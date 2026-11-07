import SwiftUI
import DateGuessCore

/// The cameras that took undated photos, and the years the user remembers using each one.
struct CamerasView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let cameras = state.undatedCameras.map { CameraItem(name: $0.name, count: $0.count) }
        if cameras.isEmpty {
            ContentUnavailableView {
                Label("No Camera Details", systemImage: "camera")
            } description: {
                Text(state.settings.scan.deepCheck
                     ? "None of your undated photos say which camera took them. Scanned prints never do."
                     : "Turn on “Photos whose file has no capture date” in Settings ▸ Scanning and scan again to read camera details.")
            }
        } else {
            Table(cameras) {
                TableColumn("Camera") { c in
                    Label(c.name, systemImage: "camera")
                }
                .width(min: 180, ideal: 280)
                TableColumn("Undated Photos") { c in
                    Text(c.count.formatted()).monospacedDigit().foregroundStyle(.secondary)
                }
                .width(110)
                TableColumn("Used") { c in
                    CameraYears(state: state, name: c.name)
                }
                .width(min: 180, ideal: 200)
            }
            .navigationSubtitle("Enter the years you used a camera, and its photos are dated within them")
        }
    }
}

struct CameraItem: Identifiable {
    var id: String { name }
    var name: String
    var count: Int
}

/// The years a camera was in use, edited in place.
struct CameraYears: View {
    /// Passed in rather than read from the environment: Table rows can be laid out before the
    /// environment reaches them, and reading a missing Observable from it crashes.
    var state: AppState
    var name: String

    private var period: CameraPeriod? { state.cameraPeriods.first { $0.id == name } }

    var body: some View {
        HStack(spacing: 6) {
            NumberField(title: "From", value: Binding(
                get: { period?.fromYear },
                set: { state.setCameraYears(name, from: $0, to: period?.toYear) }),
                range: YearBounds.earliestPhotoYear...YearBounds.currentYear(), width: 60)
            Text("to").foregroundStyle(.secondary)
            NumberField(title: "To", value: Binding(
                get: { period?.toYear },
                set: { state.setCameraYears(name, from: period?.fromYear, to: $0) }),
                range: YearBounds.earliestPhotoYear...YearBounds.currentYear(), width: 60)
        }
        .controlSize(.small)
    }
}
