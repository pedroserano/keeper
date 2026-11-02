import Photos
import SwiftUI
import Vision
import WinnowKit

private var backingScale: CGFloat { NSScreen.main?.backingScaleFactor ?? 2 }

/// A PhotoKit image that loads a quick preview first, then the sharp version.
struct AssetImage: View {
    @EnvironmentObject private var library: PhotoLibrary
    let asset: PHAsset
    let pointSize: CGSize
    var fill = false

    @State private var image: NSImage?
    @State private var missingInCloud = false

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: fill ? .fill : .fit)
            } else if missingInCloud {
                Image(systemName: "icloud").font(.title).foregroundStyle(.secondary)
            }
        }
        .task(id: "\(asset.localIdentifier)|\(Int(pointSize.width))x\(Int(pointSize.height))") {
            let target = CGSize(width: pointSize.width * backingScale, height: pointSize.height * backingScale)
            var gotImage = false
            var inCloud = false
            // Keep the previous photo on screen until this one's first image arrives: no flash between photos.
            for await loaded in library.images(for: asset, targetSize: target,
                                               contentMode: fill ? .aspectFill : .aspectFit) {
                if let new = loaded.image {
                    image = new
                    gotImage = true
                }
                inCloud = inCloud || loaded.isInCloud
            }
            if !gotImage && !Task.isCancelled {
                image = nil
                missingInCloud = inCloud
            }
        }
    }
}

// MARK: - Grid

struct GridView: View {
    @EnvironmentObject private var session: CullingSession
    private let cell: CGFloat = 168
    private let spacing: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let columns = max(1, Int((geo.size.width - spacing * 2 + spacing) / (cell + spacing)))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(cell), spacing: spacing), count: columns),
                              spacing: spacing) {
                        // Indexes, not photos: only the cells on screen ever load their photo.
                        ForEach(session.list.indices, id: \.self) { i in
                            let asset = session.list.asset(at: i)
                            GridCell(asset: asset, decision: session.decision(asset),
                                     selected: i == session.cursor, size: cell)
                                .onTapGesture(count: 2) {
                                    session.select(index: i)
                                    session.mode = .single
                                }
                                .onTapGesture { session.select(index: i) }
                        }
                    }
                    .padding(spacing)
                }
                .onAppear {
                    session.gridColumns = columns
                    proxy.scrollTo(session.cursor, anchor: .center)
                }
                .onChange(of: columns) { session.gridColumns = columns }
                .onChange(of: session.cursor) { proxy.scrollTo(session.cursor) }
            }
        }
    }
}

struct GridCell: View {
    let asset: PHAsset
    let decision: Decision
    let selected: Bool
    let size: CGFloat

    var body: some View {
        AssetImage(asset: asset, pointSize: CGSize(width: size, height: size), fill: true)
            .frame(width: size, height: size)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .opacity(decision.flag == .reject ? 0.35 : 1)
            .overlay(alignment: .topLeading) { DecisionBadge(decision: decision).padding(6) }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 3)
            }
            .contentShape(Rectangle())
    }
}

// MARK: - Single photo

struct SingleView: View {
    @EnvironmentObject private var session: CullingSession
    @EnvironmentObject private var library: PhotoLibrary

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let asset = session.current {
                    if session.zoomed {
                        ZoomedImage(asset: asset, onFace: session.zoomOnFace, allowNetwork: session.allowDownloads)
                            .id("\(asset.localIdentifier)|\(session.zoomOnFace)")
                    } else {
                        AssetImage(asset: asset, pointSize: geo.size)
                            .padding(12)
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if let asset = session.current {
                    InfoBar(asset: asset, decision: session.decision(asset),
                            position: "\(session.cursor + 1) of \(session.list.count)")
                }
            }
            .task(id: session.cursor) { prefetch(size: geo.size) }
        }
    }

    /// Warm up the next three and previous one so stepping through feels instant.
    private func prefetch(size: CGSize) {
        let list = session.list
        guard !list.isEmpty else { return }
        let range = max(session.cursor - 1, 0)...min(session.cursor + 3, list.count - 1)
        let target = CGSize(width: size.width * backingScale, height: size.height * backingScale)
        library.startCaching(range.map { list.asset(at: $0) }, targetSize: target)
    }
}

struct InfoBar: View {
    let asset: PHAsset
    let decision: Decision
    let position: String

