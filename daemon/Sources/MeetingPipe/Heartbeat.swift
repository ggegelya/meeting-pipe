import Foundation
import MeetingPipeCore

/// OBS5: `main` / `heartbeat`, once an hour, so uptime and a silent detector are measurable from
/// the log alone. Before it the only launch-scoped row was `engine_resolved`, and a daemon alive
/// for a week with no meeting left nothing between launch and exit.
///
/// The decision is pure (two dates in, emit or not out); `HeartbeatTicker` checks it every
/// `checkInterval` on a common-mode main-run-loop timer, so a fire swallowed by a sleep costs
/// minutes rather than the next hour, and a burst of fires on wake writes one row.
enum Heartbeat {
    static let interval: TimeInterval = 3600
    static let checkInterval: TimeInterval = 300

    /// Whether a heartbeat is due: `interval` has passed since the last one, or since the ticker
    /// started for the first. A clock that went backwards (a manual time change) is not a due beat.
    static func isDue(last: Date, now: Date, interval: TimeInterval = Heartbeat.interval) -> Bool {
        now.timeIntervalSince(last) >= interval
    }

    /// The row's attributes. Names only: the controller state's label and the bundle ids DET23's
    /// monitor reads as holding input, never a title. `launch_id` is stamped by `Log`.
    static func attributes(uptimeSec: Int, state: String, micHeldBy: [String]) -> [String: Any] {
        [
            "uptime_sec": uptimeSec,
            "state": state,
            "mic_held_by": micHeldBy.sorted(),
        ]
    }
}

/// The heartbeat's session-lifetime timer, a `SessionWatchers` member so the one
/// `watchers.startAll()` call starts it and its fence covers it (T7).
final class HeartbeatTicker: Startable {
    typealias Scheduler = (_ every: TimeInterval, _ action: @escaping () -> Void) -> () -> Void

    private let now: () -> Date
    private let schedule: Scheduler
    private let beat: () -> Void
    private var last: Date?
    private var cancel: (() -> Void)?

    /// - Parameter beat: writes the row; called on main, at most once per `Heartbeat.interval`.
    init(
        now: @escaping () -> Date = Date.init,
        schedule: @escaping Scheduler = { every, action in
            Schedulers.mainRunLoopRepeating(every: every, firstFire: Date().addingTimeInterval(every), tolerance: 30, action)
        },
        beat: @escaping () -> Void
    ) {
        self.now = now
        self.schedule = schedule
        self.beat = beat
    }

    var isRunning: Bool { cancel != nil }

    func start() {
        guard cancel == nil else { return }
        last = now()
        cancel = schedule(Heartbeat.checkInterval) { [weak self] in self?.check() }
    }

    func stop() {
        cancel?()
        cancel = nil
    }

    /// One timer fire: beats when due. Internal so a test can drive it without a run loop.
    func check() {
        let at = now()
        guard let last, Heartbeat.isDue(last: last, now: at) else { return }
        self.last = at
        beat()
    }
}
