// winnow-scores — command-line front end to WinnowCore, used for automated testing.
// The Winnow Spike app does the same things from a window.
//
//   winnow-scores schema  --library PATH
//   winnow-scores export  --library PATH [--out FILE]
//   winnow-scores compare PHOTOS.csv VISION.csv [--column TABLE.COLUMN]

import Foundation
import WinnowCore

func option(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func readCSV(_ path: String) throws -> (header: [String], rows: [[String]]) {
    let text = try String(contentsOfFile: path, encoding: .utf8)
    var lines = text.split(whereSeparator: \.isNewline)
        .map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
    guard !lines.isEmpty else { throw PhotosDatabaseError(kind: .notFound, message: "\(path) is empty") }
    return (lines.removeFirst(), lines)
}

func fmt(_ v: Double?) -> String { v.map { String(format: "%.3f", $0) } ?? "–" }

let args = Array(CommandLine.arguments.dropFirst())
let library = option("--library", in: args).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }

do {
    switch args.first {
    case "schema" where library != nil:
        let db = try PhotosDatabase(library: library!)
        print("\(db.libraryName) · asset table \(db.schema.assetTable) · \(try db.photoCount()) photos")
        for s in try db.columnStats() {
            let join = s.joinable ? "" : "  (several rows per photo; not exported)"
            print("  \(s.id.padding(toLength: 58, withPad: " ", startingAt: 0)) n=\(s.nonNull) min=\(fmt(s.min)) max=\(fmt(s.max)) mean=\(fmt(s.mean))\(join)")
        }

    case "export" where library != nil:
        let db = try PhotosDatabase(library: library!)
        let export = try db.exportRows()
        let out = URL(fileURLWithPath: option("--out", in: args) ?? "out/photos-scores.csv")
        var csv = export.header.joined(separator: ",") + "\n"
        for row in export.rows { csv += row.map { $0 ?? "" }.joined(separator: ",") + "\n" }
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try csv.write(to: out, atomically: true, encoding: .utf8)
        print("Exported \(export.rows.count) photos × \(export.header.count - 1) score columns to \(out.path)")

    case "compare" where args.count >= 3:
        let photos = try readCSV(args[1]), vision = try readCSV(args[2])
        let column = option("--column", in: args)
        guard let pc = column.flatMap({ photos.header.firstIndex(of: $0) })
                ?? photos.header.firstIndex(where: { $0.uppercased().contains("OVERALLAESTHETIC") }),
              let vc = vision.header.firstIndex(of: "overall") else {
            throw PhotosDatabaseError(kind: .notFound, message: "Need an overall aesthetic column (or --column) and a Vision 'overall' column.")
        }
        var photoScore: [String: Double] = [:]
        for row in photos.rows where row.count > pc { photoScore[row[0]] = Double(row[pc]) }
        let pairs: [(Double, Double)] = vision.rows.compactMap { row in
            guard row.count > vc, let p = photoScore[row[0]], let v = Double(row[vc]) else { return nil }
            return (p, v)
        }
        guard pairs.count >= 10 else {
            throw PhotosDatabaseError(kind: .notFound, message: "Only \(pairs.count) photos are in both files; need 10.")
        }
        let overlap = bottomFifthOverlap(pairs)
        print("Column: \(photos.header[pc])\nPhotos in both files: \(pairs.count)")
        print(String(format: "Spearman rank correlation: %.2f", spearman(pairs)))
        print("Bottom-20% overlap: \(overlap.hits) of \(overlap.of)")

    default:
        print("""
            usage: winnow-scores schema  --library PATH
                   winnow-scores export  --library PATH [--out FILE]
                   winnow-scores compare PHOTOS.csv VISION.csv [--column TABLE.COLUMN]
            """)
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
