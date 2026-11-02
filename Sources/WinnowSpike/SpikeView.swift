import SwiftUI
import WinnowCore

struct SpikeView: View {
    @EnvironmentObject private var model: SpikeModel
    @State private var showingColumns = false
    @State private var confirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if model.photosAccessDenied {
                photosAccessBanner
            } else if model.isSystemLibrary == false {
                notSystemLibraryBanner
            }
            if model.isSystemLibrary == true {
                controls
                Text(model.status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let comparison = model.comparison {
                    Text(comparison).font(.callout.weight(.medium)).textSelection(.enabled)
                }
                grid
            } else {
                Spacer()
            }
        }
        .padding(16)
        .sheet(isPresented: $showingColumns) { ScoreColumnsSheet() }
        .confirmationDialog("Delete \(model.rejectedCount) photos from “\(model.library?.database.libraryName ?? "")”?",
                            isPresented: $confirmingDelete) {
            Button("Delete \(model.rejectedCount) Photos", role: .destructive) { Task { await model.deleteRejected() } }
        } message: {
            Text("They go to Recently Deleted for 30 days. macOS will ask you to confirm once more.")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.library?.database.libraryName ?? "").font(.title2.bold())
                HStack(spacing: 6) {
                    Text("\(model.library?.photoCount ?? 0) photos")
                    Text("·")
                    Text("\(model.library?.columns.count ?? 0) Photos score columns")
                    if model.isSystemLibrary == true {
                        Text("·")
                        Label("System Photo Library", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Score Columns…") { showingColumns = true }
            Button("Choose Library…") { model.chooseAnotherLibrary() }
                .disabled(model.running)
        }
    }

    private var notSystemLibraryBanner: some View {
        Banner(systemImage: "info.circle", tint: .blue) {
            Text("This isn't your System Photo Library").font(.headline)
            Text("""
                Winnow has read this library's own scores (see Score Columns). But macOS only lets apps load photos \
                from, and make changes to, the System Photo Library. To test with this library, open it in Photos, \
                choose Photos › Settings › General › Use as System Photo Library, then click Check Again.
                """)
            Text("If your main library uses iCloud Photos, switching turns iCloud Photos off for it until you switch back.")
                .foregroundStyle(.secondary)
        } actions: {
            Button("Open in Photos") { model.openInPhotos() }
            Button("Check Again") { Task { await model.checkSystemLibrary() } }
        }
    }

    private var photosAccessBanner: some View {
        Banner(systemImage: "lock", tint: .orange) {
            Text("Winnow Spike doesn't have access to Photos").font(.headline)
            Text("Turn it on in System Settings › Privacy & Security › Photos, then click Check Again.")
        } actions: {
            Button("Open Privacy Settings") { model.openPhotosPrivacySettings() }
            Button("Check Again") { Task { await model.checkSystemLibrary() } }
        }
    }

    private var controls: some View {
        HStack(spacing: 16) {
            Button(model.running ? "Running…" : "Run") { Task { await model.run() } }
                .keyboardShortcut("r")
                .disabled(model.running)
            Stepper("Most recent \(model.sampleSize) photos", value: $model.sampleSize, in: 50...2000, step: 50)
                .disabled(model.running)
            Spacer()
            Toggle("Allow deleting (test library only)", isOn: $model.deleteEnabled)
                .toggleStyle(.checkbox)
            Button("Delete \(model.rejectedCount) Marked…") { confirmingDelete = true }
                .disabled(!model.deleteEnabled || model.rejectedCount == 0 || model.running)
                .help("Click photos to mark them, then delete them in one batch.")
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                ForEach($model.photos) { $photo in
                    PhotoCard(photo: photo)
                        .onTapGesture { photo.rejected.toggle() }
                }
            }
        }
    }
}

struct Banner<Content: View, Actions: View>: View {
    let systemImage: String
    let tint: Color
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage).font(.title2).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 6) {
                content
                HStack { actions }.padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct PhotoCard: View {
    let photo: ScoredPhoto

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if let thumbnail = photo.thumbnail {
                    Image(nsImage: thumbnail).resizable().scaledToFill()
                } else {
                    Rectangle().fill(.quaternary).overlay(Image(systemName: "icloud"))
                }
            }
            .frame(height: 130)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(photo.rejected ? Color.red : .clear, lineWidth: 3))

            HStack {
                Text(photo.vision.map { String(format: "Vision %+.2f", $0) } ?? "Vision –")
                    .font(.headline.monospacedDigit())
                if photo.isUtility == true {
                    Text("utility").font(.caption).padding(.horizontal, 4)
                        .background(.orange.opacity(0.2), in: Capsule())
                }
                Spacer()
                if photo.rejected { Image(systemName: "xmark.circle.fill").foregroundStyle(.red) }
            }
            Text(photo.photosScore.map { String(format: "Photos %.2f", $0) } ?? "Photos –")
                .font(.subheadline.monospacedDigit())
            Text(String(format: "load %.0f ms · score %.0f ms", photo.loadMs, photo.scoreMs))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

struct ScoreColumnsSheet: View {
    @EnvironmentObject private var model: SpikeModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Photos score columns").font(.title3.bold())
            Text("Scores Apple Photos has computed for this library, as stored in its database on this macOS version.")
                .foregroundStyle(.secondary)
            Table(model.library?.columns ?? []) {
                TableColumn("Table", value: \.table)
                TableColumn("Column", value: \.column)
                TableColumn("Photos with a value") { Text("\($0.nonNull)").monospacedDigit() }
                TableColumn("Min") { Text(fmt($0.min)).monospacedDigit() }
                TableColumn("Max") { Text(fmt($0.max)).monospacedDigit() }
                TableColumn("Mean") { Text(fmt($0.mean)).monospacedDigit() }
                TableColumn("Per photo") { Text($0.joinable ? "Yes" : "No (several rows)") }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 820, minHeight: 480)
    }

    private func fmt(_ v: Double?) -> String { v.map { String(format: "%.3f", $0) } ?? "–" }
}
