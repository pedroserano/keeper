import CoreGraphics
import Foundation
import ImageIO
import Vision
import DateGuessCore

/// On-device image analysis: color/border statistics, scene labels and image fingerprints.
enum ImageAnalyzer {
    /// Vision's requests block their thread while they wait for work they spread across other threads.
    /// Run from many Swift tasks at once, they took every thread in Swift's small shared pool and then
    /// waited on each other forever (the analysis froze at 16 photos). So Vision only ever runs here:
    /// two at a time, on threads of its own.
    private static let visionQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "Keeper.dates.vision"
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .utility
        return q
    }()

    /// Runs Vision work off Swift's shared threads and waits for it without blocking one.
    static func onVisionQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            visionQueue.addOperation { continuation.resume(returning: work()) }
        }
    }

    /// Everything the estimate needs from one image, computed in a single trip to the Vision queue.
    struct Findings: Sendable {
        var featurePrint: Data?
        var statistics: ImageStatistics?
        var sceneLabels: [(identifier: String, confidence: Double)]
    }

    static func analyze(_ image: CGImage, labels: Bool = true) async -> Findings {
        await onVisionQueue {
            Findings(featurePrint: featurePrint(image), statistics: labels ? statistics(image) : nil,
                     sceneLabels: labels ? sceneLabels(image) : [])
        }
    }

    /// Downsamples and computes the color/border statistics used for era clues.
    static func statistics(_ image: CGImage) -> ImageStatistics? {
        let maxEdge = 192
        let scale = min(1, Double(maxEdge) / Double(max(image.width, image.height)))
        let w = max(16, Int(Double(image.width) * scale)), h = max(16, Int(Double(image.height) * scale))
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        return ImageStatistics.compute(rgba: pixels, width: w, height: h)
    }

    /// Vision's image fingerprint, packed (see `EventLinks`). Similar-looking photos have close prints.
    static func featurePrint(_ image: CGImage) -> Data? {
        let request = VNGenerateImageFeaturePrintRequest()
        try? VNImageRequestHandler(cgImage: image).perform([request])
        guard let print = request.results?.first, print.elementType == .float else { return nil }
        let floats = print.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        return EventLinks.pack(floats)
    }

    /// Vision scene classification labels with confidence.
    static func sceneLabels(_ image: CGImage) -> [(identifier: String, confidence: Double)] {
        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return [] }
        return (request.results ?? [])
            .filter { $0.confidence >= 0.2 }
            .prefix(25)
            .map { ($0.identifier, Double($0.confidence)) }
    }
}
