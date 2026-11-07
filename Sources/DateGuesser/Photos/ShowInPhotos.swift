import AppKit
import Foundation

/// Opens one photo in the Photos app (e.g. to name a face there). Nothing in the library is changed.
///
/// Uses Photos' own `photos://asset?identifier=<local identifier>` link. Tested against a real library,
/// it reliably selects the photo, while the scripting "spotlight" command often left the selection
/// unchanged. A link also needs no Automation permission.
enum ShowInPhotos {
    static func url(for assetID: String) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert("-")
        guard let encoded = assetID.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "photos://asset?identifier=\(encoded)")
    }

    /// Returns a problem to show the user, or nil when Photos was asked to show the photo.
    @MainActor
    static func open(_ assetID: String) async -> String? {
        guard let url = url(for: assetID) else { return "Unexpected photo ID." }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        do {
            _ = try await NSWorkspace.shared.open(url, configuration: config)
            return nil
        } catch {
            return "Couldn’t open the photo in Photos (\(error.localizedDescription))."
        }
    }
}
