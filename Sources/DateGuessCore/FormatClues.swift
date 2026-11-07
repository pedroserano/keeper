import Foundation

/// Facts about the file itself, gathered from PhotoKit and the original file's metadata.
public struct FormatInfo: Codable, Hashable, Sendable {
    public var originalFilename: String?
    public var uniformTypeIdentifier: String?
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var isScreenshot: Bool
    public var isLivePhoto: Bool
    public var isPanorama: Bool
    public var isDepthEffect: Bool
    public var cameraMake: String?
    public var cameraModel: String?
    public var software: String?
    public var hasGPS: Bool

    public init(originalFilename: String? = nil, uniformTypeIdentifier: String? = nil,
                pixelWidth: Int = 0, pixelHeight: Int = 0,
                isScreenshot: Bool = false, isLivePhoto: Bool = false, isPanorama: Bool = false,
                isDepthEffect: Bool = false, cameraMake: String? = nil, cameraModel: String? = nil,
                software: String? = nil, hasGPS: Bool = false) {
        self.originalFilename = originalFilename
        self.uniformTypeIdentifier = uniformTypeIdentifier
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.isScreenshot = isScreenshot
        self.isLivePhoto = isLivePhoto
        self.isPanorama = isPanorama
        self.isDepthEffect = isDepthEffect
        self.cameraMake = cameraMake
        self.cameraModel = cameraModel
        self.software = software
        self.hasGPS = hasGPS
    }

    public var fileExtension: String? {
        guard let name = originalFilename, let dot = name.lastIndex(of: ".") else { return nil }
        return String(name[name.index(after: dot)...]).lowercased()
    }

    /// One-line description used in the AI prompt.
    public var promptDescription: String {
        var parts: [String] = []
        if let uti = uniformTypeIdentifier { parts.append("type \(uti)") }
        if pixelWidth > 0 { parts.append("\(pixelWidth)×\(pixelHeight) px") }
        if let make = cameraMake ?? cameraModel {
            parts.append("camera \(make)\(cameraModel.map { " \($0)" } ?? "")")
        }
        if let software { parts.append("software \(software)") }
        if isLivePhoto { parts.append("Live Photo") }
        if isPanorama { parts.append("panorama") }
        if isScreenshot { parts.append("screenshot") }
        if hasGPS { parts.append("has GPS location") }
        return parts.joined(separator: ", ")
    }
}

/// Clues from the file format, device features and camera model.
public enum FormatClues {
    public static func evidence(for info: FormatInfo, now: Date = Date()) -> [DateEvidence] {
        var out: [DateEvidence] = []
        let uti = (info.uniformTypeIdentifier ?? "").lowercased()
        let ext = info.fileExtension ?? ""

        if uti.contains("heic") || uti.contains("heif") || ext == "heic" || ext == "heif" {
            out.append(lowerBound(2017, .fileFormat, "HEIC files were introduced with iOS 11 in 2017", hard: true))
        }
        if info.isLivePhoto {
            out.append(lowerBound(2015, .fileFormat, "Live Photos were introduced in 2015", hard: true))
        }
        if info.isDepthEffect {
            out.append(lowerBound(2016, .fileFormat, "Portrait (depth) photos were introduced in 2016", hard: true))
        }
        if info.isScreenshot {
            out.append(lowerBound(2007, .fileFormat, "Screenshot from a modern device", hard: false, weight: 0.8))
        }
        if info.isPanorama {
            out.append(lowerBound(2012, .fileFormat, "In-camera panorama (iPhone panoramas date from 2012)", hard: false, weight: 0.6))
        }
        if uti.contains("raw") || uti.contains("dng") || ["dng", "cr2", "cr3", "nef", "arw", "orf", "raf", "rw2"].contains(ext) {
            out.append(lowerBound(2000, .fileFormat, "Camera RAW file (digital SLR era)", hard: true))
        }
        if uti.contains("tiff") || ext == "tif" || ext == "tiff" {
            out.append(DateEvidence(source: .fileFormat, summary: "TIFF file — usually a scan of a print, slide or negative"))
        }

        // Camera information means a digital camera (or a phone) took the picture.
        let make = (info.cameraMake ?? "").trimmingCharacters(in: .whitespaces)
        let model = (info.cameraModel ?? "").trimmingCharacters(in: .whitespaces)
        if !make.isEmpty || !model.isEmpty {
            let name = [make, model].filter { !$0.isEmpty }.joined(separator: " ")
            if UndatedDetector.looksLikeScanner(make: make, model: model, software: info.software) {
                out.append(DateEvidence(source: .camera, summary: "Scanned with \(name) — the file date is the scan date, not when the photo was taken"))
            } else if let year = iPhoneReleaseYear(model) {
                out.append(lowerBound(year, .camera, "Taken with an \(model) (released \(year))", hard: true))
            } else {
                out.append(lowerBound(1995, .camera, "Taken with a digital camera (\(name))", hard: false, weight: 0.85))
                let megapixels = Double(info.pixelWidth * info.pixelHeight) / 1_000_000
                if megapixels > 0 && megapixels < 0.8 {
                    out.append(DateEvidence(source: .camera,
                                            summary: String(format: "Very low resolution (%.1f MP) typical of early digital cameras", megapixels),
                                            yearLow: 1995, yearHigh: 2005, peakYear: 2001, weight: 0.5))
                } else if megapixels >= 0.8 && megapixels < 2.5 {
                    out.append(DateEvidence(source: .camera,
                                            summary: String(format: "%.1f MP resolution typical of early-2000s digital cameras", megapixels),
                                            yearLow: 1998, yearHigh: 2008, peakYear: 2003, weight: 0.3))
                }
            }
        }
        return out
    }

