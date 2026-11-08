// R: rotate photos 90° clockwise, non-destructively, the same way Keeper (and Photos' own Rotate) does.
//
// The rotation goes through PhotoKit's editing API:
// - The original file is never touched. Photos keeps the rotated image as an edited version, and
//   Image ▸ Revert to Original in Photos brings the original back.
// - The asset itself isn't replaced, so its date, location, title, keywords, favorite, albums and
//   people all stay. The new image keeps the original's EXIF, TIFF, GPS and IPTC metadata, with
//   only the orientation and pixel size updated.
// - Earlier edits (crops, filters, an earlier rotation) are kept: Photos hands over the photo as
//   currently shown and the rotation goes on top.
// - Live Photos are edited as Live Photos, so they stay live.

import AppKit
import CoreImage
import Foundation
import ImageIO
import Observation
import Photos
import SwiftUI
import UniformTypeIdentifiers

/// A clockwise rotation, in multiples of 90°, applied to a photo as it's currently shown.
enum Rotation: Int, Sendable {
    case none = 0
    case clockwise90 = 90
    case rotate180 = 180
    case clockwise270 = 270

    init(degrees: Int) {
        let snapped = ((Int((Double(degrees) / 90).rounded()) * 90) % 360 + 360) % 360
        self = Rotation(rawValue: snapped) ?? .none
    }

    var degrees: Int { rawValue }
    var inverse: Rotation { Rotation(degrees: 360 - rawValue) }

    var cgOrientation: CGImagePropertyOrientation {
        switch self {
        case .none: .up
        case .clockwise90: .right
        case .rotate180: .down
        case .clockwise270: .left
        }
    }
}

enum PhotoRotator {
    static let formatIdentifier = (Bundle.main.bundleIdentifier ?? "local.keeper") + ".rotation"
    static let formatVersion = "1"

    enum RotateError: LocalizedError {
        case notEditable, noImageData, renderFailed(String)

        var errorDescription: String? {
            switch self {
            case .notEditable: "Photos doesn’t allow this photo to be edited."
            case .noImageData: "Photos couldn’t provide the full-size image (is it still downloading from iCloud?)."
            case .renderFailed(let why): "Couldn’t render the rotated image: \(why)."
            }
        }
    }

    nonisolated(unsafe) private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// Renders the rotated photo and saves it to Photos as an edit.
    static func rotate(_ asset: PHAsset, by rotation: Rotation) async throws {
        guard rotation != .none else { return }
        guard asset.canPerform(.content) else { throw RotateError.notEditable }
        let input = try await contentEditingInput(for: asset)
        let output = PHContentEditingOutput(contentEditingInput: input)
        let adjustment = try JSONSerialization.data(withJSONObject: ["rotateClockwiseDegrees": rotation.degrees])
        output.adjustmentData = PHAdjustmentData(formatIdentifier: formatIdentifier, formatVersion: formatVersion,
                                                 data: adjustment)
        if asset.mediaSubtypes.contains(.photoLive), let live = PHLivePhotoEditingContext(livePhotoEditingInput: input) {
            try await renderLivePhoto(live, rotation: rotation, to: output)
        } else {
            try await renderStill(input, rotation: rotation, to: output)
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest(for: asset).contentEditingOutput = output
        }
    }

    /// The photo as currently shown (earlier edits included), downloading it from iCloud if need be.
    private static func contentEditingInput(for asset: PHAsset) async throws -> PHContentEditingInput {
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = true
        // Never claim to understand another editor's adjustments: Photos then hands over its current
        // rendered version, so earlier edits stay, and Revert to Original still restores the original.
        options.canHandleAdjustmentData = { _ in false }
        return try await withCheckedThrowingContinuation { continuation in
            asset.requestContentEditingInput(with: options) { input, info in
                if let input {
                    continuation.resume(returning: input)
                } else {
                    continuation.resume(throwing: (info[PHContentEditingInputErrorKey] as? Error) ?? RotateError.noImageData)
                }
            }
        }
    }

