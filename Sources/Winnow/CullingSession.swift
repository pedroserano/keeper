// One open library: what's being culled, where the cursor is, and every decision made.
//
// Built for big libraries: the photo list is PhotoKit's own lazy fetch result, so opening never
// loads every photo. Filters that must look at every photo, and the sidebar counts, run in the
// background.
//
// Decisions apply instantly to the screen and Winnow's database, then are written to Photos
// in order on a serial queue. If a Photos write fails, that decision is rolled back.

import AppKit
import os
import Photos
import SwiftUI
import WinnowKit

let log = Logger(subsystem: "local.winnow", category: "session")

/// The photos being culled, in order. Indexes into a PhotoKit fetch result instead of holding
/// the photos, so a 100,000-photo library costs almost nothing until photos are on screen.
struct AssetList: @unchecked Sendable {
    let result: PHFetchResult<PHAsset>
    /// Positions in `result` that pass the filter, ascending; nil means all of them.
    let positions: [Int]?

    var count: Int { positions?.count ?? result.count }
    var isEmpty: Bool { count == 0 }
    var indices: Range<Int> { 0..<count }

    func asset(at index: Int) -> PHAsset { result.object(at: positions?[index] ?? index) }

    func index(of asset: PHAsset) -> Int? {
        let position = result.index(of: asset)
        guard position != NSNotFound else { return nil }
        guard let positions else { return position }
        // Binary search: positions are ascending.
        var lo = 0, hi = positions.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if positions[mid] == position { return mid }
            if positions[mid] < position { lo = mid + 1 } else { hi = mid - 1 }
        }
        return nil
    }

    static let empty = AssetList(result: PHAsset.fetchAssets(withLocalIdentifiers: [], options: nil), positions: nil)
}

@MainActor
final class CullingSession: ObservableObject {
    enum Mode: String { case grid, single, compare }

    enum Filter: String, CaseIterable, Identifiable, Sendable {
        case all = "All", unflagged = "Unflagged", picks = "Picks", rejects = "Rejects"
        var id: String { rawValue }
    }

    let library: PhotoLibrary
    let store: DecisionStore
    let libraryName: String

    @Published private(set) var source: Source = .allPhotos
    @Published var filter: Filter = .all { didSet { if filter != oldValue { reload() } } }
    @Published var newestFirst = false { didSet { if newestFirst != oldValue { reload() } } }
    @Published var mode: Mode = .grid { didSet { modeChanged(from: oldValue) } }
    @Published private(set) var list = AssetList.empty
    /// True while a filter is being worked out in the background.
    @Published private(set) var loading = false
    @Published private(set) var cursor = 0
    @Published private(set) var decisions: [String: Decision] = [:]
    @Published private(set) var history = History()
    @Published private(set) var counts: [Source: Int] = [:]

    @Published var zoomed = false
    @Published private(set) var zoomOnFace = false
    @Published private(set) var compareGroup: [PHAsset] = []
    @Published private(set) var compareFocus = 0
    @Published var allowDownloads = false
    @Published var message: String?

    /// Set by the grid so ↑ ↓ move a whole row.
    var gridColumns = 1

    private var filterTask: Task<Void, Never>?
    private var countsTask: Task<Void, Never>?
    private var writes: Task<Void, Never>?
    private var messageTask: Task<Void, Never>?

    init(library: PhotoLibrary, store: DecisionStore, libraryName: String) {
        self.library = library
        self.store = store
        self.libraryName = libraryName
        let started = ContinuousClock.now
        decisions = (try? store.all()) ?? [:]
        if let json = try? store.setting("source"), let data = json.data(using: .utf8),
           let saved = try? JSONDecoder().decode(Source.self, from: data) {
            source = saved
        }
        log.notice("open: loaded \(self.decisions.count) decisions in \(started.duration(to: .now))")
        library.onChange = { [weak self] change in self?.libraryChanged(change) }
        reload(restoreFrom: (try? store.setting("cursor.\(source.key)")) ?? nil)
        refreshCounts()
    }

    // MARK: State

    var current: PHAsset? { list.indices.contains(cursor) ? list.asset(at: cursor) : nil }

    /// The photo the next decision applies to: the focused frame in compare, otherwise the cursor.
    var target: PHAsset? {
        mode == .compare && compareGroup.indices.contains(compareFocus) ? compareGroup[compareFocus] : current
    }

