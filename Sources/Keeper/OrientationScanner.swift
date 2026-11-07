// Finds sideways and upside-down photos in the background, for Sideways Photos. Modelled on
// ApplePhotosRotator's ScanEngine.
//
// Every photo is checked once, newest first, from a small local preview (nothing is downloaded);
// results are saved every 250 photos, so quitting loses only a few seconds of work and the next run
// carries on. Photos that change later (an edit, a rotation) are checked again, and so is everything
// when the check itself improves (OrientationRecord.currentEngine). Pauses while the Mac is running hot.
//
// Photos taken within a minute of another also compare themselves, turned each way, with that
// neighbour (NeighbourCue): one shot in a series that came out sideways looks like the others only
// once it's turned back.

import Foundation
import os
import Photos
import KeeperKit
import KeeperOrientation
import AppKit

enum OrientationScanner {
    /// Long edge of the image handed to Vision: big enough for small faces and text, still quick.
    static let analysisSize = 768
    static let concurrency = 4

    struct Result: Sendable {
        let checked: Int
        let networkLoaded: Bool
    }

    /// `progress(done, total)` is called after each batch; return false from `keepGoing` to stop.
    static func run(library: PhotoLibrary, store: DecisionStore,
                    progress: @escaping @Sendable (Int, Int) async -> Void,
                    keepGoing: @escaping @Sendable () async -> Bool) async -> Result? {
        // Loading may compile the network the first time.
        let network = OrientationNetDetector.builtIn
        if network == nil { log.notice("orientation: the orientation network didn't load; using faces, people and text") }
        let analyzer = OrientationAnalyzer(network: network)
        // Feature prints only for photos with a neighbour: they cost about as much as the network.
        let printingAnalyzer = OrientationAnalyzer(network: network, collectsPrints: true)

        let fetch = library.fetch(.allPhotos, newestFirst: true)
        let scanned = (try? store.orientationScanned()) ?? [:]
        let total = fetch.count
        var index = 0
        var analysed = 0
        var recent: [Check] = [] // the end of the last batch, as neighbours for the start of the next
        // Progress counts what earlier runs checked from the start, so picking up where it left off
        // doesn't look like starting over while it skips past those photos.
        let checkedBefore = min(scanned.count, total)
        func done() -> Int { min(total, max(index, checkedBefore + analysed)) }
        await progress(done(), total)

        while index < total {
            guard await keepGoing() else { return nil }
            while ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
                try? await Task.sleep(for: .seconds(20))
                guard await keepGoing() else { return nil }
            }
            // The next 250 photos that need checking (skipping costs almost nothing), and whether each
            // was taken close to the photo before or after it.
            var todo: [(asset: PHAsset, hasNeighbour: Bool)] = []
            while index < total, todo.count < 250 {
                let asset = fetch.object(at: index)
                if needsCheck(asset, scanned: scanned) {
                    todo.append((asset, hasNeighbour(fetch, index)))
                }
                index += 1
            }
            var checks: [Check] = []
            await withTaskGroup(of: Check.self) { group in
                var next = todo.makeIterator()
                func add() -> Bool {
                    guard let item = next.next() else { return false }
                    let a = item.hasNeighbour ? printingAnalyzer : analyzer
                    group.addTask { await check(item.asset, analyzer: a) }
                    return true
                }
                for _ in 0..<concurrency where add() {}
                while let c = await group.next() {
                    checks.append(c)
                    _ = add()
                }
            }
            let records = withNeighbours(checks, previous: &recent, decider: analyzer.decider)
            if !records.isEmpty {
                do { try store.saveOrientation(records) } catch {
                    log.error("orientation: couldn't save: \(error.localizedDescription, privacy: .public)")
                }
            }
            analysed += records.count
            await progress(done(), total)
        }
        log.notice("orientation: checked \(analysed) photos this run, \(total) in the library")
        return Result(checked: total, networkLoaded: network != nil)
    }

    /// One photo's check before neighbours are taken into account.
    struct Check: Sendable {
        var record: OrientationRecord
        var date: Date?
        var evidence: [DetectorEvidence] = []
        var decision: OrientationDecision?
        var prints: TurnedPrints = [:]
    }

    /// Taken within NeighbourCue.window of the photo before or after it (the fetch is in date order).
    private static func hasNeighbour(_ fetch: PHFetchResult<PHAsset>, _ i: Int) -> Bool {
        guard let date = fetch.object(at: i).creationDate else { return false }
        for j in [i - 1, i + 1] where j >= 0 && j < fetch.count {
            if let d = fetch.object(at: j).creationDate, abs(d.timeIntervalSince(date)) <= NeighbourCue.window { return true }
        }
        return false
    }

    /// Adds each photo's neighbouring-shot evidence and decides again. A neighbour only counts when
    /// it's confidently upright itself, so a whole series turned the same way stays as it was.
    static func withNeighbours(_ checks: [Check], previous: inout [Check],
                               decider: OrientationDecider) -> [OrientationRecord] {
        let pool = (previous + checks).filter { $0.date != nil && !$0.prints.isEmpty }
        let upright = pool.filter {
            guard let d = $0.decision else { return false }
            return d.status == .upright && d.confidence >= 0.5 && $0.prints[.none] != nil
        }
        let records = checks.map { c -> OrientationRecord in
            guard let date = c.date, c.prints.count == 4 else { return c.record }
            let neighbours = upright.filter {
                $0.record.assetID != c.record.assetID && abs($0.date!.timeIntervalSince(date)) <= NeighbourCue.window
            }.map { $0.prints[.none]! }
            guard let n = NeighbourCue.evidence(prints: c.prints, neighbours: neighbours) else { return c.record }
            let evidence = c.evidence + [n]
            let d = decider.decide(evidence)
            var r = c.record
            r.status = d.status
            r.rotation = d.rotation
            r.confidence = d.confidence
            r.evidence = OrientationAnalyzer.summary(of: evidence)
            return r
        }
        // Newest first: the batch's oldest photos sit next to the next batch's newest.
        previous = Array(pool.sorted { $0.date! > $1.date! }.suffix(8))
        return records
    }

    static func modDate(_ asset: PHAsset) -> Double {
        (asset.modificationDate ?? asset.creationDate)?.timeIntervalSince1970 ?? 0
    }

    /// New or changed since it was checked; screenshots and photos Photos won't let us edit are left out.
    private static func needsCheck(_ asset: PHAsset, scanned: [String: Double]) -> Bool {
        if let date = scanned[asset.localIdentifier], abs(date - modDate(asset)) < 1 { return false }
        if asset.mediaSubtypes.contains(.photoScreenshot) { return false }
        return asset.canPerform(.content)
    }

    /// The image request and Vision both block, so they run on a GCD worker rather than tying up
    /// Swift's concurrency pool.
    private static func check(_ asset: PHAsset, analyzer: OrientationAnalyzer) async -> Check {
        let id = asset.localIdentifier, date = modDate(asset), taken = asset.creationDate
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let check: Check = autoreleasepool {
                    guard let image = OrientationAnalyzer.analysisImage(for: asset, longEdge: analysisSize) else {
                        return Check(record: OrientationRecord(assetID: id, modDate: date, status: .unavailable), date: taken)
                    }
                    do {
                        let result = try analyzer.analyze(image)
                        let record = OrientationRecord(assetID: id, modDate: date, status: result.decision.status,
                                                       rotation: result.decision.rotation,
                                                       confidence: result.decision.confidence, evidence: result.summary)
                        return Check(record: record, date: taken, evidence: result.evidence,
                                     decision: result.decision, prints: result.prints)
                    } catch {
                        return Check(record: OrientationRecord(assetID: id, modDate: date, status: .failed,
                                                               evidence: error.localizedDescription), date: taken)
                    }
                }
                continuation.resume(returning: check)
            }
        }
    }
}

