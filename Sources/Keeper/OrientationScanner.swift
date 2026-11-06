// Finds sideways and upside-down photos in the background, for Sideways Photos. Modelled on
// ApplePhotosRotator's ScanEngine.
//
// Every photo is checked once, newest first, from a small local preview (nothing is downloaded);
// results are saved every 250 photos, so quitting loses only a few seconds of work and the next run
// carries on. Photos that change later (an edit, a rotation) are checked again. Pauses while the
// Mac is running hot.

import Foundation
import os
import Photos
import KeeperKit
import KeeperOrientation
import AppKit

enum OrientationScanner {
    /// Long edge of the image handed to Vision: big enough for small faces and text, still quick.
    static let analysisSize = 768
    static let concurrency = 4

    struct Result: Sendable {
        let checked: Int
        let networkLoaded: Bool
    }

    /// `progress(done, total)` is called after each batch; return false from `keepGoing` to stop.
    static func run(library: PhotoLibrary, store: DecisionStore,
                    progress: @escaping @Sendable (Int, Int) async -> Void,
                    keepGoing: @escaping @Sendable () async -> Bool) async -> Result? {
        // Loading may compile the network the first time.
        let network = OrientationNetDetector.builtIn
        if network == nil { log.notice("orientation: the orientation network didn't load; using faces, people and text") }
        let analyzer = OrientationAnalyzer(network: network)

        let fetch = library.fetch(.allPhotos, newestFirst: true)
        let scanned = (try? store.orientationScanned()) ?? [:]
        let total = fetch.count
        var index = 0
        var analysed = 0
        await progress(0, total)

        while index < total {
            guard await keepGoing() else { return nil }
            while ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
                try? await Task.sleep(for: .seconds(20))
                guard await keepGoing() else { return nil }
            }
            // The next 250 photos that need checking (skipping costs almost nothing).
            var todo: [PHAsset] = []
            while index < total, todo.count < 250 {
                let asset = fetch.object(at: index)
                index += 1
                if needsCheck(asset, scanned: scanned) { todo.append(asset) }
            }
            var records: [OrientationRecord] = []
            await withTaskGroup(of: OrientationRecord.self) { group in
                var next = todo.makeIterator()
                func add() -> Bool {
                    guard let asset = next.next() else { return false }
                    group.addTask { await check(asset, analyzer: analyzer) }
                    return true
                }
                for _ in 0..<concurrency where add() {}
                while let record = await group.next() {
                    records.append(record)
                    _ = add()
                }
            }
            if !records.isEmpty {
                do { try store.saveOrientation(records) } catch {
                    log.error("orientation: couldn't save: \(error.localizedDescription, privacy: .public)")
                }
            }
            analysed += records.count
            await progress(index, total)
        }
        log.notice("orientation: checked \(analysed) photos this run, \(total) in the library")
        return Result(checked: total, networkLoaded: network != nil)
    }

    static func modDate(_ asset: PHAsset) -> Double {
        (asset.modificationDate ?? asset.creationDate)?.timeIntervalSince1970 ?? 0
    }

    /// New or changed since it was checked; screenshots and photos Photos won't let us edit are left out.
    private static func needsCheck(_ asset: PHAsset, scanned: [String: Double]) -> Bool {
        if let date = scanned[asset.localIdentifier], abs(date - modDate(asset)) < 1 { return false }
        if asset.mediaSubtypes.contains(.photoScreenshot) { return false }
        return asset.canPerform(.content)
    }

    /// The image request and Vision both block, so they run on a GCD worker rather than tying up
    /// Swift's concurrency pool.
    private static func check(_ asset: PHAsset, analyzer: OrientationAnalyzer) async -> OrientationRecord {
        let id = asset.localIdentifier, date = modDate(asset)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let record: OrientationRecord = autoreleasepool {
                    guard let image = OrientationAnalyzer.analysisImage(for: asset, longEdge: analysisSize) else {
                        return OrientationRecord(assetID: id, modDate: date, status: .unavailable)
                    }
                    do {
                        let result = try analyzer.analyze(image)
                        return OrientationRecord(assetID: id, modDate: date, status: result.decision.status,
                                                 rotation: result.decision.rotation,
                                                 confidence: result.decision.confidence, evidence: result.summary)
                    } catch {
                        return OrientationRecord(assetID: id, modDate: date, status: .failed,
                                                 evidence: error.localizedDescription)
                    }
                }
                continuation.resume(returning: record)
            }
        }
    }
}

extension OrientationAnalyzer {
    /// A small image of the photo as Photos shows it (edits and orientation applied), which is what
    /// you judge as sideways. Local only: a photo with no local preview returns nil. **Blocking**:
    /// call it off the main thread.
    static func analysisImage(for asset: PHAsset, longEdge: Int) -> CGImage? {
        let size = CGSize(width: longEdge, height: longEdge)
        for mode in [PHImageRequestOptionsDeliveryMode.highQualityFormat, .fastFormat] {
            let options = PHImageRequestOptions()
            options.isSynchronous = true
            options.deliveryMode = mode
            options.resizeMode = .fast
            options.version = .current
            options.isNetworkAccessAllowed = false
            var result: CGImage?
            PHImageManager.default().requestImage(for: asset, targetSize: size, contentMode: .aspectFit,
                                                  options: options) { image, _ in
                result = image.flatMap { displayedPixels(of: $0, maxLongEdge: longEdge) }
            }
            if let result, result.width >= 64, result.height >= 64 { return result }
        }
        return nil
    }

    /// The image as it appears on screen, as an upright bitmap. Not `NSImage.cgImage(forProposedRect:)`:
    /// that can hand back the stored pixels without the orientation they're shown with (a portrait
    /// iPhone photo is stored sideways, with a tag saying to turn it), so every such photo would be
    /// checked sideways. Drawing applies whatever the image applies on screen.
    private static func displayedPixels(of image: NSImage, maxLongEdge: Int) -> CGImage? {
        let displayed = image.size
        guard displayed.width > 0, displayed.height > 0 else { return nil }
        let scale = min(1, CGFloat(maxLongEdge) / max(displayed.width, displayed.height))
        let width = max(1, Int((displayed.width * scale).rounded()))
        let height = max(1, Int((displayed.height * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}
