// Winnow Spike — Phase 0 prototype.
//
// Answers three questions before Alpha:
//   1. How fast can PhotoKit hand us images, and how fast does Vision score them?
//   2. How do Vision's aesthetic scores rank the library? (exported for `winnow-scores compare`)
//   3. What does a batched PhotoKit delete feel like? (needs --allow-delete; test library only)

import AppKit
import Photos
import SwiftUI
import Vision

@main
struct WinnowSpikeApp: App {
    @StateObject private var model = SpikeModel()

    var body: some Scene {
        WindowGroup("Winnow Spike") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 960, minHeight: 640)
        }
    }
}

struct ScoredPhoto: Identifiable {
    let id: String // PHAsset.localIdentifier
    let thumbnail: NSImage?
    let overall: Float?
    let isUtility: Bool?
    let loadMs: Double
    let scoreMs: Double
    var rejected = false

    /// The part of the local identifier that matches ZASSET.ZUUID in Photos.sqlite.
    var uuid: String { String(id.split(separator: "/").first ?? "") }
}

@MainActor
final class SpikeModel: ObservableObject {
    @Published var status = "Press Run to score your most recent photos."
    @Published var photos: [ScoredPhoto] = []
    @Published var running = false
    @Published var sampleSize = 200

    /// Deleting is off unless the app is launched with --allow-delete, so a spike run
    /// against a real library can never remove anything.
    let allowDelete = CommandLine.arguments.contains("--allow-delete")

    var rejectedCount: Int { photos.filter(\.rejected).count }

    func run() async {
        running = true
        defer { running = false }

        let access = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard access == .authorized || access == .limited else {
            status = "Photos access denied. Turn it on in System Settings › Privacy & Security › Photos."
            return
        }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = sampleSize
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in assets.append(asset) }

        photos = []
        let request = CalculateImageAestheticsScoresRequest()
        let started = CFAbsoluteTimeGetCurrent()

        for (index, asset) in assets.enumerated() {
            status = "Scoring \(index + 1) of \(assets.count)…"
            let t0 = CFAbsoluteTimeGetCurrent()
            let image = await Self.image(for: asset, side: 1024)
            let t1 = CFAbsoluteTimeGetCurrent()

            var overall: Float?
            var isUtility: Bool?
            if let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil),
               let observation = try? await request.perform(on: cgImage) {
                overall = observation.overallScore
                isUtility = observation.isUtility
            }
            let t2 = CFAbsoluteTimeGetCurrent()

            // Keep only a small thumbnail in memory; the 1024 px image is released here.
            let thumbnail = await Self.image(for: asset, side: 256)
            photos.append(ScoredPhoto(id: asset.localIdentifier, thumbnail: thumbnail,
                                      overall: overall, isUtility: isUtility,
                                      loadMs: (t1 - t0) * 1000, scoreMs: (t2 - t1) * 1000))
        }

        // Lowest scores first: the likely rejects.
        photos.sort { ($0.overall ?? .infinity) < ($1.overall ?? .infinity) }

        let elapsed = CFAbsoluteTimeGetCurrent() - started
        let scored = photos.filter { $0.overall != nil }.count
        let missing = photos.count - scored
        status = String(format: "%d scored in %.1f s (%.1f per second) · median load %.0f ms · median score %.0f ms",
                        scored, elapsed, Double(photos.count) / max(elapsed, 0.001),
                        Self.median(photos.map(\.loadMs)), Self.median(photos.map(\.scoreMs)))
        if missing > 0 { status += " · \(missing) not on this Mac (iCloud only), skipped" }

        do {
            let url = try exportCSV()
            status += " · saved \(url.path)"
        } catch {
            status += " · CSV export failed: \(error.localizedDescription)"
        }
    }

    func deleteRejected() async {
        let ids = photos.filter(\.rejected).map(\.id)
        guard allowDelete, !ids.isEmpty else { return }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        do {
            // One change block = one macOS confirmation dialog for the whole batch.
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets)
            }
            photos.removeAll(where: \.rejected)
            status = "Deleted \(ids.count) photos. They are in Recently Deleted for 30 days."
        } catch {
            status = "Delete cancelled or failed: \(error.localizedDescription)"
        }
    }

    /// Writes ~/Documents/Winnow/out/vision-scores.csv for `winnow-scores compare`.
    private func exportCSV() throws -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Winnow/out")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("vision-scores.csv")
        var csv = "uuid,overall,isUtility,loadMs,scoreMs\n"
        for p in photos {
            csv += [p.uuid, p.overall.map { String($0) } ?? "", p.isUtility.map { String($0) } ?? "",
                    String(format: "%.1f", p.loadMs), String(format: "%.1f", p.scoreMs)].joined(separator: ",") + "\n"
        }
        try csv.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func image(for asset: PHAsset, side: CGFloat) async -> NSImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat // one callback, never a degraded first pass
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = false    // Phase 0 measures local originals only
            PHImageManager.default().requestImage(for: asset,
                                                  targetSize: CGSize(width: side, height: side),
                                                  contentMode: .aspectFit,
                                                  options: options) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: SpikeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                Button(model.running ? "Running…" : "Run") { Task { await model.run() } }
                    .keyboardShortcut("r")
                    .disabled(model.running)
                Stepper("Most recent \(model.sampleSize) photos", value: $model.sampleSize, in: 50...2000, step: 50)
                    .disabled(model.running)
                Spacer()
                Button("Delete \(model.rejectedCount) rejected") { Task { await model.deleteRejected() } }
                    .disabled(!model.allowDelete || model.rejectedCount == 0 || model.running)
                    .help(model.allowDelete ? "Deletes in one batch; macOS asks to confirm."
                                            : "Launch with --allow-delete, and only in the test library.")
            }
            Text(model.status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                    ForEach($model.photos) { $photo in
                        PhotoCard(photo: photo)
                            .onTapGesture { photo.rejected.toggle() }
                    }
                }
            }
        }
        .padding(16)
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
                Text(photo.overall.map { String(format: "%+.2f", $0) } ?? "–")
                    .font(.headline.monospacedDigit())
                if photo.isUtility == true {
                    Text("utility").font(.caption).padding(.horizontal, 4)
                        .background(.orange.opacity(0.2), in: Capsule())
                }
                Spacer()
                if photo.rejected { Image(systemName: "xmark.circle.fill").foregroundStyle(.red) }
            }
            Text(String(format: "load %.0f ms · score %.0f ms", photo.loadMs, photo.scoreMs))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}