    var body: some View {
        HStack(spacing: 14) {
            DecisionBadge(decision: decision, large: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(PHAssetResource.assetResources(for: asset).first?.originalFilename ?? "")
                    .font(.callout.weight(.medium))
                Text(asset.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if asset.isFavorite { Image(systemName: "heart.fill").foregroundStyle(.pink) }
            Text("\(asset.pixelWidth) × \(asset.pixelHeight)").font(.caption).foregroundStyle(.secondary)
            Text(position).font(.callout.monospacedDigit())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .environment(\.colorScheme, .dark)
        .padding(12)
    }
}

/// The original at 100% (one image pixel per screen pixel), centred on the main face for Z.
struct ZoomedImage: View {
    @EnvironmentObject private var library: PhotoLibrary
    let asset: PHAsset
    let onFace: Bool
    let allowNetwork: Bool

    private enum Phase { case loading, ready(NSImage, UnitPoint), inCloud, failed }
    @State private var phase: Phase = .loading

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView().controlSize(.large).environment(\.colorScheme, .dark)
            case .ready(let image, let anchor):
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: CGFloat(asset.pixelWidth) / backingScale,
                               height: CGFloat(asset.pixelHeight) / backingScale)
                }
                .defaultScrollAnchor(anchor)
            case .inCloud:
                notice("icloud.and.arrow.down",
                       "The original is in iCloud. Turn on View › Download Originals from iCloud for Zoom to see it at 100%.")
            case .failed:
                notice("exclamationmark.triangle", "Couldn't load the original.")
            }
        }
        .task {
            var result: LoadedImage?
            for await loaded in library.images(for: asset, targetSize: PHImageManagerMaximumSize,
                                               highQualityOnly: true, allowNetwork: allowNetwork) {
                result = loaded
            }
            guard let image = result?.image else {
                phase = result?.isInCloud == true ? .inCloud : .failed
                return
            }
            var anchor = UnitPoint.center
            if onFace, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
               let face = await Self.faceCenter(cg) {
                anchor = face
            }
            phase = .ready(image, anchor)
        }
    }

    private func notice(_ symbol: String, _ text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.largeTitle)
            Text(text).multilineTextAlignment(.center).frame(maxWidth: 360)
        }
        .foregroundStyle(.white.opacity(0.8))
    }

    /// Centre of the largest face, as a unit point with the origin at the top left.
    private static func faceCenter(_ image: CGImage) async -> UnitPoint? {
        await Task.detached {
            let request = VNDetectFaceRectanglesRequest()
            try? VNImageRequestHandler(cgImage: image).perform([request])
            guard let face = request.results?.max(by: {
                $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
            }) else { return nil }
            return UnitPoint(x: face.boundingBox.midX, y: 1 - face.boundingBox.midY)
        }.value
    }
}

// MARK: - Compare

struct CompareView: View {
    @EnvironmentObject private var session: CullingSession

    var body: some View {
        GeometryReader { geo in
            let group = session.compareGroup
            let columns = group.count == 4 ? 2 : max(group.count, 1)
            let rows = group.count == 4 ? 2 : 1
            let paneSize = CGSize(width: (geo.size.width - CGFloat(columns + 1) * 8) / CGFloat(columns),
                                  height: (geo.size.height - CGFloat(rows + 1) * 8) / CGFloat(rows))
            ZStack {
                Color.black
                Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                    ForEach(0..<rows, id: \.self) { r in
                        GridRow {
                            ForEach(0..<columns, id: \.self) { c in
                                let i = r * columns + c
                                if group.indices.contains(i) {
                                    pane(group[i], index: i, size: paneSize)
                                }
                            }
                        }
                    }
                }
                .padding(8)
            }
        }
    }

    private func pane(_ asset: PHAsset, index: Int, size: CGSize) -> some View {
        let focused = index == session.compareFocus
        return ZStack {
            if session.zoomed {
                ZoomedImage(asset: asset, onFace: session.zoomOnFace, allowNetwork: session.allowDownloads)
                    .id("\(asset.localIdentifier)|\(session.zoomOnFace)")
            } else {
                AssetImage(asset: asset, pointSize: size)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .opacity(session.decision(asset).flag == .reject ? 0.45 : 1)
        .overlay(alignment: .topLeading) { DecisionBadge(decision: session.decision(asset), large: true).padding(8) }
        .overlay {
            RoundedRectangle(cornerRadius: 4).strokeBorder(focused ? Color.accentColor : .white.opacity(0.15),
                                                           lineWidth: focused ? 3 : 1)
        }
        .contentShape(Rectangle())
        .onTapGesture { session.focusCompare(index) }
    }
}