    func decision(_ asset: PHAsset) -> Decision {
        decisions[asset.localIdentifier] ?? .untouched(asset.localIdentifier)
    }

    var rejectCount: Int { decisions.values.filter { $0.flag == .reject }.count }
    var pickCount: Int { decisions.values.filter { $0.flag == .pick }.count }

    // MARK: Sources and filters

    func select(_ newSource: Source) {
        guard newSource != source else { return }
        saveCursor()
        source = newSource
        if let data = try? JSONEncoder().encode(newSource) {
            try? store.setSetting("source", to: String(decoding: data, as: UTF8.self))
        }
        zoomed = false
        reload(restoreFrom: (try? store.setting("cursor.\(newSource.key)")) ?? nil)
    }

    /// Fetches the source (lazy, fast) and applies the filter. Decisions don't call this, so the
    /// list stays put while you work; switching source or filter does.
    private func reload(restoreFrom id: String? = nil) {
        let keepID = id ?? current?.localIdentifier
        let started = ContinuousClock.now
        let result = library.fetch(source, newestFirst: newestFirst)
        log.notice("open: fetched \(result.count) photos for \(self.source.title) in \(started.duration(to: .now))")
        apply(result, keepingID: keepID)
    }

    private func apply(_ result: PHFetchResult<PHAsset>, keepingID: String?) {
        filterTask?.cancel()
        let keepAsset = keepingID.flatMap { library.assets(withIDs: [$0]).first }

        // The common case needs no scan: every photo in the source, straight from PhotoKit.
        if filter == .all && source != .unreviewed {
            loading = false
            setList(AssetList(result: result, positions: nil), keeping: keepAsset)
            return
        }

        // Anything else means checking each photo's decision; do that in the background.
        loading = true
        let snapshot = decisions
        let filter = filter
        let unseenOnly = source == .unreviewed
        filterTask = Task { [weak self] in
            let started = ContinuousClock.now
            let positions = await Task.detached(priority: .userInitiated) { () -> [Int] in
                var out: [Int] = []
                result.enumerateObjects { asset, i, stop in
                    if Task.isCancelled { stop.pointee = true; return }
                    let d = snapshot[asset.localIdentifier]
                    if unseenOnly, d?.seenAt != nil { return }
                    let flag = d?.flag ?? .none
                    switch filter {
                    case .all: out.append(i)
                    case .unflagged: if flag == .none { out.append(i) }
                    case .picks: if flag == .pick { out.append(i) }
                    case .rejects: if flag == .reject { out.append(i) }
                    }
                }
                return out
            }.value
            guard let self, !Task.isCancelled else { return }
            log.notice("open: filtered \(result.count) photos to \(positions.count) in \(started.duration(to: .now))")
            self.loading = false
            self.setList(AssetList(result: result, positions: positions), keeping: keepAsset)
        }
    }

    private func setList(_ newList: AssetList, keeping asset: PHAsset?) {
        list = newList
        if let asset, let i = newList.index(of: asset) {
            cursor = i
        } else {
            cursor = min(cursor, max(newList.count - 1, 0))
        }
        if mode == .compare { rebuildCompareGroup() }
    }

    /// Sidebar counts, worked out in the background. Unreviewed is "all photos minus the ones
    /// you've looked at", from Winnow's own records, so it never scans the library.
    func refreshCounts() {
        countsTask?.cancel()
        let library = library
        let seen = decisions.values.filter { $0.seenAt != nil }.count
        let albums = library.albums.map { Source.album(id: $0.localIdentifier, title: $0.localizedTitle ?? "Untitled") }
        countsTask = Task { [weak self] in
            let started = ContinuousClock.now
            let out = await Task.detached(priority: .utility) { () -> [Source: Int] in
                var out: [Source: Int] = [:]
                let all = library.fetch(.allPhotos, newestFirst: false).count
                out[.allPhotos] = all
                out[.unreviewed] = max(all - seen, 0)
                for s in [Source.favorites, .screenshots, .bursts] + albums {
                    if Task.isCancelled { break }
                    out[s] = library.fetch(s, newestFirst: false).count
                }
                return out
            }.value
            guard let self, !Task.isCancelled else { return }
            log.notice("open: counted \(out.count) sources in \(started.duration(to: .now))")
            self.counts = out
        }
    }

