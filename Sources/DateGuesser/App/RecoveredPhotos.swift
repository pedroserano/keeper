// Photos dated the day they were recovered, not the day they were taken (see KeeperCore's
// RecoveryBatches). Undated Photos labels them and filters by them, and they never count as
// dated examples: their date says when they came back, not when they were taken.

import Foundation
import DateGuessCore
import KeeperCore

extension AppState {
    /// The recovery batch a photo came back in, if any.
    func recoveryBatch(_ id: String) -> RecoveryBatches.Batch? {
        recovered[String(id.prefix { $0 != "/" })]
    }

    /// Reads the recovery batches from the library's records, in the background. Recovered photos
    /// used as dated look-alikes until now are dropped from them, so look-alikes are found again.
    func loadRecoveryBatches() {
        guard let library = AppState.keeperLibrary else { return }
        Task.detached(priority: .utility) {
            let started = ContinuousClock.now
            let found = try? PhotosDatabase.readRecoveryBatches(inLibrary: library)
            if let found { Timing.note("recovered photos: \(found.photos.count) in \(found.batches.count) batches", since: started) }
            // How reliable each year album is, from its own photos with a camera date.
            let albumsStarted = ContinuousClock.now
            let albums = ((try? PhotosDatabase.readYearAlbums(inLibrary: library, yearInTitle: AlbumYears.year(inTitle:))) ?? [:])
                .mapValues { YearAlbum(year: $0.year, dated: $0.dated, sameYear: $0.sameYear, withinYear: $0.withinYear) }
            Timing.note("year albums: \(albums.count) albums, \(albums.values.reduce(0) { $0 + $1.dated }) dated photos", since: albumsStarted)
            await MainActor.run {
                if let found {
                    let wasExample = self.referenceCandidates.keys.contains { found.photos[String($0.prefix { $0 != "/" })] != nil }
                    self.recovered = found.photos
                    if wasExample { self.recomputeLinks() }
                }
                if self.yearAlbums != albums {
                    self.yearAlbums = albums
                    self.scheduleRecompute()
                }
            }
        }
    }
}
