import AppKit
import SwiftUI
import UniformTypeIdentifiers
import KeeperKit

@main
struct KeeperApp: App {
    @StateObject private var model: AppModel

    init() {
        LegacyData.migrate()
        _model = StateObject(wrappedValue: AppModel())
    }

    var body: some Scene {
        WindowGroup("Keeper") {
            RootView().environmentObject(model)
        }
        // Compact for choosing a library, large for culling.
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Choose Library…") { model.chooseLibrary() }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { model.undo() }
                    .keyboardShortcut("z")
                Button("Redo") { model.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(before: .toolbar) {
                Button("Grid") { model.cullingSession?.mode = .grid }.keyboardShortcut("1")
                Button("Single Photo") { model.cullingSession?.mode = .single }.keyboardShortcut("2")
                Button("Compare") { model.cullingSession?.mode = .compare }.keyboardShortcut("3")
                Divider()
                Button("Get Info") {
                    if let s = model.cullingSession, s.dates == nil { s.infoAsset = s.current }
                }
                .keyboardShortcut("i")
                Divider()
                Toggle("Newest First", isOn: Binding(get: { model.session?.newestFirst ?? false },
                                                     set: { model.session?.newestFirst = $0 }))
                Toggle("Download Originals from iCloud for Zoom",
                       isOn: Binding(get: { model.session?.allowDownloads ?? false },
                                     set: { model.session?.allowDownloads = $0 }))
                Divider()
            }
        }

        Settings { SettingsView().environmentObject(model) }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    private let compact = CGSize(width: 520, height: 400)

    var body: some View {
        switch model.state {
        case .choosing:
            LibraryChooserView().frame(width: compact.width, height: compact.height)
        case .opening(let url):
            ProgressView("Opening “\(url.deletingPathExtension().lastPathComponent)”…")
                .frame(width: compact.width, height: compact.height)
        case .problem(let url, let problem):
            ProblemView(url: url, problem: problem).frame(width: compact.width, height: compact.height)
        case .ready(let session):
            // A new identity per session, so its key monitor never points at an old library.
            ContentView(session: session).id(ObjectIdentifier(session)).frame(minWidth: 1000, minHeight: 680)
        }
    }
}

// MARK: - Choosing a library

enum LibraryFinder {
    /// Photos libraries Spotlight knows about, plus anything in ~/Pictures it may have missed and
    /// the last one used (Spotlight often skips external drives). Skips temporary, trashed and
    /// app-container copies.
    static func find(lastUsed: String?) async -> [URL] {
        await Task.detached {
            var urls: [URL] = []
            let mdfind = Process()
            mdfind.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
            mdfind.arguments = ["kMDItemContentType == 'com.apple.photos.library'"]
            let pipe = Pipe()
            mdfind.standardOutput = pipe
            mdfind.standardError = FileHandle.nullDevice
            if (try? mdfind.run()) != nil {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                mdfind.waitUntilExit()
                urls += String(decoding: data, as: UTF8.self).split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
            }
            let pictures = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures")
            if let items = try? FileManager.default.contentsOfDirectory(at: pictures, includingPropertiesForKeys: nil) {
                urls += items.filter { $0.pathExtension == "photoslibrary" }
            }
            if let lastUsed, FileManager.default.fileExists(atPath: lastUsed) { urls.append(URL(fileURLWithPath: lastUsed)) }
            let hidden = ["/private/var/folders/", "/var/folders/", "/.Trash/", "/Library/Containers/"]
            var seen = Set<String>()
            return urls
                .map(\.standardizedFileURL)
                .filter { url in !hidden.contains { url.path.contains($0) } && seen.insert(url.path).inserted }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }.value
    }

    /// Starts in the folder holding the System Photo Library (or the last library used), if known.
    static func chooseOther(near library: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose a Photos Library"
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType("com.apple.photos.library")].compactMap { $0 }
        panel.directoryURL = library?.deletingLastPathComponent()
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures")
        return panel.runModal() == .OK ? panel.url : nil
    }
}