    // MARK: Library changes

    private func libraryChanged(_ change: PHChange) {
        guard let details = change.changeDetails(for: list.result) else { return }
        let after = details.fetchResultAfterChanges

        // The common case — our own favorite writes — changes objects in place: positions still hold.
        if details.hasIncrementalChanges,
           (details.insertedIndexes?.count ?? 0) == 0, (details.removedIndexes?.count ?? 0) == 0 {
            list = AssetList(result: after, positions: list.positions)
            return
        }

        // Photos added or removed (hidden, deleted, imported): stay on the same photo if it's still
        // there, otherwise on the same position, which is now the next photo.
        let keep = current
        if list.positions == nil {
            setList(AssetList(result: after, positions: nil), keeping: keep)
        } else {
            apply(after, keepingID: keep?.localIdentifier)
        }
        refreshCounts()
    }

    // MARK: Moving

    func select(index: Int) {
        guard list.indices.contains(index) else { return }
        cursor = index
        if mode != .grid { markSeen(current) }
        if mode == .compare { rebuildCompareGroup() }
        saveCursor()
    }

    func move(by delta: Int) {
        guard !list.isEmpty else { return }
        if mode == .compare {
            let next = compareFocus + delta
            if compareGroup.indices.contains(next) {
                compareFocus = next
                markSeen(compareGroup[next])
                return
            }
            // Past the edge of the group: go to the photo after (or before) it.
            let positions = compareGroup.compactMap { list.index(of: $0) }
            let edge = delta > 0 ? (positions.max() ?? cursor) + 1 : (positions.min() ?? cursor) - 1
            select(index: min(max(edge, 0), list.count - 1))
            return
        }
        zoomed = false
        select(index: min(max(cursor + delta, 0), list.count - 1))
    }

    private func modeChanged(from old: Mode) {
        zoomed = false
        if mode == .compare { rebuildCompareGroup() }
        if mode != .grid { markSeen(current) }
    }

    private func saveCursor() {
        try? store.setSetting("cursor.\(source.key)", to: current?.localIdentifier)
    }

    private func markSeen(_ asset: PHAsset?) {
        guard let asset, decision(asset).seenAt == nil else { return }
        var d = decision(asset)
        d.seenAt = Date()
        d.updatedAt = Date()
        decisions[asset.localIdentifier] = d
        try? store.save([d])
    }

    // MARK: Compare

    func focusCompare(_ index: Int) {
        guard compareGroup.indices.contains(index) else { return }
        compareFocus = index
        markSeen(compareGroup[index])
    }

    /// The frames of the current photo's burst, or photos taken within 10 seconds of it (2–4 in all).
    private func rebuildCompareGroup() {
        guard let cur = current else { compareGroup = []; return }
        var group: [PHAsset]
        if let burst = cur.burstIdentifier {
            let frames = library.burstFrames(burst)
            let center = frames.firstIndex { $0.localIdentifier == cur.localIdentifier } ?? 0
            let start = min(max(center - 1, 0), max(frames.count - 4, 0))
            group = Array(frames[start..<min(start + 4, frames.count)])
        } else {
            let t = cur.creationDate ?? .distantPast
            let near = { (i: Int) in abs((self.list.asset(at: i).creationDate ?? .distantPast).timeIntervalSince(t)) <= 10 }
            var lo = cursor, hi = cursor
            while hi - lo < 3, hi + 1 < list.count, near(hi + 1) { hi += 1 }
            while hi - lo < 3, lo > 0, near(lo - 1) { lo -= 1 }
            if lo == hi, hi + 1 < list.count { hi += 1 } // nothing close in time: compare with the next photo
            group = (lo...hi).map { list.asset(at: $0) }
        }
        compareGroup = group
        compareFocus = group.firstIndex { $0.localIdentifier == cur.localIdentifier } ?? 0
    }

    // MARK: Decisions

    func perform(_ action: Action) {
        guard let asset = target else { return }
        let label = switch action {
        case .rate(let n): n == 0 ? "Clear Rating" : "Rate \(n) Stars"
        case .pick: "Pick"
        case .reject: "Reject"
        case .clearFlag: "Clear Flag"
        case .toggleHidden: decision(asset).hidden ? "Unhide" : "Hide"
        }
        var after = decision(asset).applying(action, currentFavorite: asset.isFavorite)
        after.seenAt = after.seenAt ?? Date()
        commit(Change(label: label, before: [decision(asset)], after: [after]))

        // Auto-advance, except in compare (you keep working the group) and after hiding
        // (the photo leaves the list, so the next one is already under the cursor).
        if mode != .compare, action != .toggleHidden { move(by: 1) }
    }

