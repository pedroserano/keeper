// Tiny Thumbnails: pixelated little copies that got into the library by accident: thumbnails
// brought back by data recovery or saved from websites, and real photos shrunk to thumbnail size.
//
// From one library's sizes: below 480 pixels on the longest side photos bunch up at thumbnail
// sizes (360 × 240 most of all). Screenshots are left out. Most pixelated first: fewest pixels,
// then blurriest.

import KeeperCore

public enum LowQuality {
    /// A photo whose longest side is under this is thumbnail-sized.
    public static let thumbnailSide = 480

    /// Where the photo goes in the list, lowest first (its pixels times how sharp Photos finds it),
    /// or nil when it isn't thumbnail-sized.
    public static func rank(width: Int?, height: Int?, scores: AppleScores?, isScreenshot: Bool) -> Double? {
        guard !isScreenshot, let w = width, let h = height, w > 0, h > 0,
              max(w, h) < thumbnailSide else { return nil }
        return Double(w * h) * min(max(scores?.blurriness ?? 1, 0.01), 1)
    }

    /// Every thumbnail-sized photo by UUID, with its place in the list.
    public static func find(files: [String: FileInfo], scores: [String: AppleScores],
                            screenshots: Set<String>) -> [String: Double] {
        var out: [String: Double] = [:]
        for (uuid, file) in files {
            if let r = rank(width: file.width, height: file.height,
                            scores: scores[uuid], isScreenshot: screenshots.contains(uuid)) {
                out[uuid] = r
            }
        }
        return out
    }
}