    private static func renderStill(_ input: PHContentEditingInput, rotation: Rotation,
                                    to output: PHContentEditingOutput) async throws {
        guard let sourceURL = input.fullSizeImageURL else { throw RotateError.noImageData }
        let orientation = input.fullSizeImageOrientation
        nonisolated(unsafe) let output = output
        try await Task.detached(priority: .userInitiated) {
            try autoreleasepool {
                guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
                      let image = CIImage(contentsOf: sourceURL, options: [.applyOrientationProperty: false])
                else { throw RotateError.noImageData }
                let properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]

                let rotated = rotatedImage(image, exifOrientation: orientation, by: rotation)

                let colorSpace = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
                    ?? CGColorSpace(name: CGColorSpace.sRGB)!
                let deep = ((properties[kCGImagePropertyDepth] as? Int) ?? 8) > 8
                guard let cgImage = ciContext.createCGImage(rotated, from: rotated.extent,
                                                            format: deep ? .RGBA16 : .RGBA8, colorSpace: colorSpace)
                else { throw RotateError.renderFailed("Core Image returned no image") }

                let type = output.defaultRenderedContentType ?? .jpeg
                let destinationURL = try output.renderedContentURL(for: type)
                guard let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL,
                                                                        type.identifier as CFString, 1, nil)
                else { throw RotateError.renderFailed("can’t write \(type.identifier)") }
                var metadata = metadata(properties, width: cgImage.width, height: cgImage.height)
                metadata[kCGImageDestinationLossyCompressionQuality] = 0.95
                CGImageDestinationAddImage(destination, cgImage, metadata as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { throw RotateError.renderFailed("encoding failed") }
            }
        }.value
    }

    /// The pixels turned to how Photos shows them, then rotated on top, with the origin back at zero.
    static func rotatedImage(_ image: CIImage, exifOrientation: Int32, by rotation: Rotation) -> CIImage {
        let rotated = image.oriented(forExifOrientation: exifOrientation).oriented(rotation.cgOrientation)
        return rotated.transformed(by: CGAffineTransform(translationX: -rotated.extent.minX, y: -rotated.extent.minY))
    }

    /// The source's metadata with the orientation reset (the pixels are now upright) and the size updated.
    static func metadata(_ properties: [CFString: Any], width: Int, height: Int) -> [CFString: Any] {
        var metadata = properties
        for key in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyDepth,
                    kCGImagePropertyColorModel, kCGImagePropertyHasAlpha, kCGImagePropertyProfileName] {
            metadata.removeValue(forKey: key)
        }
        metadata[kCGImagePropertyOrientation] = 1
        if var tiff = metadata[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            metadata[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = metadata[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = width
            exif[kCGImagePropertyExifPixelYDimension] = height
            // Subject-area coordinates refer to the old pixel grid.
            exif.removeValue(forKey: kCGImagePropertyExifSubjectArea)
            exif.removeValue(forKey: kCGImagePropertyExifSubjectLocation)
            metadata[kCGImagePropertyExifDictionary] = exif
        }
        return metadata
    }

    private static func renderLivePhoto(_ context: PHLivePhotoEditingContext, rotation: Rotation,
                                        to output: PHContentEditingOutput) async throws {
        // Frames arrive in the stored pixel orientation and Photos re-applies `context.orientation` when
        // it shows the result. A rotation commutes with that, but a mirrored orientation reverses it.
        let mirrored: [CGImagePropertyOrientation] = [.upMirrored, .downMirrored, .leftMirrored, .rightMirrored]
        let orientation = (mirrored.contains(context.orientation) ? rotation.inverse : rotation).cgOrientation
        context.frameProcessor = { frame, _ in
            let image = frame.image.oriented(orientation)
            return image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            context.saveLivePhoto(to: output, options: nil) { success, error in
                if success { continuation.resume() }
                else { continuation.resume(throwing: error ?? RotateError.renderFailed("the Live Photo couldn’t be saved")) }
            }
        }
    }
}

/// Bumped when a photo's image changes here (a rotation), so thumbnails showing it load again.
@MainActor @Observable
final class ImageRevisions {
    static let shared = ImageRevisions()
    private(set) var revisions: [String: Int] = [:]

    func revision(_ id: String) -> Int { revisions[id] ?? 0 }
    func bump(_ id: String) { revisions[id, default: 0] += 1 }
}

/// Single-key commands: R rotates the selected photos, Space checks them, / shows the shortcuts. The
/// most recently shown screen (a sheet over the Review grid, say) gets the key first; typing in a
/// text field never triggers them.
@MainActor
final class KeyCommands {
    static let shared = KeyCommands()
    private var handlers: [(id: UUID, key: String, perform: () -> Bool)] = []
    private var monitor: Any?

    func push(_ id: UUID, key: String, _ perform: @escaping () -> Bool) {
        handlers.removeAll { $0.id == id }
        handlers.append((id, key, perform))
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Local monitors run on the main thread.
            nonisolated(unsafe) let event = event
            let handled = MainActor.assumeIsolated { KeyCommands.shared.handle(event) }
            return handled ? nil : event
        }
    }

    func pop(_ id: UUID) { handlers.removeAll { $0.id == id } }

    private func handle(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              !event.isARepeat || (123...126).contains(event.keyCode),   // arrow keys repeat
              let window = NSApp.keyWindow,
              !(window.firstResponder is NSText) else { return false }
        // "r" whether or not Shift is down; "?" as typed with Shift-/.
        let keys = [event.charactersIgnoringModifiers?.lowercased(), event.characters].compactMap { $0 }
        for handler in handlers.reversed() where keys.contains(handler.key) && handler.perform() { return true }
        return false
    }
}

/// Holds the latest closure, so the key always acts on what the screen shows now.
@MainActor
private final class KeyHandlerBox {
    var perform: () -> Bool = { false }
}

struct KeyCommandModifier: ViewModifier {
    var key: String
    var perform: () -> Bool
    @State private var id = UUID()
    @State private var box = KeyHandlerBox()

    func body(content: Content) -> some View {
        box.perform = perform
        let box = box, key = key, id = id
        return content
            .onAppear { KeyCommands.shared.push(id, key: key) { box.perform() } }
            .onDisappear { KeyCommands.shared.pop(id) }
    }
}

extension View {
    /// Handles R on this screen. Return false to let a screen underneath have it.
    func onRotateKey(_ perform: @escaping () -> Bool) -> some View {
        modifier(KeyCommandModifier(key: "r", perform: perform))
    }

    /// Handles Space on this screen. Return false to let a screen underneath have it.
    func onSpaceKey(_ perform: @escaping () -> Bool) -> some View {
        modifier(KeyCommandModifier(key: " ", perform: perform))
    }

    /// Handles / (the key marked ?) on this screen, with or without Shift. Return false to let a
    /// screen underneath have it.
    func onHelpKey(_ perform: @escaping () -> Bool) -> some View {
        modifier(KeyCommandModifier(key: "/", perform: perform))
            .modifier(KeyCommandModifier(key: "?", perform: perform))
    }
}
