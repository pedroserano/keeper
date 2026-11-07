import CoreGraphics
import DateGuessCore
import Foundation

/// The optional face-age model: reading how old named people look, and turning that into clues.
extension AppState {
    /// Face groups of people with a birth year → that person.
    var bornClusters: [String: UUID] {
        let born = Set(people.filter { $0.birthYear != nil }.map(\.id))
        return clusterPeople.filter { born.contains($0.value) }
    }

    /// Dated photos (from the last import) of people with a birth year, for checking the model.
    func faceAgeReferenceIDs(limit: Int = 3000) -> Set<String> {
        let clusters = Set(bornClusters.keys)
        guard !clusters.isEmpty else { return [] }
        let ids = referenceCandidates.filter { !$0.value.clusterIDs.allSatisfy { !clusters.contains($0) } }
            .sorted { $0.key < $1.key }.map(\.key)
        return Set(ids.prefix(limit))
    }

    /// Each photo's model readings of people with a birth year.
    func faceReadings() -> [String: [FaceAgeClues.Reading]] {
        let clusters = bornClusters
        var out: [String: [FaceAgeClues.Reading]] = [:]
        for (asset, ages) in faceAges {
            let readings = ages.compactMap { cluster, age in
                age < 0 ? nil : clusters[cluster].map { FaceAgeClues.Reading(personID: $0, age: age) }
            }
            if !readings.isEmpty { out[asset] = readings }
        }
        return out
    }

    /// How far off the model reads ages in this library, from faces in photos with trusted dates.
    func faceAgeCorrection() -> FaceAgeClues.Correction {
        let clusters = bornClusters
        let byID = Dictionary(people.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var pairs: [(read: Double, real: Double)] = []
        for (asset, ages) in faceAges {
            guard scan.undated[asset] == nil, let c = referenceCandidates[asset] else { continue }
            let when = Double(c.year) + (Double(c.month) - 0.5) / 12
            for (cluster, age) in ages where age >= 0 {
                guard let id = clusters[cluster], let person = byID[id], let born = person.birthYear else { continue }
                let real = when - (Double(born) + (Double(person.birthMonth ?? 7) - 0.5) / 12)
                if real >= 0 { pairs.append((age, real)) }
            }
        }
        return FaceAgeClues.Correction.learn(pairs)
    }

    /// Saves within 30 seconds of a change, even while faces keep coming in.
    func scheduleFaceAgeSave() {
        guard faceAgeSaveTask == nil else { return }
        faceAgeSaveTask = Task {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            faceAgeSaveTask = nil
            store.save(faceAges, to: "faceAges")
        }
    }

    /// Reads how old named people with a birth year look, in undated photos first and then in dated
    /// ones (to check the model). Only when a face-age model is installed; runs in the background.
    func startFaceAges() {
        guard !isEstimating, settings.backgroundPaused != true, FaceAgeEstimator.isInstalled else { return }
        let clusters = bornClusters
        let open = Set(scan.undated.keys).union(appliedIDs)
        var first: [(String, [DetectedFace])] = [], later: [(String, [DetectedFace])] = []
        for (asset, faces) in detectedFaces {
            let need = faces.filter { f in f.clusterID.map { clusters[$0] != nil && faceAges[asset]?[$0] == nil } ?? false }
            guard !need.isEmpty else { continue }
            if open.contains(asset) { first.append((asset, need)) } else { later.append((asset, need)) }
        }
        let queue = first + later
        guard !queue.isEmpty else { return }
        isEstimating = true
        estimationProgress = EstimationProgress(phase: "Reading how old people look…", total: queue.count)
        estimateTask = Task {
            let read = await Self.readFaceAges(queue,
                progress: { done in await MainActor.run { self.estimationProgress?.done = done } },
                deliver: { batch in await MainActor.run {
                    var copy = self.faceAges
                    for (asset, ages) in batch { copy[asset, default: [:]].merge(ages) { _, new in new } }
                    self.faceAges = copy
                } })
            self.isEstimating = false
            self.estimationProgress = nil
            if read == nil { self.banner = "The face-age model couldn’t be loaded. Check it in Settings ▸ General." }
            self.store.save(self.faceAges, to: "faceAges")
            self.recomputeEstimates()
        }
    }

    /// Nil when the model can't be loaded; otherwise how many photos were read.
    @concurrent
    nonisolated static func readFaceAges(_ queue: [(String, [DetectedFace])],
                                         progress: @escaping @Sendable (Int) async -> Void,
                                         deliver: @escaping @Sendable ([String: [String: Double]]) async -> Void) async -> Int? {
        guard let estimator = try? FaceAgeEstimator.load() else { return nil }
        let library = PhotoLibraryService.shared
        var done = 0
        for chunk in queue.chunked(into: 16) {
            if Task.isCancelled { break }
            // Photos load in parallel. The model then reads the faces one at a time from this task:
            // predictions waiting on each other in many tasks used up the shared threads and deadlocked.
            let images = await withTaskGroup(of: (String, CGImage?).self) { group in
                for (asset, _) in chunk {
                    group.addTask {
                        guard let a = library.asset(for: asset) else { return (asset, nil) }
                        return (asset, await library.analysisImage(for: a, maxEdge: 1600, allowNetwork: false))
                    }
                }
                var out: [String: CGImage] = [:]
                for await (asset, image) in group { if let image { out[asset] = image } }
                return out
            }
            var batch: [String: [String: Double]] = [:]
            for (asset, faces) in chunk {
                for f in faces {
                    guard let cluster = f.clusterID else { continue }
                    // -1: couldn't be read (only in iCloud, or too small), so it isn't tried again each launch.
                    batch[asset, default: [:]][cluster] = images[asset].flatMap { estimator.age(of: f, in: $0) } ?? -1
                }
            }
            done += chunk.count
            await deliver(batch)
            await progress(done)
        }
        return done
    }
}
