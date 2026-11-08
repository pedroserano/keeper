import Foundation

/// Saves app data as JSON files in Application Support. Writes happen off the main thread.
final class JSONStore: @unchecked Sendable {
    /// The store for the open library. Keeper replaces it, before making a `DatesModel`, when it
    /// opens a different library, so each library keeps its own dates data.
    static var shared = JSONStore()

    let directory: URL
    private let queue = DispatchQueue(label: "Keeper.dates.store", qos: .utility)

    init(directory chosen: URL? = nil) {
        if let custom = ProcessInfo.processInfo.environment["PDG_DATA_DIR"], !custom.isEmpty {
            // Used by tests so they never touch real app data.
            directory = URL(fileURLWithPath: custom, isDirectory: true)
        } else if let chosen {
            directory = chosen
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            directory = base.appendingPathComponent("Keeper/Dates", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func url(_ name: String) -> URL { directory.appendingPathComponent("\(name).json") }

    /// Values decoded ahead of time off the main thread (see `preload`), handed out once.
    private var preloaded: [String: Any] = [:]
    private let preloadLock = NSLock()

    private func takePreloaded<T>(_ key: String) -> T? {
        preloadLock.lock(); defer { preloadLock.unlock() }
        guard let value = preloaded[key] as? T else { return nil }
        preloaded[key] = nil
        return value
    }

    /// Decodes a file now, on whatever thread calls this, so a later `load` on the main thread is instant.
    func preload<T: Decodable>(_ type: T.Type, from name: String) {
        guard let value = decode(type, from: name) else { return }
        preloadLock.lock(); preloaded["json:" + name] = value; preloadLock.unlock()
    }

    func preloadBinary<T: Decodable>(_ type: T.Type, from name: String) {
        guard let value = decodeBinary(type, from: name) else { return }
        preloadLock.lock(); preloaded["plist:" + name] = value; preloadLock.unlock()
    }

    func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        if let value: T = takePreloaded("json:" + name) { return value }
        return decode(type, from: name)
    }

    private func decode<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(T.self, from: data)
    }

    func save<T: Encodable & Sendable>(_ value: T, to name: String) {
        let target = url(name)
        queue.async {
            let started = ContinuousClock.now
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            guard let data = try? encoder.encode(value) else { return }
            try? data.write(to: target, options: .atomic)
            Self.noteSave(name, bytes: data.count, since: started)
        }
    }

    /// Binary property list: much smaller than JSON for raw `Data` values like image fingerprints.
    func loadBinary<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        if let value: T = takePreloaded("plist:" + name) { return value }
        return decodeBinary(type, from: name)
    }

    private func decodeBinary<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("\(name).plist")) else { return nil }
        return try? PropertyListDecoder().decode(T.self, from: data)
    }

    func saveBinary<T: Encodable & Sendable>(_ value: T, to name: String) {
        let target = directory.appendingPathComponent("\(name).plist")
        queue.async {
            let started = ContinuousClock.now
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            guard let data = try? encoder.encode(value) else { return }
            try? data.write(to: target, options: .atomic)
            Self.noteSave(name, bytes: data.count, since: started)
        }
    }

    /// Logs saves that took a noticeable time (the file's kind, size and time; never its contents).
    private static func noteSave(_ name: String, bytes: Int, since started: ContinuousClock.Instant) {
        guard started.duration(to: .now) > .milliseconds(50) else { return }
        Timing.note("saved \(name) (\(bytes / 1_000_000) MB)", since: started)
    }

    /// Blocks until queued writes finish (used at quit).
    func flush() { queue.sync {} }
}