extension OrientationAnalyzer {
    /// A small image of the photo as Photos shows it (edits and orientation applied), which is what
    /// you judge as sideways. Local only: a photo with no local preview returns nil. **Blocking**:
    /// call it off the main thread.
    static func analysisImage(for asset: PHAsset, longEdge: Int) -> CGImage? {
        let size = CGSize(width: longEdge, height: longEdge)
        for mode in [PHImageRequestOptionsDeliveryMode.highQualityFormat, .fastFormat] {
            let options = PHImageRequestOptions()
            options.isSynchronous = true
            options.deliveryMode = mode
            options.resizeMode = .fast
            options.version = .current
            options.isNetworkAccessAllowed = false
            var result: CGImage?
            PHImageManager.default().requestImage(for: asset, targetSize: size, contentMode: .aspectFit,
                                                  options: options) { image, _ in
                result = image.flatMap { displayedPixels(of: $0, maxLongEdge: longEdge) }
            }
            if let result, result.width >= 64, result.height >= 64 { return result }
        }
        return nil
    }

    /// The image as it appears on screen, as an upright bitmap. Not `NSImage.cgImage(forProposedRect:)`:
    /// that can hand back the stored pixels without the orientation they're shown with (a portrait
    /// iPhone photo is stored sideways, with a tag saying to turn it), so every such photo would be
    /// checked sideways. Drawing applies whatever the image applies on screen.
    private static func displayedPixels(of image: NSImage, maxLongEdge: Int) -> CGImage? {
        let displayed = image.size
        guard displayed.width > 0, displayed.height > 0 else { return nil }
        let scale = min(1, CGFloat(maxLongEdge) / max(displayed.width, displayed.height))
        let width = max(1, Int((displayed.width * scale).rounded()))
        let height = max(1, Int((displayed.height * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}