    static func lowerBound(_ year: Int, _ source: EvidenceSource, _ summary: String, hard: Bool, weight: Double = 0.95) -> DateEvidence {
        DateEvidence(source: source, summary: summary, yearLow: year, yearHigh: nil,
                     weight: hard ? 1 : weight, isHardConstraint: hard)
    }

    /// Release year of an iPhone model string such as "iPhone 6s Plus".
    public static func iPhoneReleaseYear(_ model: String) -> Int? {
        let m = model.lowercased()
        guard m.hasPrefix("iphone") else { return nil }
        let rest = m.dropFirst("iphone".count).trimmingCharacters(in: .whitespaces)
        let table: [(String, Int)] = [
            ("3gs", 2009), ("3g", 2008), ("4s", 2011), ("4", 2010), ("5s", 2013), ("5c", 2013), ("5", 2012),
            ("se (3rd", 2022), ("se (2nd", 2020), ("se", 2016),
            ("6s", 2015), ("6", 2014), ("7", 2016), ("8", 2017), ("xs", 2018), ("xr", 2018), ("x", 2017),
            ("11", 2019), ("12", 2020), ("13", 2021), ("14", 2022), ("15", 2023), ("16e", 2025), ("16", 2024),
            ("17", 2025), ("air", 2025), ("18", 2026),
        ]
        if rest.isEmpty { return 2007 }
        for (prefix, year) in table where rest.hasPrefix(prefix) {
            // "1" must not match "11"; the table is ordered so longer prefixes come first.
            return year
        }
        return nil
    }
}

// MARK: - Digital photos vs. scans of prints

public enum DigitalPhotoClues {
    /// Exact sizes digital cameras save at (4:3, the shape of compact-camera sensors). Film prints are
    /// 3:2 or square, and scanners save at sizes set by the print and the scan resolution.
    static let cameraSizes: Set<Int> = [
        640 * 10_000 + 480, 1024 * 10_000 + 768, 1280 * 10_000 + 960, 1600 * 10_000 + 1200,
        2048 * 10_000 + 1536, 2272 * 10_000 + 1704, 2592 * 10_000 + 1944, 2816 * 10_000 + 2112,
        3072 * 10_000 + 2304, 3264 * 10_000 + 2448, 3648 * 10_000 + 2736, 4000 * 10_000 + 3000,
        4032 * 10_000 + 3024,
    ]

