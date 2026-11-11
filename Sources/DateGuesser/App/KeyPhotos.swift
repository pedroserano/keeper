// Key Photos: the undated photos whose date would tell Keeper the most about others, and the
// clue a date you set gives the photos linked to it.
//
// A date you type for a photo becomes its strongest clue, and Keeper already shares a photo's clues
// with its look-alikes and with the event it's in. So dating one photo of a wedding dates the
// rest of the wedding's photos, as soon as you set it (before Apply).

import Foundation
import DateGuessCore

/// An undated photo worth dating first, and how many unsure photos its date would reach.
struct KeyPhoto: Hashable, Sendable {
    var id: String
    var helps: Int
}

extension AppState {
    /// The clue a date you set for a photo gives it, and through it the photos linked to it.
    nonisolated static func yourDateClue(_ d: ReviewDecision) -> DateEvidence? {
        guard let year = d.overrideYear, !d.ignored else { return nil }
        let month = d.overrideMonth
        let season = month.map { Season.from(month: $0) } ?? d.overrideSeason
        let when = month.map { "\(DateEstimate.monthNames[max(1, min(12, $0)) - 1]) \(year)" }
            ?? d.overrideSeason.map { "\($0.displayName) \(year)" } ?? String(year)
        return DateEvidence(source: .groupHint, summary: "You dated this photo \(when)",
                            yearLow: year, yearHigh: year, peakYear: year, weight: 0.97,
                            season: season, seasonWeight: season == nil ? 0 : 0.9, exactMonth: month)
    }

    /// Photos linked to more than this many others aren't worth more for it: a huge event counts
    /// like a big one, so the list spreads over many events.
    nonisolated static let keyPhotoMaxReach = 40.0

    /// Ranks undated photos by how much their date would help: unsure photos linked (as look-alikes
    /// or the same suggested event) to many other unsure photos. Each pick halves what its linked
    /// photos count for the next, so the list covers different events rather than one many times.
    nonisolated static func rankKeyPhotos(candidates: [String: Double], links: [String: [EventLinks.Link]],
                                          events: [[String]], limit: Int = 60) -> [KeyPhoto] {
        // Who each photo would inform, and how strongly.
        var reach: [String: [String: Double]] = [:]
        for (id, list) in links where candidates[id] != nil {
            for l in list where candidates[l.assetID] != nil { reach[id, default: [:]][l.assetID] = max(reach[id]?[l.assetID] ?? 0, l.weight) }
        }
        for event in events {
            let members = event.filter { candidates[$0] != nil }
            guard members.count >= 2 else { continue }
            for a in members { for b in members where a != b { reach[a, default: [:]][b] = max(reach[a]?[b] ?? 0, 0.6) } }
        }
        // How much each photo still needs a date (1 − confidence); halved once a linked photo is picked.
        var need = candidates.mapValues { 1 - $0 }
        func score(_ id: String) -> Double {
            guard let others = reach[id] else { return 0 }
            let gain = others.reduce(0) { $0 + $1.value * (need[$1.key] ?? 0) }
            return (0.3 + 0.7 * (need[id] ?? 0)) * min(gain, keyPhotoMaxReach)
        }
        var out: [KeyPhoto] = []
        var left = Set(reach.keys)
        while out.count < limit {
            guard let best = left.max(by: { score($0) < score($1) }), score(best) >= 1 else { break }
            let others = reach[best] ?? [:]
            out.append(KeyPhoto(id: best, helps: others.keys.filter { (candidates[$0] ?? 1) < 0.6 }.count))
            left.remove(best)
            for o in others.keys { need[o] = (need[o] ?? 0) / 2 }
            need[best] = 0
        }
        return out
    }

    /// Works out Key Photos, in the background: once, then only when you ask (`force`). Like every
    /// screen, photos stay where they are while you work on them; only photos no longer undated
    /// (applied, or gone from the library) leave the list.
    func refreshKeyPhotos(force: Bool = false) {
        if !force && !keyPhotos.isEmpty {
            let undated = scan.undated, applied = appliedIDs
            let kept = keyPhotos.filter { undated[$0.id] != nil && !applied.contains($0.id) }
            if kept.count != keyPhotos.count { keyPhotos = kept }
            return
        }
        var candidates: [String: Double] = [:]
        let applied = appliedIDs
        for photo in undatedSorted {
            let d = decision(photo.id)
            guard !d.ignored, !d.isOverridden, !applied.contains(photo.id), let e = estimates[photo.id] else { continue }
            candidates[photo.id] = e.estimate.confidence
        }
        let links = eventLinks, events = eventSuggestions
        keyPhotosRun += 1
        let run = keyPhotosRun
        Task.detached(priority: .utility) {
            let started = ContinuousClock.now
            let ranked = AppState.rankKeyPhotos(candidates: candidates, links: links, events: events)
            Timing.note("key photos: \(ranked.count), reaching \(ranked.reduce(0) { $0 + $1.helps }) unsure photos", since: started)
            await MainActor.run {
                guard run == self.keyPhotosRun else { return }
                self.keyPhotos = ranked
            }
        }
    }

    /// How many unsure photos this photo's date would reach, if it's a key photo.
    func keyPhotoHelps(_ id: String) -> Int? { keyPhotos.first { $0.id == id }?.helps }

    /// Order-free fingerprint of the dates you set, to notice when one changes (also by ⌘Z).
    var yourDatesSignature: Int {
        decisions.reduce(0) { sum, kv in
            guard kv.value.isOverridden, !kv.value.ignored else { return sum }
            var h = Hasher()
            h.combine(kv.key); h.combine(kv.value.overrideYear); h.combine(kv.value.overrideMonth); h.combine(kv.value.overrideSeason)
            return sum &+ h.finalize()
        }
    }
}
