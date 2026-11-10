// Right-click a photo › Show in Photos.
//
// Uses Photos' own photos://asset?identifier=<local identifier> link, as PhotoMetadataGuesser does:
// it reliably selects the photo in Photos, where the scripting "spotlight" command often left the
// selection unchanged, and a link needs no Automation permission.

import AppKit
import Photos
import SwiftUI
import DateGuesser
import KeeperUI

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
    /// Right-click menu for a photo: the same items, in the same order, as on every screen.
    func photoContextMenu(_ asset: PHAsset, session: CullingSession) -> some View {
        contextMenu {
            let ids = session.photosForMenu(asset)
            let id = asset.localIdentifier
            let hidden = session.decision(asset).hidden
            PhotoMenu(
                count: ids.count,
                isSelected: session.selectsPhotos ? session.selectedPhotos.contains(id) : nil,
                select: { session.setPhotoSelected(id, $0) },
                getInfo: { session.infoAsset = asset },
                showInPhotos: { Task { if let problem = await ShowInPhotos.open(asset) { session.show(problem) } } },
                setDate: { session.requestPhotoInfo(.date, for: asset) },
                setLocation: { session.requestPhotoInfo(.location, for: asset) },
                rotate: { session.rotateFromMenu(asset) },
                hide: PhotoMenu.Item(hidden ? "Unhide in Photos  H" : "Hide in Photos  H") { session.toggleHidden(asset) })
        }
    }
}
