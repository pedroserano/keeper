import Photos
import SwiftUI
import Vision
import WinnowCore
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
                              spacing: spacing, pinnedViews: [.sectionHeaders]) {
                        if let sections = session.sections {
                            // Duplicates and Similar Shots: one section per group, the one to keep first.
                            ForEach(Array(sections.enumerated()), id: \.offset) { n, range in
                                Section {
                                    ForEach(range, id: \.self) { i in cellView(i, details: true) }
                                } header: {
                                    if session.sectionGroups.indices.contains(n) {
                                        GroupHeader(group: session.sectionGroups[n], range: range,
                                                    number: n + 1, of: sections.count)
                                    }
                                }
                            }
                        } else {
                            // Indexes, not photos: only the cells on screen ever load their photo.
                            ForEach(session.list.indices, id: \.self) { i in cellView(i, details: false) }
                        }
                    }
                    .padding(spacing)
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    if session.sections != nil, !session.sectionGroups.isEmpty { MergeBar() }
                }
                .onAppear {
                    session.gridColumns = columns
                    proxy.scrollTo(session.cursor, anchor: .center)
                }
                .onChange(of: columns) { session.gridColumns = columns }
                // Groups: centre the photo, so its group's header is in view and not under the pinned ones.
                .onChange(of: session.cursor) { proxy.scrollTo(session.cursor, anchor: session.sections == nil ? nil : .center) }
            }
        }
    }
}

extension GridView {
    func cellView(_ i: Int, details: Bool) -> some View {
        let asset = session.list.asset(at: i)
        return GridCell(asset: asset, decision: session.decision(asset), suggestion: session.suggestion(asset),
                        isFavorite: session.isFavorite(asset), selected: i == session.cursor, size: cell,
                        file: details ? session.fileInfo(asset) : nil, showDetails: details,
                        isKeeper: details && session.isKeeper(asset),
                        keep: details ? { session.keepInGroup(asset) } : nil)
            .id(i)
            .photoContextMenu(asset, session: session)
            .onTapGesture(count: 2) {
                session.select(index: i)
                session.mode = .single
            }
            .onTapGesture { session.select(index: i) }
    }
}

/// "☐ Group 12 of 412 · 3 near-identical copies · Nov 3, 2019, 2:14:07 – 2:14:31 PM   Keeps the largest [Merge]"
struct GroupHeader: View {
    @EnvironmentObject private var session: CullingSession
    let group: LookAlikeGroup
    let range: Range<Int>
    let number: Int
    let of: Int

