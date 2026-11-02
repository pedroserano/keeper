// Right-click a photo › Show in Photos.
//
// Uses Photos' own photos://asset?identifier=<local identifier> link, as PhotoMetadataGuesser does:
// it reliably selects the photo in Photos, where the scripting "spotlight" command often left the
// selection unchanged, and a link needs no Automation permission.

import AppKit
import Photos
import SwiftUI

enum ShowInPhotos {
    static func url(for asset: PHAsset) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert("-")
        guard let encoded = asset.localIdentifier.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "photos://asset?identifier=\(encoded)")
    }

    /// Returns a problem to show, or nil when Photos was asked to show the photo.
    @MainActor
    static func open(_ asset: PHAsset) async -> String? {
        guard let url = url(for: asset) else { return "Unexpected photo ID." }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        do {
            _ = try await NSWorkspace.shared.open(url, configuration: config)
            return nil
        } catch {
            return "Couldn't open the photo in Photos (\(error.localizedDescription))."
        }
    }
}

extension View {
    /// Right-click menu for a photo.
    func photoContextMenu(_ asset: PHAsset, session: CullingSession) -> some View {
        contextMenu {
            Button("Show in Photos") {
                Task { if let problem = await ShowInPhotos.open(asset) { session.show(problem) } }
            }
        }
    }
}
