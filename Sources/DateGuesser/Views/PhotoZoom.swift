import SwiftUI

/// A photo shown filling the window, like Quick Look: click a thumbnail or press Space over it to
/// open, Esc or Space to go back, ← and → to step through the photos it was shown with.
@MainActor
@Observable
final class PhotoZoom {
    static let shared = PhotoZoom()

    struct Request: Equatable {
        var ids: [String]
        var index: Int
        /// Which window shows it: the main window or a sheet.
        var scope: String
        var id: String { ids[index] }
    }

    var request: Request?
    /// The thumbnail under the pointer, for Space.
    @ObservationIgnored var hovered: (id: String, ids: [String], scope: String)?

    func open(_ id: String, in ids: [String], scope: String) {
        let list = ids.contains(id) ? ids : [id]
        request = Request(ids: list, index: list.firstIndex(of: id) ?? 0, scope: scope)
    }

    /// Space: zooms the thumbnail under the pointer.
    func openHovered(scope: String) -> Bool {
        guard request == nil, let h = hovered, h.scope == scope else { return false }
        open(h.id, in: h.ids, scope: scope)
        return true
    }

    func close() { request = nil }

    func step(_ delta: Int) {
        guard var r = request else { return }
        r.index = min(max(0, r.index + delta), r.ids.count - 1)
        request = r
    }
}

private struct ZoomScopeKey: EnvironmentKey {
    static let defaultValue = "main"
}

extension EnvironmentValues {
    /// Which window a zoomed photo opens in (sheets are their own windows).
    var zoomScope: String {
        get { self[ZoomScopeKey.self] }
        set { self[ZoomScopeKey.self] = newValue }
    }
}

private struct Zoomable: ViewModifier {
    @Environment(\.zoomScope) private var scope
    var id: String
    var ids: [String]
    var openOnClick: Bool

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                let zoom = PhotoZoom.shared
                if inside { zoom.hovered = (id, ids, scope) } else if zoom.hovered?.id == id { zoom.hovered = nil }
            }
            .onTapGesture(count: openOnClick ? 1 : 2) { PhotoZoom.shared.open(id, in: ids, scope: scope) }
    }
}

extension View {
    /// Click (or double-click, when a click already does something) or Space over it shows the photo
    /// filling the window; ← and → then step through `ids`.
    func zoomable(_ id: String, in ids: [String], openOnClick: Bool = true) -> some View {
        modifier(Zoomable(id: id, ids: ids, openOnClick: openOnClick))
    }

    /// Shows zoomed photos for this window. Put it on the window's root view (or a sheet's).
    func photoZoomHost(scope: String = "main") -> some View {
        environment(\.zoomScope, scope)
            .overlay { PhotoZoomOverlay(scope: scope) }
            .onSpaceKey { PhotoZoom.shared.openHovered(scope: scope) }
    }
}

private struct PhotoZoomOverlay: View {
    var scope: String

    var body: some View {
        if let request = PhotoZoom.shared.request, request.scope == scope {
            ZoomedPhoto(request: request)
                .transition(.opacity)
        }
    }
}

private struct ZoomedPhoto: View {
    var request: PhotoZoom.Request
    @State private var loader = ThumbnailLoader()

    var body: some View {
        let zoom = PhotoZoom.shared
        ZStack {
            Rectangle().fill(.black.opacity(0.92))
            if let image = loader.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(24)
            } else {
                ProgressView().controlSize(.large).tint(.white)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { zoom.close() }
        .overlay(alignment: .bottom) {
            HStack(spacing: 14) {
                if request.ids.count > 1 {
                    Button { zoom.step(-1) } label: { Image(systemName: "chevron.left") }
                        .disabled(request.index == 0)
                    Text("\((request.index + 1).formatted()) of \(request.ids.count.formatted())")
                        .monospacedDigit()
                    Button { zoom.step(1) } label: { Image(systemName: "chevron.right") }
                        .disabled(request.index == request.ids.count - 1)
                }
                Text("Esc or Space to go back").foregroundStyle(.white.opacity(0.6))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.white)
            .font(.callout)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.black.opacity(0.5), in: Capsule())
            .padding(14)
        }
        .onAppear { loader.load(request.id, side: 2400) }
        .onChange(of: request.id) { loader.load(request.id, side: 2400) }
        .onDisappear { loader.cancel() }
        // Pushed last, so these win over the screen underneath while it's open.
        .onSpaceKey { zoom.close(); return true }
        .modifier(KeyCommandModifier(key: "\u{1b}", perform: { zoom.close(); return true }))
        .modifier(KeyCommandModifier(key: String(UnicodeScalar(NSLeftArrowFunctionKey)!), perform: { zoom.step(-1); return true }))
        .modifier(KeyCommandModifier(key: String(UnicodeScalar(NSRightArrowFunctionKey)!), perform: { zoom.step(1); return true }))
    }
}
