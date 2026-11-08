import Foundation
import os

/// How long the Dates work takes, in Keeper's log ("timing: dates links #2 3.41 s"), to see where
/// time goes. Counts and times only: no names or paths.
enum Timing {
    static let log = Logger(subsystem: "local.keeper", category: "dates")

    static func seconds(since start: ContinuousClock.Instant) -> String {
        let c = start.duration(to: .now).components
        return String(format: "%.2f s", Double(c.seconds) + Double(c.attoseconds) / 1e18)
    }

    static func note(_ stage: String, since start: ContinuousClock.Instant) {
        let text = "timing: dates \(stage) \(seconds(since: start))"
        log.notice("\(text, privacy: .public)")
    }

    static func note(_ text: String) {
        log.notice("timing: dates \(text, privacy: .public)")
    }
}
