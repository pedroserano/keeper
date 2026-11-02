// The library picker shown at launch, modelled on the one Photos shows when you hold ⌥.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum LibraryFinder {
    /// Photos libraries Spotlight knows about, plus anything in ~/Pictures it may have missed.
    /// Skips temporary, trashed and app-container copies.
    static func find() async -> [URL] {
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
                urls += String(decoding: data, as: UTF8.self)
                    .split(separator: "\n")
                    .map { URL(fileURLWithPath: String($0)) }
            }

            let pictures = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures")
            if let items = try? FileManager.default.contentsOfDirectory(at: pictures, includingPropertiesForKeys: nil) {
                urls += items.filter { $0.pathExtension == "photoslibrary" }
            }

            let hidden = ["/private/var/folders/", "/var/folders/", "/.Trash/", "/Library/Containers/"]
            var seen = Set<String>()
            return urls
                .map(\.standardizedFileURL)
                .filter { url in !hidden.contains { url.path.contains($0) } && seen.insert(url.path).inserted }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }.value
    }

    static func chooseOther() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose a Photos Library"
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType("com.apple.photos.library")].compactMap { $0 }
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures")
        return panel.runModal() == .OK ? panel.url : nil
    }
}

struct LibraryChooserView: View {
    @EnvironmentObject private var model: SpikeModel
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
                    Image(systemName: "photo.on.rectangle.angled")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack {
                            Text(url.deletingPathExtension().lastPathComponent)
                            if url.path == model.lastLibraryPath {
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
                    if let url = LibraryFinder.chooseOther() { Task { await model.open(url) } }
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
            libraries = await LibraryFinder.find()
            searching = false
            selection = libraries.first { $0.path == model.lastLibraryPath } ?? libraries.first
        }
    }
}