    /// Compare view: keep the focused frame, reject the rest of the group.
    func keepFocusedRejectRest() {
        guard mode == .compare, compareGroup.indices.contains(compareFocus) else { return }
        let before = compareGroup.map(decision)
        let after = compareGroup.enumerated().map { i, a in
            var d = decision(a).applying(i == compareFocus ? .pick : .reject, currentFavorite: a.isFavorite)
            d.seenAt = d.seenAt ?? Date()
            return d
        }
        commit(Change(label: "Keep One, Reject \(compareGroup.count - 1)", before: before, after: after))
    }

    func undo() {
        guard let change = history.undo() else { return }
        commit(change, record: false)
        show("Undo \(change.label)")
        revealFirst(of: change)
    }

    func redo() {
        guard let change = history.redo() else { return }
        commit(change, record: false)
        show("Redo \(change.label)")
        revealFirst(of: change)
    }

    private func revealFirst(of change: Change) {
        guard mode != .compare, let id = change.after.first?.assetID,
              let asset = library.assets(withIDs: [id]).first, let i = list.index(of: asset) else { return }
        select(index: i)
    }

    private func commit(_ change: Change, record: Bool = true) {
        var after = change.after
        let missingCloud = after.filter { $0.cloudID == nil }.map(\.assetID)
        if !missingCloud.isEmpty {
            let ids = library.cloudIDs(for: missingCloud)
            for i in after.indices where after[i].cloudID == nil { after[i].cloudID = ids[after[i].assetID] }
        }
        for d in after { decisions[d.assetID] = d }
        do {
            try store.save(after)
        } catch {
            show("Couldn't save: \(error.localizedDescription)")
        }
        if record { history.record(Change(label: change.label, before: change.before, after: after)) }

        let pairs = Array(zip(change.before, after))
        let previous = writes
        writes = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            // Fetch fresh objects so "is it a favorite now" reflects earlier writes.
            let assets = Dictionary(self.library.assets(withIDs: pairs.map(\.0.assetID)).map { ($0.localIdentifier, $0) },
                                    uniquingKeysWith: { a, _ in a })
            let items = pairs.compactMap { before, after -> (asset: PHAsset, change: PhotosChange)? in
                guard let asset = assets[after.assetID] else { return nil }
                return (asset, PhotosChange(from: before, to: after, currentFavorite: asset.isFavorite))
            }
            do {
                try await self.library.apply(items)
            } catch {
                // Roll back so Winnow never shows a state Photos doesn't have.
                for d in change.before { self.decisions[d.assetID] = d }
                try? self.store.save(change.before)
                if record { self.history.discardLast() }
                self.show("Couldn't update Photos: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Delete queue

    func rejectedAssets() -> [PHAsset] {
        library.assets(withIDs: decisions.values.filter { $0.flag == .reject }.map(\.assetID))
    }

    /// Returns true if the photos were deleted.
    func deleteRejected() async -> Bool {
        await writes?.value
        let assets = rejectedAssets()
        guard !assets.isEmpty else { return false }
        do {
            try await library.delete(assets)
        } catch {
            if (error as? PHPhotosError)?.code == .userCancelled {
                show("Nothing deleted.")
            } else {
                show("Couldn't delete: \(error.localizedDescription)")
            }
            return false
        }
        let ids = assets.map(\.localIdentifier)
        for id in ids { decisions[id] = nil }
        try? store.remove(ids)
        // Winnow can't bring deleted photos back (Photos' Recently Deleted can), so undo stops here.
        history.clear()
        show("Deleted \(ids.count) photos. They're in Recently Deleted in Photos for 30 days.")
        return true
    }

    // MARK: Zoom

    func toggleZoom(onFace: Bool) {
        guard mode != .grid else { return }
        if zoomed, zoomOnFace == onFace {
            zoomed = false
        } else {
            zoomOnFace = onFace
            zoomed = true
        }
    }

    // MARK: Messages

    func show(_ text: String) {
        message = text
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { self?.message = nil }
        }
    }
}