    static let cameraName = try! NSRegularExpression(
        pattern: #"^(img|dsc|dscn|dscf|dsci|pict|cimg|dcp|hpim|kif|imag|pxl|p[0-9]{3})[_ -]?[0-9]{3,}\.(jpe?g|heic)$"#,
        options: [.caseInsensitive])

    /// A photo straight from a digital camera rather than a scanned print.
    public static func looksDigital(_ info: FormatInfo) -> Bool {
        let long = max(info.pixelWidth, info.pixelHeight), short = min(info.pixelWidth, info.pixelHeight)
        if cameraSizes.contains(long * 10_000 + short) { return true }
        if let name = info.originalFilename {
            let range = NSRange(name.startIndex..., in: name)
            if cameraName.firstMatch(in: name, range: range) != nil { return true }
        }
        return false
    }

    /// Clues about film prints that make no sense for a digital photo.
    static let filmOnly: Set<EvidenceSource> = [.colorTone, .printFormat]

    /// Leaves out film-print clues on digital photos (unless a print border was seen, which means
    /// it's a scan after all).
    public static func apply(to evidence: [DateEvidence], format: FormatInfo) -> [DateEvidence] {
        guard looksDigital(format), !evidence.contains(where: { $0.source == .borderPaper }) else { return evidence }
        // A "digital era" clue was tried too; on real data it made guesses worse, so there isn't one.
        return evidence.map { e -> DateEvidence in
            guard filmOnly.contains(e.source), !e.isHardConstraint, e.weight > 0 || e.seasonWeight > 0 else { return e }
            var e = e
            e.weight = 0
            e.summary += " — left out: this looks like a digital camera photo, not a scanned print"
            return e
        }
    }
}

// MARK: - Cameras the user remembers

/// "I used this camera from … to …", entered by the user.
public struct CameraPeriod: Codable, Hashable, Identifiable, Sendable {
    /// The camera's name as the app shows it (make + model), also used to match photos.
    public var id: String
    public var fromYear: Int?
    public var toYear: Int?

    public init(id: String, fromYear: Int? = nil, toYear: Int? = nil) {
        self.id = id
        self.fromYear = fromYear
        self.toYear = toYear
    }
}

public enum CameraClues {
    /// "Canon Canon PowerShot S100" → "Canon PowerShot S100" (many cameras repeat the make in the model).
    public static func name(make: String?, model: String?) -> String? {
        let m = (make ?? "").trimmingCharacters(in: .whitespaces)
        let mo = (model ?? "").trimmingCharacters(in: .whitespaces)
        if mo.isEmpty { return m.isEmpty ? nil : m }
        if m.isEmpty || mo.lowercased().hasPrefix(m.lowercased().split(separator: " ").first.map(String.init) ?? m.lowercased()) {
            return mo
        }
        return "\(m) \(mo)"
    }

    /// The camera that took this photo, unless it's a scanner (a scan's camera says nothing about when).
    public static func camera(of info: FormatInfo) -> String? {
        guard !UndatedDetector.looksLikeScanner(make: info.cameraMake, model: info.cameraModel, software: info.software) else { return nil }
        return name(make: info.cameraMake, model: info.cameraModel)
    }

    public static func evidence(for info: FormatInfo, periods: [CameraPeriod]) -> DateEvidence? {
        guard let camera = camera(of: info),
              let period = periods.first(where: { $0.id.caseInsensitiveCompare(camera) == .orderedSame }),
              period.fromYear != nil || period.toYear != nil else { return nil }
        let lo = period.fromYear, hi = period.toYear
        let range: String
        switch (lo, hi) {
        case let (a?, b?): range = "from \(min(a, b)) to \(max(a, b))"
        case let (a?, nil): range = "from \(a) on"
        case let (nil, b?): range = "until \(b)"
        default: range = ""
        }
        return DateEvidence(source: .camera, summary: "You used the \(camera) \(range)",
                            yearLow: lo.map { a in hi.map { min(a, $0) } ?? a },
                            yearHigh: hi.map { b in lo.map { max(b, $0) } ?? b }, weight: 0.92)
    }
}
