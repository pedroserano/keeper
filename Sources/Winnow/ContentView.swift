import Photos
import SwiftUI
import WinnowKit

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: CullingSession
    @State private var showingDelete = false
    @State private var showingShortcuts = false
    @FocusState private var keysFocused: Bool

    var body: some View {
        NavigationSplitView {
            Sidebar(session: session, library: session.library)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            detail
                .focusable()
                .focusEffectDisabled()
                .focused($keysFocused)
                .onKeyPress(phases: .down, action: handleKey)
                .simultaneousGesture(TapGesture().onEnded { keysFocused = true })
                .onAppear { keysFocused = true }
                .onChange(of: session.source) { keysFocused = true }
                .overlay(alignment: .top) { toast }
                .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar(session: session) }
                .toolbar { toolbar }
                .navigationTitle(session.source.title)
                .navigationSubtitle(session.libraryName)
        }
        .environmentObject(session)
        .environmentObject(session.library)
        .sheet(isPresented: $showingDelete) { DeleteQueueSheet().environmentObject(session).environmentObject(session.library) }
        .sheet(isPresented: $showingShortcuts) { ShortcutsSheet() }
    }

    @ViewBuilder private var detail: some View {
        if session.loading {
            ProgressView("Filtering \(session.source.title)…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if session.list.isEmpty {
            ContentUnavailableView(emptyTitle, systemImage: "photo.on.rectangle",
                                   description: Text(emptyDetail))
        } else {
            switch session.mode {
            case .grid: GridView()
            case .single: SingleView()
            case .compare: CompareView()
            }
        }
    }

    private var emptyTitle: String {
        session.filter == .all ? "No photos in \(session.source.title)" : "No \(session.filter.rawValue.lowercased()) photos"
    }

    private var emptyDetail: String {
        session.source == .unreviewed && session.filter == .all
            ? "You've looked at every photo in this library."
            : "Choose another source or filter."
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("View", selection: $session.mode) {
                Label("Grid", systemImage: "square.grid.2x2").tag(CullingSession.Mode.grid)
                Label("Single", systemImage: "square").tag(CullingSession.Mode.single)
                Label("Compare", systemImage: "rectangle.split.2x1").tag(CullingSession.Mode.compare)
            }
            .pickerStyle(.segmented)
            .help("Grid, single photo or compare (⌘1, ⌘2, ⌘3)")
        }
        ToolbarItem {
            Picker("Show", selection: $session.filter) {
                ForEach(CullingSession.Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
            .help("Which photos to show")
        }
        ToolbarItem {
            Button { showingDelete = true } label: {
                Label("Delete Rejected (\(session.rejectCount))", systemImage: "trash")
            }
            .disabled(session.rejectCount == 0)
            .help("Review and delete the photos you rejected")
        }
        ToolbarItem {
            Button { showingShortcuts = true } label: { Label("Keyboard Shortcuts", systemImage: "keyboard") }
                .help("Keyboard shortcuts (?)")
        }
    }

    @ViewBuilder private var toast: some View {
        if let message = session.message {
            Text(message)
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 10)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        if press.modifiers.contains(.command) { return .ignored } // leave ⌘ shortcuts to the menus
        let s = session
        switch press.key {
        case .leftArrow: s.move(by: -1)
        case .rightArrow: s.move(by: 1)
        case .upArrow: s.move(by: s.mode == .grid ? -s.gridColumns : -1)
        case .downArrow: s.move(by: s.mode == .grid ? s.gridColumns : 1)
        case .return: s.mode = s.mode == .grid ? .single : .grid
        case .escape:
            if s.zoomed { s.zoomed = false } else if s.mode != .grid { s.mode = .grid } else { return .ignored }
        case .space:
            if s.mode == .grid { s.mode = .single } else { s.toggleZoom(onFace: false) }
        case .delete, .deleteForward: s.perform(.reject)
        default:
            switch press.characters.lowercased() {
            case "0", "1", "2", "3", "4", "5": s.perform(.rate(Int(press.characters)!))
            case "p": s.perform(.pick)
            case "x": s.perform(.reject)
            case "u": s.perform(.clearFlag)
            case "h": s.perform(.toggleHidden)
            case "z": s.toggleZoom(onFace: true)
            case "c": s.mode = s.mode == .compare ? .single : .compare
            case "k": s.keepFocusedRejectRest()
            case "?", "/": showingShortcuts = true
            default: return .ignored
            }
        }
        return .handled
    }
}

struct Sidebar: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: CullingSession
    @ObservedObject var library: PhotoLibrary

    var body: some View {
        List(selection: Binding<Source?>(get: { session.source }, set: { if let s = $0 { session.select(s) } })) {
            Section("Library") {
                row(.allPhotos)
                row(.unreviewed)
                row(.favorites)
            }
            Section("Media Types") {
                row(.screenshots)
                row(.bursts)
            }
            if !library.albums.isEmpty {
                Section("Albums") {
                    ForEach(library.albums, id: \.localIdentifier) { album in
                        row(.album(id: album.localIdentifier, title: album.localizedTitle ?? "Untitled"))
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Image(systemName: "photo.on.rectangle.angled").foregroundStyle(.secondary)
                Text(session.libraryName).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Change…") { model.chooseLibrary() }
                    .buttonStyle(.link)
            }
            .font(.callout)
            .padding(10)
        }
    }

    private func row(_ source: Source) -> some View {
        Label(source.title, systemImage: source.systemImage)
            .badge(session.counts[source] ?? 0)
            .tag(source)
    }
}

struct StatusBar: View {
    @ObservedObject var session: CullingSession

    var body: some View {
        HStack(spacing: 14) {
            if !session.list.isEmpty {
                Text("\(session.cursor + 1) of \(session.list.count)").monospacedDigit()
            }
            Label("\(session.pickCount) picked", systemImage: "checkmark.circle")
            Label("\(session.rejectCount) rejected", systemImage: "xmark.circle")
            Spacer()
            if session.zoomed { Text("100%").monospacedDigit() }
            Text("? for shortcuts").foregroundStyle(.tertiary)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

/// Flag and stars, drawn over a photo.
struct DecisionBadge: View {
    let decision: Decision
    var large = false

    var body: some View {
        HStack(spacing: large ? 8 : 4) {
            switch decision.flag {
            case .pick: Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, .green)
            case .reject: Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .red)
            case .none: EmptyView()
            }
            if decision.rating > 0 {
                Text(String(repeating: "★", count: decision.rating))
                    .foregroundStyle(.yellow)
                    .shadow(radius: 1)
            }
        }
        .font(large ? .title3 : .caption)
    }
}