struct LibraryChooserView: View {
    @EnvironmentObject private var model: AppModel
    @State private var libraries: [URL] = []
    @State private var selection: URL?
    @State private var searching = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Choose Library").font(.headline)
                Text("Switch libraries later with File › Choose Library (⌘O).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            List(libraries, id: \.self, selection: $selection) { url in
                HStack(spacing: 10) {
                    Image(systemName: "photo.on.rectangle.angled").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack {
                            Text(url.deletingPathExtension().lastPathComponent)
                            if url == model.systemLibrary {
                                Text("System Photo Library").font(.caption).foregroundStyle(.secondary)
                            } else if url.path == model.lastLibraryPath {
                                Text("Last used").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Text(url.deletingLastPathComponent().path(percentEncoded: false))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(.vertical, 2)
                .contextMenu {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
            }
            .contextMenu(forSelectionType: URL.self) { _ in } primaryAction: { urls in
                if let url = urls.first { Task { await model.open(url) } }
            }
            .overlay {
                if searching {
                    ProgressView("Looking for libraries…")
                } else if libraries.isEmpty {
                    ContentUnavailableView("No libraries found", systemImage: "photo.on.rectangle",
                                           description: Text("Use Other Library… to find one."))
                }
            }
            HStack {
                Button("Other Library…") {
                    if let url = LibraryFinder.chooseOther(near: model.systemLibrary ?? model.lastLibraryPath.map { URL(fileURLWithPath: $0) }) { Task { await model.open(url) } }
                }
                Spacer()
                Button("Choose Library") {
                    if let url = selection { Task { await model.open(url) } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
        }
        .padding(20)
        .task {
            libraries = await LibraryFinder.find(lastUsed: model.lastLibraryPath)
            selection = libraries.first { $0.path == model.lastLibraryPath } ?? libraries.first
            await model.findSystemLibrary(among: libraries)
            searching = false
            if let system = model.systemLibrary {
                libraries = [system] + libraries.filter { $0 != system }
                selection = system
            }
        }
    }
}

struct ProblemView: View {
    @EnvironmentObject private var model: AppModel
    let url: URL
    let problem: AppModel.Problem

    private var name: String { url.deletingPathExtension().lastPathComponent }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 32)).foregroundStyle(.secondary)
            Text(title).font(.headline).multilineTextAlignment(.center)
            Text(detail).multilineTextAlignment(.center).foregroundStyle(.secondary)
            HStack {
                Button("Choose Another Library") { model.chooseLibrary() }
                switch problem {
                case .photosAccess:
                    Button("Open Privacy Settings") { model.openPhotosPrivacySettings() }
                case .fullDiskAccess:
                    Button("Open Privacy Settings") { model.openFullDiskAccessSettings() }
                    Button("Continue Without Checking") { Task { await model.open(url, skipSystemCheck: true) } }
                case .notSystemLibrary:
                    Button("Open in Photos") { NSWorkspace.shared.open(url) }
                case .other:
                    EmptyView()
                }
                Button("Try Again") { Task { await model.open(url) } }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
    }

    private var icon: String {
        switch problem {
        case .photosAccess, .fullDiskAccess: "lock.shield"
        case .notSystemLibrary: "photo.on.rectangle.angled"
        case .other: "exclamationmark.triangle"
        }
    }

    private var title: String {
        switch problem {
        case .photosAccess: "Keeper needs access to Photos"
        case .fullDiskAccess: "Keeper can't check “\(name)”"
        case .notSystemLibrary: "“\(name)” isn't your System Photo Library"
        case .other: "Can't open “\(name)”"
        }
    }

    private var detail: String {
        switch problem {
        case .photosAccess:
            "Turn on Keeper in System Settings › Privacy & Security › Photos, then click Try Again."
        case .fullDiskAccess(let message):
            message + " Without it, Keeper can't confirm this is the library Photos is using."
        case .notSystemLibrary:
            """
            macOS only lets apps work with the System Photo Library. Open this library in Photos, choose \
            Photos › Settings › General › Use as System Photo Library, then click Try Again.
            """
        case .other(let message):
            message
        }
    }
}

/// Keeper used to be called Winnow. The first launch after the rename moves Winnow's data and
/// settings over, so nothing is lost: each library's database, the reports, and the settings
/// (the last library, keeper rules, sliders). Photos' "Winnow – Rejected" album is renamed when a
/// library opens (see PhotoLibrary).
enum LegacyData {
    static func migrate() {
        let fm = FileManager.default
        let old = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Winnow", isDirectory: true)
        if fm.fileExists(atPath: old.path), !fm.fileExists(atPath: DecisionStore.directory.path) {
            try? fm.moveItem(at: old, to: DecisionStore.directory)
        }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "movedFromWinnow") else { return }
        if let settings = defaults.persistentDomain(forName: "local.winnow.app") {
            for (key, value) in settings where defaults.object(forKey: key) == nil { defaults.set(value, forKey: key) }
        }
        defaults.set(true, forKey: "movedFromWinnow")
    }
}
