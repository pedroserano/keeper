import CoreGraphics
import Foundation
import os
import DateGuessCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple Intelligence's on-device model (macOS 27+), asked only for the season and the occasion.
///
/// Tested on a real library it was poor at years (it guessed 2015–2019 for nearly everything), so it's
/// never asked for one. For seasons it answered on about a quarter of photos and was right on about
/// half of those (chance is 25%), so its answers count only as weak hints.
enum OnDeviceModel {
    struct Reading: Hashable {
        var season: Season?
        var occasion: SceneClues.Occasion?
    }

    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 27.0, *) {
            let model = SystemLanguageModel.default
            return model.availability == .available && model.capabilities.contains(.vision)
        }
        #endif
        return false
    }

    static let instructions = """
        You look at one photo and report only what is plainly visible. Season: judge from snow, bare trees, \
        leaf colors, blossoms, heavy or light clothing, or holiday decorations; if there is no such clue, say \
        unknown. Occasion: name it only if it is clearly shown (a Christmas tree, a birthday cake with candles, \
        Halloween costumes); otherwise say none.
        """

    static let question = """
        Answer on one line exactly like this: season: <winter|spring|summer|fall|unknown>; occasion: \
        <christmas|birthday|halloween|easter|thanksgiving|beach|wedding|graduation|none>
        """

    /// Gives up after `timeout` seconds, so one stuck answer can't hold up the whole analysis or the
    /// Stop button. (A task group would wait for a stuck model call anyway, so this races two
    /// unstructured tasks and returns whichever finishes first.)
    static func read(_ image: CGImage, timeout: Double = 30) async -> Reading? {
        let done = OSAllocatedUnfairLock(initialState: false)
        return await withCheckedContinuation { (continuation: CheckedContinuation<Reading?, Never>) in
            func finish(_ value: Reading?) {
                let first = done.withLock { already -> Bool in
                    defer { already = true }
                    return !already
                }
                if first { continuation.resume(returning: value) }
            }
            let work = Task { finish(await ask(image)) }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                work.cancel()
                finish(nil)
            }
        }
    }

    private static func ask(_ image: CGImage) async -> Reading? {
        #if canImport(FoundationModels)
        if #available(macOS 27.0, *) {
            let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
            guard let response = try? await session.respond(to: Prompt { question; Attachment(image) }) else { return nil }
            return parse(response.content)
        }
        #endif
        return nil
    }

    /// "season: winter; occasion: christmas" → winter, Christmas. Unknown words are ignored.
    static func parse(_ text: String) -> Reading {
        let lower = text.lowercased()
        func value(after key: String) -> String {
            guard let r = lower.range(of: key + ":") else { return "" }
            return lower[r.upperBound...].prefix { $0 != ";" && $0 != "\n" }.trimmingCharacters(in: .whitespaces)
        }
        let s = value(after: "season")
        let season: Season? = s.hasPrefix("winter") ? .winter : s.hasPrefix("spring") ? .spring
            : s.hasPrefix("summer") ? .summer : (s.hasPrefix("fall") || s.hasPrefix("autumn")) ? .fall : nil
        let occasion = SceneClues.Occasion(rawValue: value(after: "occasion").split(separator: " ").first.map(String.init) ?? "")
        return Reading(season: season, occasion: occasion)
    }
}
