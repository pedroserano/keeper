// Photos scanned one after another usually share a year: pages of one album, prints from one roll.
// Undated Photos lists them side by side (by date in Photos, which for a scan is when it was
// scanned), and they share their clues the way look-alikes do.
//
// Measured on photos whose year the owner typed (the ones Keeper had wrong): neighbours scanned in
// the same second shared a year 96% of the time, under 10 minutes apart 85–91%, against 7% for two
// random photos. Sharing clues with up to 10 neighbours each side, scanned within 10 minutes, took
// guesses within a year from 20% to 37%.

import Foundation
import DateGuessCore

extension AppState {
    static let neighbourReach = 10
    static let neighbourSeconds = 600.0

    /// Each undated photo's neighbours: up to 10 each side in Undated Photos' order, scanned within
    /// 10 minutes of it. Closer in time counts more.
    nonisolated static func scanNeighbours(_ order: [UndatedPhoto]) -> [String: [EventLinks.Link]] {
        var out: [String: [EventLinks.Link]] = [:]
        for (i, p) in order.enumerated() {
            guard let t = p.libraryDate else { continue }
            var mine: [EventLinks.Link] = []
            for j in max(0, i - neighbourReach)...min(order.count - 1, i + neighbourReach) where j != i {
                guard let u = order[j].libraryDate else { continue }
                let gap = abs(u.timeIntervalSince(t))
                guard gap < neighbourSeconds else { continue }
                mine.append(EventLinks.Link(assetID: order[j].id, distance: 0, weight: gap < 1 ? 0.8 : gap < 60 ? 0.6 : 0.5))
            }
            if !mine.isEmpty { out[p.id] = mine }
        }
        return out
    }
}
