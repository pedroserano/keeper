// Photos that may be missing from an album: in no album at all, but taken during an album's days
// and near where its photos were taken at the time.
//
// Only albums covering at most `maxSpanDays` count (a trip or an event, not "2019" or "Family").
// A photo fits an album when it was taken between the album's first and last photo and within
// `areaKm` of the album photo taken closest to it in time, so a road trip's album takes photos
// from each stop. A photo that fits two albums goes to the one with a photo closest in time.

import Foundation

public enum AlbumAdditions {
    public static let areaKm = 25.0
    public static let maxSpanDays = 30.0
    /// Albums need this many photos with a location to say where they were.
    public static let minLocated = 3

    public struct Album: Sendable {
        public var id: String
        public var title: String
        /// The album's photos that have a date and a location.
        public var located: [AlbumSuggestions.Photo]
        public init(id: String, title: String, located: [AlbumSuggestions.Photo]) {
            self.id = id
            self.title = title
            self.located = located
        }
    }

    public struct Addition: Sendable, Hashable, Identifiable {
        public var albumID: String
        public var title: String
        /// In time order.
        public var ids: [String]
        public var start: Date
        public var end: Date
        public var id: String { albumID }
    }

    /// `loose` are photos in no album. Albums with the most to add come first.
    public static func suggest(albums: [Album], loose: [AlbumSuggestions.Photo]) -> [Addition] {
        struct Window {
            var album: Album
            var members: [AlbumSuggestions.Photo]   // sorted by time
            var start: Date, end: Date
        }
        let windows: [Window] = albums.compactMap { album in
            let members = album.located.sorted { $0.time < $1.time }
            guard members.count >= minLocated, let start = members.first?.time, let end = members.last?.time,
                  end.timeIntervalSince(start) <= maxSpanDays * 86_400 else { return nil }
            return Window(album: album, members: members, start: start, end: end)
        }
        guard !windows.isEmpty else { return [] }

        var found: [String: [AlbumSuggestions.Photo]] = [:]
        for photo in loose {
            var best: (album: String, gap: TimeInterval)?
            for w in windows where photo.time >= w.start && photo.time <= w.end {
                guard let nearest = closestInTime(w.members, to: photo.time),
                      nearest.point.distanceKm(to: photo.point) <= areaKm else { continue }
                let gap = abs(nearest.time.timeIntervalSince(photo.time))
                if best == nil || gap < best!.gap { best = (w.album.id, gap) }
            }
            if let best { found[best.album, default: []].append(photo) }
        }
        return windows.compactMap { w in
            guard let photos = found[w.album.id], !photos.isEmpty else { return nil }
            let sorted = photos.sorted { $0.time != $1.time ? $0.time < $1.time : $0.id < $1.id }
            return Addition(albumID: w.album.id, title: w.album.title, ids: sorted.map(\.id), start: w.start, end: w.end)
        }
        .sorted { $0.ids.count != $1.ids.count ? $0.ids.count > $1.ids.count : $0.start > $1.start }
    }

    /// Binary search in photos sorted by time.
    static func closestInTime(_ sorted: [AlbumSuggestions.Photo], to time: Date) -> AlbumSuggestions.Photo? {
        guard !sorted.isEmpty else { return nil }
        var lo = 0, hi = sorted.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sorted[mid].time < time { lo = mid + 1 } else { hi = mid }
        }
        let candidates = [lo - 1, lo].filter { $0 >= 0 && $0 < sorted.count }.map { sorted[$0] }
        return candidates.min { abs($0.time.timeIntervalSince(time)) < abs($1.time.timeIntervalSince(time)) }
    }
}
