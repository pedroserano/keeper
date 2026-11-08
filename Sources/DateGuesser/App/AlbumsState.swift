import DateGuessCore
import Foundation
import KeeperCore
import Observation
import Photos

/// The Albums section: albums to make from photos taken in one place, and copies of the same
/// picture an album holds twice. Changes go through PhotoKit; no photo is ever deleted.
@MainActor
@Observable
final class AlbumsState {
    @ObservationIgnored weak var app: AppState?
    @ObservationIgnored private let store = JSONStore.shared

    // MARK: Suggestions

    var suggestions: [AlbumSuggestions.Suggestion] = []
    /// Suggestions the user dismissed, by id. Kept, so they don't come back.
    var dismissed: Set<String> { didSet { store.save(dismissed, to: "albumSuggestionsDismissed") } }
    /// Names the user typed over the suggested ones.
    var names: [String: String] = [:]
    var isSuggesting = false
    var isCreating = false

    // MARK: Missing from albums

    var additions: [AlbumAdditions.Addition] = []
    /// "albumID|photoID" the user said don't belong. Kept, so they don't come back.
    var notInAlbum: Set<String> { didSet { store.save(notInAlbum, to: "albumAdditionsDismissed") } }
    /// "albumID|photoID" unticked before adding (only for now).
    var unticked: Set<String> = []
    var isLookingForAdditions = false
    var isAdding = false

    // MARK: Duplicates

    var duplicates: [AlbumDuplicates] = []
    var duplicatesProblem: String?
    var isReadingDuplicates = false
    var isRemoving = false
    /// The last copies taken out of an album, so they can be put back.
    var lastRemoval: (albumID: String, title: String, assetIDs: [String])?

    init() {
        dismissed = store.load(Set<String>.self, from: "albumSuggestionsDismissed") ?? []
        notInAlbum = store.load(Set<String>.self, from: "albumAdditionsDismissed") ?? []
    }

    var shownSuggestions: [AlbumSuggestions.Suggestion] { suggestions.filter { !dismissed.contains($0.id) } }

    func refresh() {
        refreshSuggestions()
        refreshAdditions()
        refreshDuplicates()
    }

    // MARK: Suggesting

    /// Located photos (and ones placed here), grouped into runs; then photos without a location
    /// taken during a run, which Places is sure were taken there, join it.
    func refreshSuggestions() {
        guard let app, app.isAuthorized, !isSuggesting else { return }
        let places = app.places
        let scan = places.scan
        guard scan.lastScan != nil else { return }
        let placed = places.placed
        let untrusted = places.untrustedDates()
        let guesses = places.guesses
        isSuggesting = true
        Task {
            let result = await Self.suggest(scan: scan, placed: placed, untrusted: untrusted, guesses: guesses)
            self.suggestions = result
            self.isSuggesting = false
        }
    }

    @concurrent
    nonisolated static func suggest(scan: PlacesScan, placed: [String: PlaceJournalEntry], untrusted: Set<String>,
                                    guesses: [String: PlaceGuessResult]) async -> [AlbumSuggestions.Suggestion] {
        var photos: [AlbumSuggestions.Photo] = []
        photos.reserveCapacity(scan.located.count + placed.count)
        for i in 0..<scan.located.count {
            photos.append(.init(id: scan.located.ids[i], time: scan.located.times[i], point: scan.located.point(i)))
        }
        for (id, entry) in placed where !untrusted.contains(id) {
            if let date = scan.missing[id] ?? nil { photos.append(.init(id: id, time: date, point: entry.new)) }
        }
        var timeOf = Dictionary(photos.map { ($0.id, $0.time) }, uniquingKeysWith: { a, _ in a })
        let albums = PhotoLibraryService.shared.userAlbumMembers().map { AlbumSuggestions.Album(title: $0.title, ids: $0.ids) }
        var out = AlbumSuggestions.suggest(photos, existing: albums)

        // Photos without a location from the same days, that Places places there with confidence.
        let inRun = Set(out.flatMap(\.ids))
        let candidates: [(id: String, time: Date, point: GeoPoint)] = guesses.compactMap { id, guess in
            guard guess.level == .high, !inRun.contains(id), !untrusted.contains(id), placed[id] == nil,
                  let date = scan.missing[id] ?? nil else { return nil }
            return (id, date, guess.estimate.point)
        }
        for i in out.indices {
            let s = out[i]
            let extra = candidates.filter {
                $0.time >= s.start && $0.time <= s.end && $0.point.distanceKm(to: s.center) <= AlbumSuggestions.areaKm
            }
            guard !extra.isEmpty else { continue }
            for c in extra { timeOf[c.id] = c.time }
            out[i].ids = (s.ids + extra.map(\.id)).sorted { (timeOf[$0] ?? .distantPast) < (timeOf[$1] ?? .distantPast) }
        }
        return out
    }

