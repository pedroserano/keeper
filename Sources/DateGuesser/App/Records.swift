import Foundation
import DateGuessCore

/// A photo the scan found without a trustworthy date.
struct UndatedPhoto: Codable, Identifiable, Hashable {
    var id: String
    var reason: UndatedReason
    var libraryDate: Date?
    var format: FormatInfo
    var albums: [String]

    var filename: String { format.originalFilename ?? "Untitled" }
}

struct ScanOptions: Codable, Hashable {
    /// Read each original file's header to find photos whose date is only the import/scan time.
    var deepCheck = true
    /// Photos with GPS come from phones/cameras with clocks: trust their dates.
    var skipGPSTagged = true
    /// Download originals from iCloud when they aren't on this Mac (slow, uses bandwidth).
    var allowICloudDownloads = false
    var includeScreenshots = false
    /// Albums whose photos should all be treated as undated (PhotoKit collection identifiers).
    var undatedAlbumIDs: [String] = []
    var dateRangeRules: [DateRangeRule] = []
}

struct ScanSnapshot: Codable {
    var lastScan: Date?
    var totalAssets = 0
    var undated: [String: UndatedPhoto] = [:]
    /// Deep-checked photos that turned out to have a real capture date (lets re-scans skip them).
    var checkedDatedIDs: Set<String> = []
    var unverifiableCount = 0
}

/// Everything learned about one photo during estimation (before groups/people are applied).
struct PhotoAnalysis: Codable, Hashable {
    var assetID: String
    var localEvidence: [DateEvidence]
    var analyzedAt: Date
    /// Image fingerprint, carried from the engine to `AppState.featurePrints` (not saved here).
    var featurePrint: Data? = nil
    /// Which version of the on-device checks produced `localEvidence` (nil means version 1).
    var localVersion: Int? = nil
    /// Apple Intelligence's reading (macOS 27+), kept raw so its weight can change without re-analyzing.
    var modelSeason: Season? = nil
    var modelOccasion: SceneClues.Occasion? = nil
    /// Apple Intelligence has looked at this photo (so it isn't asked again).
    var modelChecked: Bool? = nil

    init(assetID: String, localEvidence: [DateEvidence], analyzedAt: Date, localVersion: Int? = nil) {
        self.assetID = assetID
        self.localEvidence = localEvidence
        self.analyzedAt = analyzedAt
        self.localVersion = localVersion
    }

    /// Bump when on-device rules change so existing photos are checked again.
    /// 2: exact scene labels (Santa and Christmas trees mean winter).
    static let currentLocalVersion = 2

    var isCurrent: Bool { (localVersion ?? 1) >= Self.currentLocalVersion }

    /// Clues from the photo itself.
    var evidence: [DateEvidence] {
        localEvidence + SceneClues.evidence(modelSeason: modelSeason, occasion: modelOccasion)
    }
}

/// The user's choices for one photo on the review screen.
struct ReviewDecision: Codable, Hashable {
    var selected = false
    var overrideYear: Int?
    var overrideSeason: Season?
    var ignored = false
    /// An exact month the user set (e.g. by dating a whole event).
    var overrideMonth: Int?

    var isOverridden: Bool { overrideYear != nil || overrideSeason != nil || overrideMonth != nil }
}

struct JournalEntry: Codable, Hashable {
    var assetID: String
    var previousDate: Date?
    var newDate: Date
}

/// One "Apply" click, kept so it can be undone.
struct ApplyBatch: Codable, Identifiable, Hashable {
    var id = UUID()
    var date: Date
    var entries: [JournalEntry]
    var failures: [String: String] = [:]
    var undone = false
    /// Photos in this batch whose previous date was put back on their own (e.g. by undoing one event).
    var undoneIDs: Set<String>? = nil

    /// Entries still in effect.
    var liveEntries: [JournalEntry] {
        guard !undone else { return [] }
        let gone = undoneIDs ?? []
        return gone.isEmpty ? entries : entries.filter { !gone.contains($0.assetID) }
    }
}

struct AppSettings: Codable, Hashable {
    var scan = ScanOptions()
    var allowExactMonth = true
    /// When you type a birthday, also save it to the person's linked Contacts card. Off unless turned on.
    var writeBirthdaysToContacts: Bool?
    /// No guesses before this year: the user knows their library has no older photos.
    var earliestYear: Int?
    /// The user chose "Not Now" when setup asked for the Photos library.
    var skippedLibrarySetup: Bool?
    /// The user chose "Not Now" when setup asked for Contacts access.
    var skippedContactsSetup: Bool?
    /// Ask Apple Intelligence for seasons and occasions where it's available. Nil means on.
    var useAppleIntelligence: Bool?
    /// The user clicked Stop: don't restart background analysis by itself (even after relaunching).
    var backgroundPaused: Bool?
}

/// A fused estimate ready for review.
struct ComputedEstimate: Hashable {
    var estimate: DateEstimate
    var evidence: [DateEvidence]
    var groupName: String?
    /// Look-alike undated photos that were dated together with this one.
    var matches: [String] = []
}
