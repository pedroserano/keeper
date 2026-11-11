import Foundation

/// How far to trust an album named for a year, learned from its own photos that have a camera date.
///
/// "1998" or "Beach 2004" is a strong hint, but how strong depends on how the library is kept: on
/// one library, photos with a camera date were in the album's year 63% of the time for albums named
/// only a year (85% within a year), and 81% (93%) for a year in a longer name. So each album is
/// judged by its own dated photos: one whose photos are nearly all from its year counts heavily for
/// that year; one whose photos spill into the years around it counts for "that year, give or take
/// one"; one that mixes many years counts for less.
public struct YearAlbum: Codable, Hashable, Sendable {
    public var year: Int
    /// Its photos with a capture time from the camera.
    public var dated: Int
    public var sameYear: Int
    public var withinYear: Int

    public init(year: Int, dated: Int, sameYear: Int, withinYear: Int) {
        self.year = year
        self.dated = dated
        self.sameYear = sameYear
        self.withinYear = withinYear
    }
}

public enum AlbumYears {
    /// Albums need this many dated photos before they're judged by them.
    public static let minimumDated = 10
    public static let maxWeight = 0.97

    /// The single year in an album's name ("1998", "Beach 2004"), or nil for none or several.
    public static func year(inTitle title: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: "(?<![0-9])(18|19|20)[0-9]{2}(?![0-9])") else { return nil }
        let ns = title as NSString
        let years = regex.matches(in: title, range: NSRange(location: 0, length: ns.length)).compactMap { Int(ns.substring(with: $0.range)) }
        return years.count == 1 ? years[0] : nil
    }

    /// The album name an album clue was made from.
    static func title(of e: DateEvidence) -> String? {
        let base = e.summary.components(separatedBy: ClueCalibration.noteSeparator)[0]
        guard let open = base.lastIndex(of: "“"), let close = base.lastIndex(of: "”"), open < close else { return nil }
        return String(base[base.index(after: open)..<close])
    }

    /// An album's year clue, weighted by how often the album's own dated photos are from that year.
    public static func adjust(_ e: DateEvidence, albums: [String: YearAlbum]) -> DateEvidence {
        guard e.source == .album, !e.isHardConstraint, let lo = e.yearLow, lo == e.yearHigh,
              let title = title(of: e), let album = albums[title], album.year == lo,
              album.dated >= minimumDated else { return e }
        // A little toward even odds, so a small album isn't taken as certain.
        let n = Double(album.dated)
        let same = (Double(album.sameYear) + 1) / (n + 2)
        let near = (Double(album.withinYear) + 1) / (n + 2)
        var out = e
        if same >= 0.8 {
            out.weight = min(maxWeight, same)
        } else {
            out.yearLow = lo - 1
            out.yearHigh = lo + 1
            out.peakYear = lo
            out.weight = min(maxWeight, near)
        }
        out.summary = e.summary + ClueCalibration.noteSeparator
            + "\(Int((same * 100).rounded()))% of its \(album.dated.formatted()) photos with a camera date are from \(lo), \(Int((near * 100).rounded()))% within a year"
        return out
    }
}