    /// The name shown and used: what the user typed, else "2026-08 Hartford". Nil while Apple Maps
    /// hasn't named the place yet. Only when it has no name for the spot is it just "2026-08".
    func name(for s: AlbumSuggestions.Suggestion) -> String? {
        if let typed = names[s.id] { return typed }
        guard let town = PlaceNames.shared.cityAnswer(for: s.center) else { return nil }
        return AlbumSuggestions.title(start: s.start, town: town)
    }

    /// The year and month, for while the place is being looked up.
    func month(for s: AlbumSuggestions.Suggestion) -> String { AlbumSuggestions.title(start: s.start, town: nil) }

    func dismiss(_ s: AlbumSuggestions.Suggestion) { dismissed.insert(s.id) }

    func create(_ s: AlbumSuggestions.Suggestion) {
        guard !isCreating else { return }
        guard let title = name(for: s)?.trimmingCharacters(in: .whitespaces), !title.isEmpty else { return }
        isCreating = true
        Task {
            let assets = PhotoLibraryService.shared.assets(for: s.ids)
            let ordered = s.ids.compactMap { assets[$0] }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
                    request.addAssets(ordered as NSArray)
                }
                self.app?.banner = "Made the album “\(title)” in Photos with \(ordered.count.formatted()) photos."
                self.dismissed.insert(s.id)
            } catch {
                self.app?.banner = "Couldn’t make the album: \(error.localizedDescription)"
            }
            self.isCreating = false
        }
    }

    // MARK: Adding to albums

    /// Photos in no album, with a location (or one Places is sure of), taken during a short album's
    /// days near where its photos were taken.
    func refreshAdditions() {
        guard let app, app.isAuthorized, !isLookingForAdditions else { return }
        let places = app.places
        let scan = places.scan
        guard scan.lastScan != nil else { return }
        let untrusted = places.untrustedDates()
        let guesses = places.guesses
        let placed = places.placed
        let dismissed = notInAlbum
        isLookingForAdditions = true
        Task {
            var found = await Self.additions(scan: scan, placed: placed, untrusted: untrusted, guesses: guesses)
            for i in found.indices {
                let album = found[i].albumID
                found[i].ids.removeAll { dismissed.contains(album + "|" + $0) }
            }
            self.additions = found.filter { !$0.ids.isEmpty }
            self.isLookingForAdditions = false
        }
    }

    @concurrent
    nonisolated static func additions(scan: PlacesScan, placed: [String: PlaceJournalEntry], untrusted: Set<String>,
                                      guesses: [String: PlaceGuessResult]) async -> [AlbumAdditions.Addition] {
        let albums = PhotoLibraryService.shared.userAlbumDetails()
        var inSomeAlbum = Set<String>()
        for a in albums { inSomeAlbum.formUnion(a.ids) }
        var loose: [AlbumSuggestions.Photo] = []
        for i in 0..<scan.located.count where !inSomeAlbum.contains(scan.located.ids[i]) {
            loose.append(.init(id: scan.located.ids[i], time: scan.located.times[i], point: scan.located.point(i)))
        }
        for (id, entry) in placed where !inSomeAlbum.contains(id) && !untrusted.contains(id) {
            if let date = scan.missing[id] ?? nil { loose.append(.init(id: id, time: date, point: entry.new)) }
        }
        for (id, guess) in guesses where guess.level == .high && placed[id] == nil && !untrusted.contains(id) && !inSomeAlbum.contains(id) {
            if let date = scan.missing[id] ?? nil { loose.append(.init(id: id, time: date, point: guess.estimate.point)) }
        }
        let windows = albums.map { AlbumAdditions.Album(id: $0.id, title: $0.title, located: $0.located) }
        return AlbumAdditions.suggest(albums: windows, loose: loose)
    }

    func isTicked(_ id: String, in a: AlbumAdditions.Addition) -> Bool { !unticked.contains(a.albumID + "|" + id) }

    func toggle(_ id: String, in a: AlbumAdditions.Addition) {
        let key = a.albumID + "|" + id
        if unticked.contains(key) { unticked.remove(key) } else { unticked.insert(key) }
    }

    func ticked(_ a: AlbumAdditions.Addition) -> [String] { a.ids.filter { isTicked($0, in: a) } }

    /// The unticked ones don't belong: they won't be suggested for this album again.
    func dismissUnticked(_ a: AlbumAdditions.Addition) {
        let keys = a.ids.filter { !isTicked($0, in: a) }.map { a.albumID + "|" + $0 }
        notInAlbum.formUnion(keys)
        unticked.subtract(keys)
        if let i = additions.firstIndex(where: { $0.albumID == a.albumID }) {
            additions[i].ids.removeAll { notInAlbum.contains(a.albumID + "|" + $0) }
            if additions[i].ids.isEmpty { additions.remove(at: i) }
        }
    }

    /// Dismisses the whole album's suggestions.
    func dismissAll(_ a: AlbumAdditions.Addition) {
        notInAlbum.formUnion(a.ids.map { a.albumID + "|" + $0 })
        additions.removeAll { $0.albumID == a.albumID }
    }

    /// Adds the ticked photos to the album. Only adds: nothing is removed or changed.
    func add(_ a: AlbumAdditions.Addition) {
        let ids = ticked(a)
        guard !isAdding, !ids.isEmpty else { return }
        isAdding = true
        Task {
            let assets = PhotoLibraryService.shared.assets(for: ids)
            let ordered = ids.compactMap { assets[$0] }
            do {
                guard let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [a.albumID], options: nil).firstObject,
                      collection.canPerform(.addContent) else { throw AlbumError("Photos doesn’t allow adding to this album.") }
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetCollectionChangeRequest(for: collection)?.addAssets(ordered as NSArray)
                }
                self.app?.banner = "Added \(ordered.count.formatted()) photos to “\(a.title)”."
                if let i = self.additions.firstIndex(where: { $0.albumID == a.albumID }) {
                    self.additions[i].ids.removeAll { ids.contains($0) }
                    if self.additions[i].ids.isEmpty { self.additions.remove(at: i) }
                }
            } catch {
                self.app?.banner = "Couldn’t add them: \(error.localizedDescription)"
            }
            self.isAdding = false
        }
    }

    // MARK: Duplicates

    func refreshDuplicates() {
        guard let library = AppState.keeperLibrary, !isReadingDuplicates else { return }
        isReadingDuplicates = true
        Task {
            let result = await Task.detached(priority: .utility) { () -> Result<[AlbumDuplicates], Error> in
                Result { try PhotosDatabase.readAlbumDuplicates(inLibrary: library) }
            }.value
            switch result {
            case .success(let found):
                self.duplicates = found
                self.duplicatesProblem = nil
            case .failure(let error):
                self.duplicates = []
                self.duplicatesProblem = error.localizedDescription
            }
            self.isReadingDuplicates = false
        }
    }

    nonisolated static func albumID(_ uuid: String) -> String { "\(uuid)/L0/040" }
    nonisolated static func assetID(_ uuid: String) -> String { "\(uuid)/L0/001" }

    /// Takes the later copies out of the album. Only out of the album: the photos stay in the
    /// library, and each group's first copy stays in the album. A group is skipped unless both are
    /// still in it.
    func removeExtras(from album: AlbumDuplicates) {
        guard !isRemoving else { return }
        isRemoving = true
        Task {
            let outcome = await Self.remove(album)
            switch outcome {
            case .success(let removed):
                self.lastRemoval = removed.isEmpty ? nil : (Self.albumID(album.albumUUID), album.title, removed)
                self.duplicates.removeAll { $0.albumUUID == album.albumUUID }
                self.app?.banner = removed.isEmpty
                    ? "Nothing was removed: the album changed in Photos. Look again to see what it holds now."
                    : "Took \(removed.count.formatted()) \(removed.count == 1 ? "copy" : "copies") out of “\(album.title)”. "
                      + "The photos are still in your library."
            case .failure(let error):
                self.app?.banner = "Couldn’t change the album: \(error.localizedDescription)"
            }
            self.isRemoving = false
            // Photos takes a moment to update its database.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self.refreshDuplicates()
        }
    }

    nonisolated static func remove(_ album: AlbumDuplicates) async -> Result<[String], Error> {
        let collections = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID(album.albumUUID)], options: nil)
        guard let collection = collections.firstObject, collection.assetCollectionType == .album,
              collection.canPerform(.removeContent) else {
            return .failure(AlbumError("Photos doesn’t allow changing this album."))
        }
        let contents = PHAsset.fetchAssets(in: collection, options: nil)
        var inAlbum: [String: PHAsset] = [:]
        contents.enumerateObjects { asset, _, _ in inAlbum[asset.localIdentifier] = asset }
        var extras: [PHAsset] = []
        for group in album.groups {
            let ids = group.map(assetID)
            // The copy that stays must still be in the album, or removing the rest would empty it of the picture.
            guard let keep = ids.first, inAlbum[keep] != nil else { continue }
            extras += ids.dropFirst().compactMap { inAlbum[$0] }
        }
        guard !extras.isEmpty else { return .success([]) }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                // Removing from an album; PHAssetChangeRequest.deleteAssets is never called here.
                PHAssetCollectionChangeRequest(for: collection, assets: contents)?.removeAssets(extras as NSArray)
            }
            return .success(extras.map(\.localIdentifier))
        } catch {
            return .failure(error)
        }
    }

    /// Puts the last removed copies back in their album.
    func putBack() {
        guard let removal = lastRemoval, !isRemoving else { return }
        isRemoving = true
        Task {
            let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [removal.albumID], options: nil).firstObject
            let assets = PhotoLibraryService.shared.assets(for: removal.assetIDs)
            do {
                guard let collection else { throw AlbumError("The album is no longer in Photos.") }
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetCollectionChangeRequest(for: collection)?.addAssets(Array(assets.values) as NSArray)
                }
                self.app?.banner = "Put \(assets.count.formatted()) back in “\(removal.title)”."
                self.lastRemoval = nil
            } catch {
                self.app?.banner = "Couldn’t put them back: \(error.localizedDescription)"
            }
            self.isRemoving = false
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self.refreshDuplicates()
        }
    }
}

struct AlbumError: LocalizedError {
    var errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
