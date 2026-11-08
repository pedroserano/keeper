import Foundation

/// Photos on screen come first, in Keeper's lists and in the Dates, Places and Albums screens.
/// Photos renders every app's requests in one queue, so a background scan asking for high-quality
/// previews hour after hour left the grid's photos on their blurry first image, waiting behind it. The scans call `waitUntilQuiet` before each photo, and so pause
/// while anything on screen is loading and for a moment after.
public final class ScreenImages: @unchecked Sendable {
    public static let shared = ScreenImages()
    private let lock = NSLock()
    private var loading = 0
    private var lastActivity = Date.distantPast
    /// How long after the last on-screen image a scan waits, so scrolling isn't interrupted.
    private let settle: TimeInterval = 1.5

    public init() {}

    public func begin() {
        lock.lock(); loading += 1; lastActivity = Date(); lock.unlock()
    }

    public func end() {
        lock.lock(); loading = max(0, loading - 1); lastActivity = Date(); lock.unlock()
    }

    public var isBusy: Bool {
        lock.lock(); defer { lock.unlock() }
        return loading > 0 || Date().timeIntervalSince(lastActivity) < settle
    }

    /// Blocks (for scan threads) until nothing on screen is loading, for at most `limit` seconds.
    public func waitUntilQuiet(limit: TimeInterval = 30) {
        let deadline = Date().addingTimeInterval(limit)
        while isBusy, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
    }

    /// The same, for Swift concurrency.
    public func waitUntilQuiet(limit: TimeInterval = 30) async {
        let deadline = Date().addingTimeInterval(limit)
        while isBusy, Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
    }
}
