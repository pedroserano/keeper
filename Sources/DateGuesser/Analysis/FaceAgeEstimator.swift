import CoreGraphics
import CoreML
import DateGuessCore
import Foundation

/// Reads how old a face looks with an optional Core ML model the user adds (Settings ▸ Face Age
/// Model). Nothing is bundled with the app: the models that work well are licensed for
/// non-commercial use only. The model takes a 384×384 RGB face and returns `age` in years.
final class FaceAgeEstimator: @unchecked Sendable {
    /// Either format works; the newer .mlpackage runs on the GPU and is far faster.
    static let fileNames = ["FaceAge.mlpackage", "FaceAge.mlmodel"]

    private let model: MLModel
    private let constraint: MLImageConstraint
    /// One prediction at a time: parallel GPU predictions on one model deadlocked (seen in a sample).
    private let lock = NSLock()

    /// Where the user's model is kept: the app's data folder.
    static var modelURL: URL {
        let urls = fileNames.map { JSONStore.shared.directory.appendingPathComponent($0) }
        return urls.first { FileManager.default.fileExists(atPath: $0.path) } ?? urls[0]
    }
    static var compiledURL: URL { JSONStore.shared.directory.appendingPathComponent("FaceAge.mlmodelc") }
    /// One the user added in Settings (it replaces the built-in one).
    static var hasOwnModel: Bool { fileNames.contains { FileManager.default.fileExists(atPath: JSONStore.shared.directory.appendingPathComponent($0).path) } }
    /// The model that comes with the app (MiVOLO v2, CC BY-NC 4.0: see FaceAge-NOTICE.txt).
    static var bundledURL: URL? { Bundle.main.url(forResource: "FaceAge", withExtension: "mlpackage") }
    static var isInstalled: Bool { hasOwnModel || bundledURL != nil }
    /// The model in use: the user's own, otherwise the built-in one.
    static var sourceURL: URL? { hasOwnModel ? modelURL : bundledURL }

    /// Loads the installed model, compiling it once.
    static func load() throws -> FaceAgeEstimator? {
        guard let sourceURL else { return nil }
        let fm = FileManager.default
        // Recompile when the model changes, or when switching between the user's and the built-in one.
        let marker = compiledURL.appendingPathComponent("source.txt")
        let stamp = "\(sourceURL.path)|\(((try? fm.attributesOfItem(atPath: sourceURL.path)[.modificationDate] as? Date) ?? .distantPast).timeIntervalSince1970)"
        if (try? String(contentsOf: marker, encoding: .utf8)) != stamp {
            let temp = try MLModel.compileModel(at: sourceURL)
            try? fm.removeItem(at: compiledURL)
            try fm.moveItem(at: temp, to: compiledURL)
            try? stamp.write(to: marker, atomically: true, encoding: .utf8)
        }
        let config = MLModelConfiguration()
        // Measured on this model: GPU 0.1 s a face, Neural Engine 0.15 s, CPU 0.5 s.
        config.computeUnits = .cpuAndGPU
        let model = try MLModel(contentsOf: compiledURL, configuration: config)
        guard let constraint = model.modelDescription.inputDescriptionsByName["face"]?.imageConstraint,
              model.modelDescription.outputDescriptionsByName["age"] != nil else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "That model doesn’t take a “face” image and give an “age”."])
        }
        return FaceAgeEstimator(model: model, constraint: constraint)
    }

    /// Copies a model the user picked into the data folder (replacing any earlier one).
    static func install(from url: URL) throws {
        let fm = FileManager.default
        remove()
        let target = JSONStore.shared.directory.appendingPathComponent(url.pathExtension == "mlpackage" ? fileNames[0] : fileNames[1])
        try fm.copyItem(at: url, to: target)
        _ = try load()
    }

    static func remove() {
        for name in fileNames { try? FileManager.default.removeItem(at: JSONStore.shared.directory.appendingPathComponent(name)) }
        try? FileManager.default.removeItem(at: compiledURL)
    }

    private init(model: MLModel, constraint: MLImageConstraint) {
        self.model = model
        self.constraint = constraint
    }

    /// How old the face looks, in years. Nil if the face is too small to read.
    func age(of face: DetectedFace, in image: CGImage) -> Double? {
        guard let crop = Self.crop(face, from: image, side: constraint.pixelsWide),
              let value = try? MLFeatureValue(cgImage: crop, constraint: constraint, options: nil),
              let input = try? MLDictionaryFeatureProvider(dictionary: ["face": value]),
              let out = lock.withLock({ try? model.prediction(from: input) }),
              let age = out.featureValue(for: "age")?.multiArrayValue?[0].doubleValue, age.isFinite else { return nil }
        return max(0, age)
    }

    /// A square around the face, a little larger than the face, padded with gray where it runs off
    /// the picture (the model was trained on letterboxed crops).
    static func crop(_ face: DetectedFace, from image: CGImage, side: Int) -> CGImage? {
        let w = Double(image.width), h = Double(image.height)
        let size = face.size * max(w, h) * 1.2
        guard size >= 24 else { return nil }
        let cx = face.x * w, cy = face.y * h
        let rect = CGRect(x: cx - size / 2, y: cy - size / 2, width: size, height: size)
        let visible = rect.intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard !visible.isNull, visible.width >= 12, visible.height >= 12, let part = image.cropping(to: visible.integral) else { return nil }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 114.0 / 255, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        ctx.interpolationQuality = .high
        let scale = Double(side) / size
        // Core Graphics draws from the bottom-left.
        let x = (visible.minX - rect.minX) * scale
        let y = (rect.maxY - visible.maxY) * scale
        ctx.draw(part, in: CGRect(x: x, y: y, width: visible.width * scale, height: visible.height * scale))
        return ctx.makeImage()
    }
}
