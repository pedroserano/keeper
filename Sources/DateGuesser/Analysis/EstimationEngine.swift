import CoreGraphics
import Foundation
import Photos
import DateGuessCore

struct EstimationProgress: Equatable {
    var phase = ""
    var done = 0
    var total = 0

    var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
}

/// Gathers on-device clues for each undated photo: filename, albums, file format, color, borders,
/// scene labels, an image fingerprint and, when available, Apple Intelligence's season and occasion.
/// Nothing leaves the Mac.
struct EstimationEngine {
    var photos: [UndatedPhoto]
    /// Ask Apple's on-device model for the season and occasion (slower; skipped where unavailable).
    var useOnDeviceModel: Bool

    private var library: PhotoLibraryService { .shared }

    /// Always in the background: Vision work on the main thread froze the app (and could deadlock).
    @concurrent
    func run(progress: @escaping @Sendable (EstimationProgress) async -> Void,
             deliver: @escaping @Sendable ([PhotoAnalysis]) async -> Void) async {
        let model = useOnDeviceModel && OnDeviceModel.isAvailable
        var state = EstimationProgress(phase: model ? "Analyzing photos on this Mac, with Apple Intelligence…" : "Analyzing photos on this Mac…",
                                       total: photos.count)
        await progress(state)

        // Neighbors by filename tend to be related scans; process them together so results arrive in order.
        let sorted = photos.sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
        let units = sorted.chunked(into: 8)
        await withTaskGroup(of: [PhotoAnalysis].self) { group in
            var iterator = units.makeIterator()
            for _ in 0..<4 {
                guard let unit = iterator.next() else { break }
                group.addTask { await self.process(unit, model: model) }
            }
            while let analyses = await group.next() {
                if Task.isCancelled { group.cancelAll(); break }
                await deliver(analyses)
                state.done += analyses.count
                await progress(state)
                if let next = iterator.next() {
                    group.addTask { await self.process(next, model: model) }
                }
            }
        }
        state.phase = Task.isCancelled ? "Stopped" : "Done"
        await progress(state)
    }

    /// On-device clues for a few photos.
    @concurrent
    func process(_ unit: [UndatedPhoto], model: Bool) async -> [PhotoAnalysis] {
        var analyses: [PhotoAnalysis] = []
        for photo in unit {
            if Task.isCancelled { break }
            var analysis = PhotoAnalysis(assetID: photo.id, localEvidence: LocalClues.evidence(for: photo), analyzedAt: Date(),
                                         localVersion: PhotoAnalysis.currentLocalVersion)
            if let asset = library.asset(for: photo.id), let image = await library.analysisImage(for: asset, maxEdge: 512) {
                let found = await ImageAnalyzer.analyze(image)
                analysis.featurePrint = found.featurePrint
                if let stats = found.statistics { analysis.localEvidence += VisualClues.evidence(from: stats) }
                analysis.localEvidence += SceneClues.evidence(fromLabels: found.sceneLabels)
                if model, let reading = await OnDeviceModel.read(image) {
                    analysis.modelSeason = reading.season
                    analysis.modelOccasion = reading.occasion
                    analysis.modelChecked = true
                }
            }
            analyses.append(analysis)
        }
        return analyses
    }

    /// Fingerprints only, for photos analyzed before fingerprints existed, or dated reference photos.
    /// Results come back in batches.
    @concurrent
    static func fingerprints(for ids: [String],
                             progress: @escaping @Sendable (Int) async -> Void,
                             deliver: @escaping @Sendable ([String: Data]) async -> Void) async {
        let library = PhotoLibraryService.shared
        var done = 0
        for chunk in ids.chunked(into: 16) {
            if Task.isCancelled { return }
            let batch = await withTaskGroup(of: (String, Data?).self) { group in
                for id in chunk {
                    group.addTask {
                        guard let asset = library.asset(for: id),
                              let image = await library.analysisImage(for: asset, maxEdge: 512) else { return (id, nil) }
                        return (id, await ImageAnalyzer.analyze(image, labels: false).featurePrint)
                    }
                }
                var out: [String: Data] = [:]
                for await (id, data) in group { if let data { out[id] = data } }
                return out
            }
            done += chunk.count
            await deliver(batch)
            await progress(done)
        }
    }
}

/// Clues that need no image: filename, albums and file format.
enum LocalClues {
    static func evidence(for photo: UndatedPhoto) -> [DateEvidence] {
        var out: [DateEvidence] = []
        if let name = photo.format.originalFilename { out += TextClues.evidence(fromFilename: name) }
        for album in photo.albums { out += TextClues.evidence(fromAlbumName: album) }
        out += FormatClues.evidence(for: photo.format)
        return out
    }
}

/// Clues the user gave for a group, applied to every photo in it.
enum GroupClues {
    static func evidence(for group: PhotoGroup, people: [PersonInfo]) -> [DateEvidence] {
        var out = TextClues.evidence(fromHint: group.name) + TextClues.evidence(fromHint: group.hint)
        if group.yearFrom != nil || group.yearTo != nil {
            out.append(DateEvidence(source: .groupHint, summary: "You said these are from \(group.yearRangeText)",
                                    yearLow: group.yearFrom, yearHigh: group.yearTo, weight: 0.9))
        }
        if let season = group.season {
            out.append(DateEvidence(source: .groupHint, summary: "You said these are from \(season.displayName.lowercased())",
                                    season: season, seasonWeight: 1))
        }
        return out + peopleEvidence(group.people, people: people)
    }

    /// "This person is here, about N years old."
    static func peopleEvidence(_ hints: [GroupPersonHint], people: [PersonInfo]) -> [DateEvidence] {
        var out: [DateEvidence] = []
        for hint in hints {
            guard let person = people.first(where: { $0.id == hint.personID }) else { continue }
            if let age = hint.approximateAge,
               let e = PeopleClues.age(of: person, ageLow: age, ageHigh: age, matchConfidence: 1, userProvided: true) {
                out.append(e)
            } else if let type = hint.faceAgeType, let e = PeopleClues.faceAgeGroup(of: person, type: type) {
                out.append(e)
            }
            if let e = PeopleClues.presence(of: person, via: hint.fromPhotos ? " (tagged in Photos)" : "") { out.append(e) }
        }
        return out
    }
}

extension PhotoGroup {
    var yearRangeText: String {
        switch (yearFrom, yearTo) {
        case let (a?, b?): return "\(a)–\(b)"
        case let (a?, nil): return "\(a) or later"
        case let (nil, b?): return "\(b) or earlier"
        default: return ""
        }
    }
}
