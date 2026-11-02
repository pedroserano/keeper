// Winnow Spike — Phase 0 prototype.
//
// Pick a Photos library from a window (like holding ⌥ when opening Photos), then:
//   1. See which of Apple Photos' own score columns this macOS version has.
//   2. Time PhotoKit image loading and Vision aesthetic scoring.
//   3. Compare Vision's ranking with Photos' own overall aesthetic score.
//   4. Try a batched PhotoKit delete (off by default; test library only).

import SwiftUI
import WinnowCore

@main
struct WinnowSpikeApp: App {
    @StateObject private var model = SpikeModel()

    var body: some Scene {
        WindowGroup("Winnow Spike") {
            RootView()
                .environmentObject(model)
        }
        // The window follows each view's size: compact for the chooser, large for the results.
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Choose Library…") { model.chooseAnotherLibrary() }
                    .keyboardShortcut("o")
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: SpikeModel

    var body: some View {
        switch model.state {
        case .choosing:
            LibraryChooserView()
                .frame(width: compactSize.width, height: compactSize.height)
        case .opening(let url):
            ProgressView("Opening “\(url.deletingPathExtension().lastPathComponent)”…")
                .frame(width: compactSize.width, height: compactSize.height)
        case .failed(let url, let message, let needsFullDiskAccess):
            OpenFailedView(url: url, message: message, needsFullDiskAccess: needsFullDiskAccess)
                .frame(width: compactSize.width, height: compactSize.height)
        case .ready:
            SpikeView()
                .frame(minWidth: 960, minHeight: 640)
        }
    }

    /// About the size of the library picker Photos shows when you hold ⌥.
    private let compactSize = CGSize(width: 520, height: 400)
}

struct OpenFailedView: View {
    @EnvironmentObject private var model: SpikeModel
    let url: URL
    let message: String
    let needsFullDiskAccess: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: needsFullDiskAccess ? "lock.shield" : "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("Can't open “\(url.deletingPathExtension().lastPathComponent)”").font(.headline)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if needsFullDiskAccess {
                Text("Add Winnow Spike with the + button, switch it on, then click Try Again. macOS may ask you to reopen the app.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
            }
            HStack {
                Button("Choose Another Library") { model.chooseAnotherLibrary() }
                if needsFullDiskAccess {
                    Button("Open Privacy Settings") { model.openFullDiskAccessSettings() }
                }
                Button("Try Again") { Task { await model.open(url) } }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
    }
}
