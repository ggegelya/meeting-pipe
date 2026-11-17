import AppKit
import Foundation

/// The pure half of `MainThreadStallWatchdog` (PERF11): given how long a main-queue ping
/// waited, decide whether it is a row, whether it breaks the budget, and what the rate
/// limit does with it. Explicit inputs only, so the thresholds and the window are unit
/// tested without a timer or a run loop.
enum StallDetector {

    /// A wait at or over this is logged. The 2026-11-13 responsiveness audit's budget is
    /// "no single job over 50 ms, log a stall at 100 ms".
    static let logThresholdMs: Double = 100
    /// A wait at or over this is a bug: the row carries `over_budget: true`.
    static let overBudgetMs: Double = 250
    /// At most one row per this many seconds; stalls inside the window are counted into
    /// the next row's `suppressed`, so a pathological minute cannot flood the rotating log.
    static let rateLimitSeconds: TimeInterval = 10

    enum Decision: Equatable {
        /// Under the threshold: nothing to say.
        case none
        /// Inside the rate window: count it, emit nothing.
        case suppress
        /// Emit a row; `suppressed` is how many stalls the window swallowed since the last row.
        case emit(overBudget: Bool, suppressed: Int)
    }

    static func decide(
        waitMs: Double,
        nowUptime: TimeInterval,
        lastEmitUptime: TimeInterval?,
        suppressedSoFar: Int,
        thresholdMs: Double = logThresholdMs,
        overBudgetMs: Double = overBudgetMs,
        rateLimitSeconds: TimeInterval = rateLimitSeconds
    ) -> Decision {
        guard waitMs >= thresholdMs else { return .none }
        if let last = lastEmitUptime, nowUptime - last < rateLimitSeconds { return .suppress }
        return .emit(overBudget: waitMs >= overBudgetMs, suppressed: suppressedSoFar)
    }
}

/// Says out loud when the main thread was blocked (PERF11), so "is it the app or the OS"
/// can be answered from `events.jsonl` instead of a mistimed live `sample`.
///
/// A utility-queue timer (every `defaultInterval`, 25 ms) posts one no-op to the main queue at
/// a time and measures how long it waited to run. 25 ms rather than the first build's 250 ms
/// (PERF11 amendment, 2026-11-17): a ping only measures the part of a stall left after it was
/// posted, so at 4 Hz a 200 ms stall was hit less than half the time and understated when it
/// was, and every logged duration was a lower bound short by up to a quarter second. At 25 ms
/// the understatement is at most 25 ms, well under the 100 ms threshold. The context snapshot
/// is refreshed at most every `contextRefreshSeconds`, so the faster ping does not run the
/// context closure on main forty times a second. The row is written when the stall ends (the ping finally
/// runs), never from a blocked main. Context cannot be read from main while it is blocked,
/// so each successful ping refreshes a snapshot (via `context`, which runs on main) and a
/// stall reports the last one, which describes the moment just before it began. The
/// frontmost app is read off main at emission.
///
/// OBS7's `last_ui_seq` is not attached: OBS7 has not landed, and this does not build a
/// second sequence counter. It adds the two attributes when it does.
final class MainThreadStallWatchdog: @unchecked Sendable {

    /// How often a ping is posted. 20 to 50 ms was the amendment's range; 25 ms bounds the
    /// understatement of any stall at a quarter of the log threshold.
    static let defaultInterval: TimeInterval = 0.025
    /// The context snapshot is refreshed at most this often (it describes the moment before a
    /// stall, so a quarter second of staleness costs nothing).
    static let contextRefreshSeconds: TimeInterval = 0.25

    private let queue = DispatchQueue(label: "meetingpipe.stall-watchdog", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let interval: TimeInterval
    private let thresholdMs: Double
    private let rateLimitSeconds: TimeInterval
    private let context: @Sendable () -> [String: Any]
    private let emit: @Sendable (_ attributes: [String: Any]) -> Void

    // All below are confined to `queue`.
    private var pingOutstanding = false
    private var snapshot: [String: Any] = [:]
    private var lastEmitUptime: TimeInterval?
    private var suppressed = 0
    private var lastContextUptime: TimeInterval?

    /// `context` runs on main (cheap reads only). `emit` defaults to the `perf` event.
    init(
        interval: TimeInterval = MainThreadStallWatchdog.defaultInterval,
        thresholdMs: Double = StallDetector.logThresholdMs,
        rateLimitSeconds: TimeInterval = StallDetector.rateLimitSeconds,
        context: @escaping @Sendable () -> [String: Any] = { [:] },
        emit: @escaping @Sendable ([String: Any]) -> Void = { attrs in
            Log.event(category: "perf", action: "main_thread_stall", attributes: attrs)
        }
    ) {
        self.interval = interval
        self.thresholdMs = thresholdMs
        self.rateLimitSeconds = rateLimitSeconds
        self.context = context
        self.emit = emit
    }

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(5))
            t.setEventHandler { [weak self] in self?.tick() }
            timer = t
            t.resume()
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
        }
    }

    private func tick() {
        guard !pingOutstanding else { return }
        pingOutstanding = true
        let postedAt = ProcessInfo.processInfo.systemUptime
        let wantsContext = lastContextUptime.map { postedAt - $0 >= Self.contextRefreshSeconds } ?? true
        let context = self.context
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let ranAt = ProcessInfo.processInfo.systemUptime
            let ctx = wantsContext ? context() : nil
            self.queue.async { self.completed(waitSeconds: ranAt - postedAt, nowUptime: ranAt, ctx: ctx) }
        }
    }

    private func completed(waitSeconds: TimeInterval, nowUptime: TimeInterval, ctx: [String: Any]?) {
        pingOutstanding = false
        let waitMs = waitSeconds * 1000
        let before = snapshot
        if let ctx {
            snapshot = ctx
            lastContextUptime = nowUptime
        }
        switch StallDetector.decide(
            waitMs: waitMs, nowUptime: nowUptime,
            lastEmitUptime: lastEmitUptime, suppressedSoFar: suppressed,
            thresholdMs: thresholdMs, rateLimitSeconds: rateLimitSeconds
        ) {
        case .none:
            return
        case .suppress:
            suppressed += 1
        case let .emit(overBudget, count):
            lastEmitUptime = nowUptime
            suppressed = 0
            var attrs = before
            attrs["duration_ms"] = Int(waitMs.rounded())
            attrs["over_budget"] = overBudget
            attrs["suppressed"] = count
            attrs["frontmost_app"] = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? NSNull()
            emit(attrs)
        }
    }
}