    var body: some View {
        let dates = range.compactMap { session.list.asset(at: $0).creationDate }
        HStack(spacing: 8) {
            Toggle(isOn: Binding(get: { session.selectedGroups.contains(group.id) },
                                 set: { _ in session.toggleSelection(group) })) { EmptyView() }
                .toggleStyle(.checkbox)
                .help("Select this group to merge it with others")
            Text("Group \(number.formatted()) of \(of.formatted())").fontWeight(.semibold)
            Text("·")
            Text(kind)
            if let first = dates.min(), let last = dates.max() {
                Text("·")
                Text(span(first, last))
            }
            Spacer()
            Text(keepNote)
                .foregroundStyle(.secondary)
                .help("Click Keep under another photo, or select it and press K, to keep that one instead")
            Button("Merge") { Task { await session.merge([group]) } }
                .disabled(session.merging)
                .help("Keep the photo marked Keep, giving it the group's best rating, Favorite and albums; "
                      + "move the others to Rejected. ⌘Z undoes.")
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private var kind: String {
        "\(group.members.count) " + (group.kind == .duplicate ? "near-identical copies" : "similar shots")
    }

    private var keepNote: String {
        if session.isChosenByYou(group) { return "Keeping your pick" }
        return group.kind == .duplicate ? "Suggests the largest copy" : "Suggests the best, favoring bigger files"
    }

    private func span(_ a: Date, _ b: Date) -> String {
        let day = a.formatted(date: .abbreviated, time: .omitted)
        let time = Date.FormatStyle().hour().minute().second()
        return a == b ? "\(day), \(a.formatted(time))" : "\(day), \(a.formatted(time)) – \(b.formatted(time))"
    }
}

/// Above the look-alike groups: select them all, merge the selected ones.
struct MergeBar: View {
    @EnvironmentObject private var session: CullingSession
    @State private var confirming = false

    private var selected: [LookAlikeGroup] {
        session.sectionGroups.filter { session.selectedGroups.contains($0.id) }
    }

    var body: some View {
        let total = session.sectionGroups.count
        let allSelected = !session.sectionGroups.isEmpty && selected.count == total
        HStack(spacing: 12) {
            Button(allSelected ? "Deselect All" : "Select All") {
                allSelected ? session.deselectAllGroups() : session.selectAllGroups()
            }
            Text("\(selected.count.formatted()) of \(total.formatted()) groups selected")
                .foregroundStyle(.secondary)
            Spacer()
            if session.merging { ProgressView().controlSize(.small) }
            Button("Merge Selected…") { confirming = true }
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty || session.merging)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .confirmationDialog(title, isPresented: $confirming) {
            Button("Merge \(selected.count.formatted()) Groups") {
                let groups = selected
                Task { await session.merge(groups) }
            }
        } message: {
            Text("""
                Each group's kept photo gets the group's best rating, its Favorite and all its albums. \
                The other \(selected.map(\.others.count).reduce(0, +).formatted()) photos move to Rejected; \
                nothing is deleted until you use Delete Rejected. ⌘Z undoes the whole merge.
                """)
        }
    }

    private var title: String {
        "Merge \(selected.count.formatted()) \(selected.count == 1 ? "group" : "groups")?"
    }
}

struct GridCell: View {
    let asset: PHAsset
    let decision: Decision
    let suggestion: Suggestion?
    let isFavorite: Bool
    let selected: Bool
    let size: CGFloat
    var file: FileInfo? = nil
    /// Under the photo: time to the second, dimensions, file size, and whether Winnow would keep it.
    var showDetails = false
    var isKeeper = false
    /// In a group: makes this the photo to keep.
    var keep: (() -> Void)? = nil

    var body: some View {
        if showDetails {
            VStack(alignment: .leading, spacing: 3) {
                thumbnail
                HStack(spacing: 4) {
                    Text(asset.creationDate?.formatted(Date.FormatStyle().hour().minute().second()) ?? "")
                    Spacer(minLength: 0)
                    if isKeeper {
                        Text("Keep")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .background(.green.opacity(0.85), in: Capsule())
                            .foregroundStyle(.white)
                    } else if let keep {
                        Button("Keep", action: keep)
                            .buttonStyle(.plain)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .overlay(Capsule().stroke(.secondary.opacity(0.6)))
                            .foregroundStyle(.secondary)
                            .help("Keep this one instead when the group is merged (K)")
                    }
                }
                .font(.caption.monospacedDigit())
                Text(dimensionsAndSize)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(width: size)
        } else {
            thumbnail
        }
    }

    private var dimensionsAndSize: String {
        let w = file?.width ?? asset.pixelWidth, h = file?.height ?? asset.pixelHeight
        var parts = ["\(w) × \(h)"]
        if let bytes = file?.bytes { parts.append(bytes.formatted(.byteCount(style: .file))) }
        return parts.joined(separator: " · ")
    }

    private var thumbnail: some View {
        AssetImage(asset: asset, pointSize: CGSize(width: size, height: size), fill: true)
            .frame(width: size, height: size)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .opacity(decision.flag == .reject ? 0.35 : 1)
            .overlay { PhotoBadges(decision: decision, suggestion: suggestion, isFavorite: isFavorite) }
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
            .contentShape(Rectangle())
            .modifier(CurrentPhotoMenu(session: session))
            .overlay(alignment: .topTrailing) {
                if session.showingScores, let asset = session.current {
                    ScoresPanel(scores: session.recommender?.scores[String(asset.localIdentifier.split(separator: "/").first ?? "")])
                }
            }
            .overlay(alignment: .bottom) {
                if let asset = session.current {
                    InfoBar(asset: asset, decision: session.decision(asset), suggestion: session.suggestion(asset),
                            isFavorite: session.isFavorite(asset),
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
    let suggestion: Suggestion?
    let isFavorite: Bool
    let position: String

    var body: some View {
        HStack(spacing: 14) {
            FlagIcon(flag: decision.flag)
            RatingLabel(rating: decision.rating, suggested: suggestion?.stars ?? 0)
            VStack(alignment: .leading, spacing: 2) {
                Text(PHAssetResource.assetResources(for: asset).first?.filename ?? "")
                    .font(.callout.weight(.medium))
                Text(asset.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let suggestion, suggestion.stars > 0 || !suggestion.reasons.isEmpty || suggestion.group != nil {
                    Text(suggestionLine(suggestion))
                        .font(.caption)
                        .foregroundStyle(suggestion.suggestsReject ? .orange : .secondary)
                }
            }
            Spacer()
            if isFavorite { Image(systemName: "heart.fill").foregroundStyle(.pink) }
            Text("\(asset.pixelWidth) × \(asset.pixelHeight)").font(.caption).foregroundStyle(.secondary)
            Text(position).font(.callout.monospacedDigit())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .environment(\.colorScheme, .dark)
        .padding(12)
    }

    private func suggestionLine(_ s: Suggestion) -> String {
        var parts: [String] = []
        if s.stars > 0 { parts.append("Suggested \(s.stars)★ (A to accept)") }
        let reasons = s.reasons.map(\.rawValue).joined(separator: ", ")
        if s.suggestsReject {
            parts.append("Consider rejecting: " + reasons)
        } else if !s.reasons.isEmpty {
            parts.append("\(reasons), but Photos thinks this one matters to you")
        }
        if let g = s.group {
            let kind = g.kind == .duplicate ? "copies" : "similar shots"
            parts.append(g.isBest ? "Suggested keeper of \(g.size) \(kind) (C to compare)"
                                  : "One of \(g.size) \(kind); another is suggested to keep (C to compare)")
        }
        return parts.joined(separator: " · ")
    }
}

/// I: Apple Photos' own scores for this photo, as read from its library.
struct ScoresPanel: View {
    let scores: AppleScores?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Apple Photos scores").font(.headline)
            if let s = scores, s.isAnalysed {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                    row("Overall aesthetic", s.overall)
                    row("Curation", s.curation)
                    row("Failure", s.failure)
                    row("Blurriness", s.blurriness)
                    row("Exposure", s.exposure)
                    row("Noise", s.noise)
                    row("Sharp subject", s.sharpSubject)
                    row("Composition", s.composition)
                    row("Lighting", s.lighting)
                }
                .font(.callout.monospacedDigit())
            } else {
                Text("Photos hasn't analysed this photo yet.").font(.callout).foregroundStyle(.secondary)
            }
            Text("I to hide").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .environment(\.colorScheme, .dark)
        .padding(12)
    }

    private func row(_ name: String, _ value: Double?) -> some View {
        GridRow {
            Text(name).foregroundStyle(.secondary)
            Text(value.map { String(format: "%+.3f", $0) } ?? "–").gridColumnAlignment(.trailing)
        }
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
        .overlay { PhotoBadges(decision: session.decision(asset), suggestion: session.suggestion(asset),
                                 isFavorite: session.isFavorite(asset), large: true) }
        .overlay {
            RoundedRectangle(cornerRadius: 4).strokeBorder(focused ? Color.accentColor : .white.opacity(0.15),
                                                           lineWidth: focused ? 3 : 1)
        }
        .contentShape(Rectangle())
        .photoContextMenu(asset, session: session)
        .onTapGesture { session.focusCompare(index) }
    }
}

/// Single view's right-click menu, for whichever photo is showing.
private struct CurrentPhotoMenu: ViewModifier {
    @ObservedObject var session: CullingSession

    func body(content: Content) -> some View {
        if let asset = session.current { content.photoContextMenu(asset, session: session) } else { content }
    }
}

