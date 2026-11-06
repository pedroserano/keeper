// Winnow › Settings › Keeper Rules: how Duplicates and Similar Shots pick the photo to keep.
//
// Saved app-wide (the same rules for every library). Open lists re-pick their keepers as soon as
// a rule changes; photos you picked yourself with Keep or K stay picked.

import AppKit
import SwiftUI
import WinnowKit

@MainActor
final class KeeperSettings: ObservableObject {
    static let shared = KeeperSettings()
    private static let key = "keeperRules"

    @Published var rules: KeeperRules {
        didSet {
            if let data = try? JSONEncoder().encode(rules) { UserDefaults.standard.set(data, forKey: Self.key) }
        }
    }

    private init() {
        rules = UserDefaults.standard.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(KeeperRules.self, from: $0) } ?? .standard
    }
}

struct KeeperSettingsView: View {
    @ObservedObject private var settings = KeeperSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rules:")
            List {
                ForEach(Array(settings.rules.rules.enumerated()), id: \.element.id) { n, setting in
                    row(n, setting)
                }
                .onMove { from, to in settings.rules.rules.move(fromOffsets: from, toOffset: to) }
            }
            .listStyle(.bordered)
            .alternatingRowBackgrounds(.disabled)
            .frame(minHeight: 420)
            Text("""
                * check rules you need, set values for them, drag and drop to change the order. \
                The first rule where a group's photos differ picks the one to keep; sizes within \
                \(KeeperRules.sizeTie.formatted(.percent)) count as the same. Your own picks (Keep, K) always win.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Restore Defaults") { settings.rules = .standard }
                    .disabled(settings.rules == .standard)
            }
        }
        .padding(20)
        .frame(width: 560)
        .background(SettingsWindowMarker())
    }

    private func row(_ n: Int, _ setting: KeeperRuleSetting) -> some View {
        let index = n
        return HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .help("Drag to change the order")
            Text("\(n + 1).")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .trailing)
            Toggle("", isOn: Binding(get: { settings.rules.rules[index].enabled },
                                     set: { settings.rules.rules[index].enabled = $0 }))
                .toggleStyle(.checkbox)
                .labelsHidden()
            Image(systemName: setting.rule.systemImage)
                .frame(width: 20)
                .foregroundStyle(.secondary)
            Text(setting.rule.title)
            Spacer()
            Picker("", selection: Binding(get: { settings.rules.rules[index].keepHigher },
                                          set: { settings.rules.rules[index].keepHigher = $0 })) {
                Text(setting.rule.markLabel(keepHigher: true)).tag(true)
                Text(setting.rule.markLabel(keepHigher: false)).tag(false)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
        .padding(.vertical, 3)
        .opacity(setting.enabled ? 1 : 0.6)
    }
}

/// Tags the Settings window, so the culling keys (arrows, numbers, letters) leave it alone.
struct SettingsWindowMarker: NSViewRepresentable {
    static let identifier = NSUserInterfaceItemIdentifier("winnow.settings")

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { view.window?.identifier = Self.identifier }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if view.window?.identifier != Self.identifier { view.window?.identifier = Self.identifier }
    }
}
