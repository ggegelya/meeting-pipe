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

    /// END21: how a hold concluded, which decides where (and whether) its tail is cut.
    public enum Conclusion: Equatable {
        /// The engine confirmed it on the pair dwell or a definitive signal.
        case engineEnd
        /// The engine confirmed it on the lone dwell alone.
        case loneDwell
        /// Teams' teardown line for this recording confirmed it.
        case teardown
        /// A stop inside the hold: the user's Stop or toggle, the panic key, the low-space and
        /// write-failure stops, the idle backstop, the URL scheme.
        case stop
    }

    public struct Hold: Equatable {
        public let context: MeetingLifecycleContext
        /// The first provisional's moment, never a later one's. The cut when no process audio
        /// reported; where it did, `trimPoint` cuts at the release instead (END21).
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
    /// hold. Re-entry keeps the first stamp, because a flapping signal must not move the hold's
    /// start (the cut, where no process audio reported) later.
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

    /// Where to cut the recording if the hold concludes at `now` by `conclusion`, or nil for no cut.
    /// Does not clear the hold; `release()` does.
    ///
    /// END21. Before, this was the hold's start whatever happened, and a Leave-led hold opens under a
    /// live mic and can sit there for the whole of a compact-view call, so a late genuine end cut every
    /// minute since the first doubt (G001). Now, where process audio reported (`evidence.processAudio`
    /// non-nil):
    /// - it still reads live: nothing is cut, the call was up;
    /// - it reads released: the cut is the release (never earlier than the hold's start). A stop
    ///   cuts there only under the owner's rule of 2026-11-16: no signal read live again after the
    ///   release, and the Leave button or the call window also went after it. A headphone switch drops
    ///   only the mic, so a Stop pressed during one cuts nothing.
    /// Where it never reported (browser, Webex, Slack, an unresolved mic), the owner's decision of
    /// 2026-11-16: the hold's start for a pair, teardown or definitive end, and nothing for a lone-dwell
    /// end, which is no evidence of when the call ended (F032), or for a stop.
    /// Holds under `minimumTrimmedHoldSec` are never cut, as before.
    public func trimPoint(concludingAt now: Date, evidence: HoldEvidence?, conclusion: Conclusion) -> Date? {
        guard let hold, now.timeIntervalSince(hold.startedAt) >= Self.minimumTrimmedHoldSec else { return nil }
        if let evidence, let processAudio = evidence.processAudio {
            guard processAudio == .ended, let releasedAt = evidence.releasedAt else { return nil }
            if conclusion == .stop, evidence.liveSinceRelease || !evidence.callWindowEndedSinceRelease {
                return nil
            }
            return max(releasedAt, hold.startedAt)
        }
        switch conclusion {
        case .engineEnd, .teardown:
            return hold.startedAt
        case .loneDwell, .stop:
            return nil
        }
    }

    /// Drop the hold, whether it concluded or the call came back. Returns what was dropped so the
    /// host can log how long it was held.
    @discardableResult
    public mutating func release() -> Hold? {
        defer { hold = nil }
        return hold
    }
}

/// END21: what the engine's readings say about a hold, for the host's trim decision. Built by
/// `PromotionEngine.holdEvidence` from its per-signal states, cached by `MeetingLifecycleCoordinator`
/// so the host reads it on main without reaching across to the engine queue.
public struct HoldEvidence: Equatable {
    /// Process audio's current reading, nil when it never reported in this engagement.
    public let processAudio: PrimarySignalState?
    /// When process audio went released, if it reads released now.
    public let releasedAt: Date?
    /// Some signal went live at or after the release.
    public let liveSinceRelease: Bool
    /// The Leave button or the call window went ended at or after the release and still reads so.
    public let callWindowEndedSinceRelease: Bool

    public init(
        processAudio: PrimarySignalState?,
        releasedAt: Date?,
        liveSinceRelease: Bool,
        callWindowEndedSinceRelease: Bool
    ) {
        self.processAudio = processAudio
        self.releasedAt = releasedAt
        self.liveSinceRelease = liveSinceRelease
        self.callWindowEndedSinceRelease = callWindowEndedSinceRelease
    }
}
