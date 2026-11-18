import Foundation

/// UX82 item 2: stop launchd's 10 s respawn of an app that crashes during start.
///
/// The LaunchAgent's `KeepAlive = { SuccessfulExit = false }` brings the app back after every
/// non-zero exit, and its only guard, `ThrottleInterval` 10, spaces the respawns without ever
/// ending them. So the app counts its own crashes: a launch whose previous process left no clean
/// exit (`LaunchRecord`'s `previous_exit` reads `unclean`) is recorded, and more than
/// `threshold` of those inside `window` trips the breaker. A tripped launch stays up in a safe
/// idle mode (status item and menu only), which is what stops launchd: a running job is not
/// respawned.
///
/// Only unclean launches count. A requested relaunch, a quit and reopen, and a login all follow a
/// clean exit (or none on record), so a burst of deliberate restarts can never trip it.
enum CrashLoopBreaker {
    static let window: TimeInterval = 60
    /// More than this many unclean launches inside `window` trips. Five is the spec's "more than 5".
    static let threshold = 5
    /// The history never grows past this; older entries carry no information the window needs.
    static let historyLimit = 10

    struct Verdict: Equatable {
        /// What to persist for the next launch.
        let history: [Date]
        let tripped: Bool
        /// Unclean launches inside the window, this one included when it counted.
        let count: Int
    }

    /// Fold this launch into the history. `previousExit` is `LaunchRecord.Previous.exit`.
    static func decide(history: [Date], now: Date, previousExit: String) -> Verdict {
        var kept = history.filter { now.timeIntervalSince($0) < window && $0 <= now }
        let counted = previousExit == "unclean"
        if counted { kept.append(now) }
        kept = Array(kept.suffix(historyLimit))
        // Only a launch that itself followed a crash can trip: quitting the safe mode and
        // reopening inside the window follows a clean exit and starts normally.
        return Verdict(history: kept, tripped: counted && kept.count > threshold, count: kept.count)
    }

    // MARK: - Persistence (a file, written synchronously, like `LaunchRecord`'s)

    static let fileName = "crash-loop.json"

    private struct File: Codable { let launches: [Date] }

    static func load(from url: URL) -> [Date] {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return file.launches
    }

    static func save(_ launches: [Date], to url: URL) {
        guard let data = try? JSONEncoder().encode(File(launches: launches)) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Run once at the top of `App.main`, after `LaunchRecord.begin`. Returns whether this launch
    /// starts in safe mode.
    static func evaluate(logsDir: URL, previousExit: String, now: Date = Date()) -> Verdict {
        let url = logsDir.appendingPathComponent(fileName)
        let verdict = decide(history: load(from: url), now: now, previousExit: previousExit)
        save(verdict.history, to: url)
        return verdict
    }

    /// "Try a normal start": forget the history so the relaunch it requests is not counted.
    static func reset(logsDir: URL) {
        save([], to: logsDir.appendingPathComponent(fileName))
    }
}
