// Finds duplicates and similar shots in the background.
//
// Only photos taken within Similarity.clusterGap of another are fingerprinted (Vision feature
// print, revision 2, from a small preview), and each fingerprint is saved, so the first run does
// the work once and later runs only process new photos. Pauses while the Mac is running hot.

import AppKit
import Foundation
import os
import Photos
import Vision
import KeeperKit
import KeeperCore

enum SimilarityIndexer {
    struct Result: Sendable {
        let groups: [SimilarGroup]
        /// uuid → PHAsset.localIdentifier for every grouped photo.
        let localIDs: [String: String]
        let candidates: Int
        let histogram: [(upTo: Float, count: Int)]
        /// Duplicates under the old rule (no shared capture moment needed), only until saved ticks
        /// have been carried over to the new groups.
        let previousDuplicates: [SimilarGroup]
        /// Every photo, newest first, for the Sideways scan that follows (so it needn't read them again).
        let library: [OrientationScanner.Photo]
    }

    /// `progress(done, total)` is called after each batch; return false from `keepGoing` to stop.
    static func run(library: PhotoLibrary, store: DecisionStore,
                    progress: @escaping @Sendable (Int, Int) async -> Void,
                    keepGoing: @escaping @Sendable () async -> Bool) async -> Result? {
        var clock = StageClock("similarity")
        // 1. Every photo's date, to find the ones taken close together.
        var photos: [(uuid: String, date: Date)] = []
        var localIDs: [String: String] = [:]
        var dates: [String: Date] = [:]
        var everyPhoto: [OrientationScanner.Photo] = []
        library.fetch(.allPhotos, newestFirst: false).enumerateObjects { a, _, _ in
            everyPhoto.append(OrientationScanner.Photo(a))
            guard let date = a.creationDate else { return }
            let uuid = String(a.localIdentifier.split(separator: "/").first ?? "")
            photos.append((uuid, date))
            localIDs[uuid] = a.localIdentifier
            dates[uuid] = date
        }
        clock.lap("enumerate")
        let clusters = Similarity.timeClusters(photos)
        let candidates = clusters.flatMap { $0 }
        let done = (try? store.featurePrintUUIDs()) ?? []
        let todo = candidates.filter { !done.contains($0) }
        clock.lap("find new")
        log.notice("similarity: \(photos.count) photos, \(candidates.count) taken close to another, \(todo.count) to fingerprint")

        // 2. Fingerprint what's new, a batch at a time, saving as we go.
        var processed = candidates.count - todo.count
        await progress(processed, candidates.count)
        for start in stride(from: 0, to: todo.count, by: 64) {
            guard await keepGoing() else { return nil }
            while ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
                try? await Task.sleep(for: .seconds(20))
                guard await keepGoing() else { return nil }
            }
            let batch = Array(todo[start..<min(start + 64, todo.count)])
            let assets = library.assets(withIDs: batch.compactMap { localIDs[$0] })
            var prints: [String: FeatureVector] = [:]
            await withTaskGroup(of: (String, FeatureVector?).self) { group in
                var next = assets.makeIterator()
                func add() -> Bool {
                    guard let asset = next.next() else { return false }
                    group.addTask { (String(asset.localIdentifier.split(separator: "/").first ?? ""),
                                     await featurePrint(asset, library: library)) }
                    return true
                }
                for _ in 0..<4 where add() {} // four at a time
                while let (uuid, vector) = await group.next() {
                    if let vector { prints[uuid] = vector }
                    _ = add()
                }
            }
            try? store.saveFeaturePrints(prints)
            processed += batch.count
            await progress(processed, candidates.count)
        }

        clock.lap("fingerprint \(todo.count)")
        // 3. Group them: near-identical copies, and look-alike takes, separately.
        let vectors = (try? store.featurePrints(for: Set(candidates))) ?? [:]
        clock.lap("read prints")
        let groups = Similarity.groups(clusters: clusters, vectors: vectors, dates: dates, kind: .duplicate)
            + Similarity.groups(clusters: clusters, vectors: vectors, dates: dates, kind: .similar)
        let carriedOver = ((try? store.setting("duplicatesRule")) ?? nil) == CullingSession.duplicatesRule
        let previous = carriedOver ? [] : Similarity.groups(clusters: clusters, vectors: vectors, dates: dates,
                                                             kind: .duplicate, sameMomentDuplicates: false)
        let grouped = Set(groups.flatMap(\.members))
        clock.lap("group")
        let histogram = Similarity.nearestNeighbourHistogram(clusters: clusters, vectors: vectors)
        clock.lap("histogram")
        return Result(groups: groups, localIDs: localIDs.filter { grouped.contains($0.key) },
                      candidates: candidates.count, histogram: histogram, previousDuplicates: previous,
                      library: everyPhoto.reversed())
    }

    /// Vision feature print of a small preview. Photos only stored in iCloud still have a local
    /// preview, so nothing is downloaded.
    static func featurePrint(_ asset: PHAsset, library: PhotoLibrary) async -> FeatureVector? {
        var image: NSImage?
        await ScreenImages.shared.waitUntilQuiet()
        for await loaded in library.images(for: asset, targetSize: CGSize(width: 360, height: 360),
                                           highQualityOnly: true, background: true) {
            image = loaded.image ?? image
        }
        guard let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = VNGenerateImageFeaturePrintRequestRevision2
        guard (try? VNImageRequestHandler(cgImage: cg).perform([request])) != nil,
              let print = request.results?.first, print.elementType == .float else { return nil }
        return FeatureVector(print.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) })
    }

    /// Summary for tuning the thresholds: how many photos were compared, how many groups formed,
    /// and how close each photo's nearest neighbour was. No per-photo data.
    static func saveReport(_ r: Result, libraryName: String) {
        var csv = "library,measure,value\n"
        csv += "\(libraryName),comparedPhotos,\(r.candidates)\n"
        for kind in [SimilarGroup.Kind.duplicate, .similar] {
            let name = kind == .duplicate ? "duplicate" : "similar"
            let groups = r.groups.filter { $0.kind == kind }
            let sizes = Similarity.sizeCounts(groups)
            csv += "\(libraryName),\(name).threshold,\(kind.distance)\n"
            csv += "\(libraryName),\(name).groups,\(groups.count)\n"
            csv += "\(libraryName),\(name).photos,\(groups.map(\.members.count).reduce(0, +))\n"
            csv += "\(libraryName),\(name).largestGroup,\(sizes.largest)\n"
            for size in sizes.counts.keys.sorted() where size <= 10 {
                csv += "\(libraryName),\(name).groupsOfSize\(size),\(sizes.counts[size]!)\n"
            }
            let bigger = sizes.counts.filter { $0.key > 10 }.values.reduce(0, +)
            if bigger > 0 { csv += "\(libraryName),\(name).groupsOfSizeOver10,\(bigger)\n" }
        }
        csv += "\(libraryName),groupSpanSeconds,\(Int(Similarity.groupSpan))\n"
        for bin in r.histogram {
            csv += "\(libraryName),nearestNeighbour<=\(bin.upTo.isFinite ? String(format: "%.2f", bin.upTo) : "inf"),\(bin.count)\n"
        }
        let dir = DecisionStore.directory.appendingPathComponent("Reports")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? csv.write(to: dir.appendingPathComponent("similarity-report.csv"), atomically: true, encoding: .utf8)
    }
}
