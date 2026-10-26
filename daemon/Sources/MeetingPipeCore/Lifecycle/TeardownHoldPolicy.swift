import Foundation

/// T8: what END9's hold decides, with no clock and no host of its own.
///
/// A weak end opens a hold with the recorder running (END17, ADR 0017). The host,
/// `MeetingSessionController`, used to keep this state inline and stamp it with `Date()`, so the
/// only way to exercise the hold was a real controller and a real wall clock, and the detection
/// corpus modelled it with a `confirm_provisional_end` pseudo-event instead, which is the exact
/// path END9 replaced. Lifted here, the corpus's lifecycle replay drives the same decisions the
/// host does, on a virtual clock.
///
/// The decisions, and only those: where a hold starts and that a second provisional cannot move it,
/// what a consult asks `CallTeardownOracle`, where the held tail is cut, and dropping it. The host
/// keeps the 1 Hz `Timer`, the teardown watcher's snapshot reads, the event-log rows and the HUD,
/// and passes its clock in. Nothing here bounds a hold: since END17 the engine's dwells
/// (`PromotionEngine.tick`) do, and the oracle only ever confirms on evidence.
public struct TeardownHoldPolicy: Equatable {

    public struct Hold: Equatable {
        public let context: MeetingLifecycleContext
        /// Where the held tail starts: the first provisional's moment, never a later one's.
        public let startedAt: Date

        public init(context: MeetingLifecycleContext, startedAt: Date) {
            self.context = context
            self.startedAt = startedAt
        }
    }

    /// A hold shorter than this is not trimmed. The normal Teams end confirms on the first consult,
    /// a few milliseconds in, and marking those would be churn on every genuine leave.
    public static let minimumTrimmedHoldSec: TimeInterval = 1.0

    public private(set) var hold: Hold?

    public init() {}

    public var isOpen: Bool { hold != nil }

    /// Open a hold stamped `now`, or re-enter the open one. Returns `true` when this opened a new
    /// hold. Re-entry keeps the first stamp, because the stamp is where the held tail starts and a
    /// flapping signal must not move it later.
    @discardableResult
    public mutating func open(context: MeetingLifecycleContext, at now: Date) -> Bool {
        guard hold == nil else { return false }
        hold = Hold(context: context, startedAt: now)
        return true
    }

    /// One consult of Teams' teardown line against the open hold, or `nil` when there is nothing to
    /// ask: no hold, or a browser hold, which Teams' log says nothing about. `lastTeardownAt` is
    /// the watcher's newest teardown, `nil` when the log is unreadable (no evidence since END17).
    public func consult(now: Date, lastTeardownAt: Date?, recordingStartedAt: Date?) -> CallTeardownOracle.Verdict? {
        guard let hold, hold.context.kind == .native else { return nil }
        return CallTeardownOracle.decide(CallTeardownOracle.Input(
            now: now,
            provisionalStartedAt: hold.startedAt,
            lastTeardownAt: lastTeardownAt,
            // END10 item 6: without the recording's own start, a previous call's teardown inside
            // the lookback confirms this one.
            recordingStartedAt: recordingStartedAt
        ))
    }

    /// Where to cut the recording if the hold concludes in an end at `now`: its start, when it has
    /// been held at least `minimumTrimmedHoldSec`. Everything captured since it opened is post-call
    /// audio by construction. Does not clear the hold; `release()` does.
    public func trimPoint(concludingAt now: Date) -> Date? {
        guard let hold, now.timeIntervalSince(hold.startedAt) >= Self.minimumTrimmedHoldSec else { return nil }
        return hold.startedAt
    }

    /// Drop the hold, whether it concluded or the call came back. Returns what was dropped so the
    /// host can log how long it was held.
    @discardableResult
    public mutating func release() -> Hold? {
        defer { hold = nil }
        return hold
    }
}
