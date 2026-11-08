// Settings › Reset: start over, a little or completely. Photos itself is never touched here:
// ratings, favorites, albums and edits stay, as do photos in the Rejected album.

import SwiftUI
import DateGuesser
import KeeperKit

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView {
            KeeperSettingsView()
                .tabItem { Label("Keeper Rules", systemImage: "checkmark.seal") }
            DatesSettingsTab(session: model.session, scanning: false)
                .tabItem { Label("Dates", systemImage: "calendar") }
            DatesSettingsTab(session: model.session, scanning: true)
                .tabItem { Label("Date Scanning", systemImage: "magnifyingglass") }
            ResetSettingsView()
                .tabItem { Label("Reset", systemImage: "arrow.counterclockwise") }
        }
        .frame(width: 600)
        .background(SettingsWindowMarker())
    }
}

/// Settings for the Dates screens, loading their data first if no Dates row has been opened yet.
struct DatesSettingsTab: View {
    var session: CullingSession?
    var scanning: Bool

    var body: some View {
        if let session {
            Loaded(session: session, scanning: scanning)
        } else {
            ContentUnavailableView("No Library Open", systemImage: "calendar",
                                   description: Text("Open a library to change how Dates finds and estimates dates."))
                .frame(height: 300)
        }
    }

    private struct Loaded: View {
        @ObservedObject var session: CullingSession
        var scanning: Bool

        var body: some View {
            if let dates = session.datesModel {
                DatesSettings(model: dates, scanning: scanning)
            } else {
                ProgressView("Loading Dates…")
                    .frame(maxWidth: .infinity, minHeight: 300)
                    .onAppear { session.loadDates() }
            }
        }
    }
}

struct ResetSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirming: Action?
    @State private var working = false

    enum Action: String, Identifiable {
        case rescan, library, everything
        var id: String { rawValue }
    }

    var body: some View {
        Form {
            Section {
                row(.rescan, "Scan Again",
                    "Forgets the look-alike fingerprints and orientation checks, and runs both scans again from the start. Your rejects, picks and ticks stay.")
                row(.library, "Reset This Library…",
                    "Forgets everything \(appName) stored for \(libraryName): rejects, which photos you've seen, keeper picks, ticks and scans.")
                row(.everything, "Reset \(appName)…",
                    "Every library's data, \(appName)'s settings (keeper rules included) and caches, as if just installed. You choose a library again.")
            } footer: {
                Text("Photos itself isn't changed: ratings, favorites, albums and edits stay, and photos you rejected stay in the “\(PhotoLibrary.rejectAlbumTitle)” album until you take them out.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 340)
        .disabled(working)
        .confirmationDialog(title, isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            presenting: confirming) { action in
            Button(button(action), role: action == .rescan ? nil : .destructive) { run(action) }
        } message: { action in
            Text(message(action))
        }
    }

    private var appName: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Keeper" }
    private var libraryName: String { model.session.map { "“\($0.libraryName)”" } ?? "the open library" }

    private func row(_ action: Action, _ label: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label.replacingOccurrences(of: "…", with: ""))
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(label) { confirming = action }
                .disabled(action != .everything && model.session == nil)
        }
        .padding(.vertical, 2)
    }

    private var title: String {
        switch confirming {
        case .rescan: "Scan the whole library again?"
        case .library: "Reset \(libraryName)?"
        case .everything: "Reset \(appName) completely?"
        case nil: ""
        }
    }

    private func button(_ action: Action) -> String {
        switch action {
        case .rescan: "Scan Again"
        case .library: "Reset Library"
        case .everything: "Reset \(appName)"
        }
    }

    private func message(_ action: Action) -> String {
        switch action {
        case .rescan:
            "The first scans of a big library take hours. They run in the background as before."
        case .library:
            "Rejects, seen photos, keeper picks, ticks and scans for this library are deleted and can't be brought back. Photos isn't changed."
        case .everything:
            "All of \(appName)'s data and settings are deleted and can't be brought back. Photos isn't changed."
        }
    }

    private func run(_ action: Action) {
        working = true
        Task {
            switch action {
            case .rescan: await model.rescan()
            case .library: await model.resetLibrary()
            case .everything: model.resetEverything()
            }
            working = false
        }
    }
}
