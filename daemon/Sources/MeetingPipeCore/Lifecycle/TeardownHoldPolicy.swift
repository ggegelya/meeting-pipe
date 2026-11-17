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

    /// END21 amendment (owner, 2026-11-16): how long before the mic release a Leave button or call
    /// window end still counts as the second signal a stop's cut needs. On a real leave the window
    /// goes 50 to 400 ms before Teams lets go of the mic (END14's corpus) and the Leave control up to
    /// DET8's 11.4 s before it, so "after the release" alone left those ends untrimmed on a Stop. The
    /// owner accepted the known cost: minimising, or Teams' compact view, inside this window before
    /// a headphone switch makes a Stop during the switch cut the few restorable seconds since it.
    public static let secondSignalLeadSec: TimeInterval = 30

    /// A hold shorter than this is not trimmed: a hold the teardown line confirms on its first
    /// consult is milliseconds old, and marking those would be churn. That was meant to be the
    /// normal Teams end; in the field it is rare (END16: the line confirmed 0 of 59 Teams ends
    /// from 2026-09-29 to 2026-11-13, which ended on the pair dwell 60 s after the mic release).
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

    /// Whether a hold on `context` asks Teams' teardown line at all: only a native Teams hold.
    /// END16 (G053): the guard used to be `.native` alone, so a Zoom, Webex or Slack hold under a
    /// live mic consulted the Teams watcher, and an unrelated Teams call unregistering after the
    /// recording started confirmed it. The family is `NativeLifecycleConfig.teams`'s, the same set
    /// `EndingReason.isDefinitive(forBundleID:)` reads the teardown evidence against.
    public static func consultsTeardown(for context: MeetingLifecycleContext) -> Bool {
        context.kind == .native && NativeLifecycleConfig.teams.bundleIDs.contains(context.bundleID)
    }

    /// One consult of Teams' teardown line against the open hold, or `nil` when there is nothing to
    /// ask: no hold, or a hold on anything but Teams (`consultsTeardown`), which Teams' log says
    /// nothing about. `lastTeardownAt` is the watcher's newest teardown, `nil` when the log is
    /// unreadable (no evidence since END17).
    public func consult(now: Date, lastTeardownAt: Date?, recordingStartedAt: Date?) -> CallTeardownOracle.Verdict? {
        guard let hold, Self.consultsTeardown(for: hold.context) else { return nil }
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
    ///   release, and the Leave button or the call window also went, after it or within
    ///   `secondSignalLeadSec` before it (the owner's amendment, same day). A headphone switch drops
    ///   only the mic, so a Stop pressed during one cuts nothing unless the window or the Leave
    ///   button went just before it.
    /// Where it never reported (browser, Webex, Slack, an unresolved mic), the owner's decision of
    /// 2026-11-16: the hold's start for a pair, teardown or definitive end, and nothing for a lone-dwell
    /// end, which is no evidence of when the call ended (F032), or for a stop.
    /// Holds under `minimumTrimmedHoldSec` are never cut, as before.
    public func trimPoint(concludingAt now: Date, evidence: HoldEvidence?, conclusion: Conclusion) -> Date? {
        guard let hold, now.timeIntervalSince(hold.startedAt) >= Self.minimumTrimmedHoldSec else { return nil }
        if let evidence, let processAudio = evidence.processAudio {
            guard processAudio == .ended, let releasedAt = evidence.releasedAt else { return nil }
            if conclusion == .stop, evidence.liveSinceRelease || !evidence.callWindowBacksRelease {
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

/// END16: which of a hold's teardown consults the host logs, and how many of them were blind.
///
/// The host consults once a second for the whole hold, so a row per consult would bury the log.
/// It logs edges instead: the first consult, and every later one where the watcher's newest
/// teardown stamp moved; the counts go out once, when the hold resolves. `blindConsults` is the
/// count the 2026-10-25 amendment asked for: consults made while the watcher could not read the
/// log, i.e. holds the oracle could not have helped. Pure; the host owns the clock and the rows.
public struct TeardownConsultLedger: Equatable {
    public enum Edge: String, Equatable {
        case first
        case stampChanged = "stamp_changed"
    }

    public private(set) var consults = 0
    public private(set) var blindConsults = 0
    private var lastStamp: Date?

    public init() {}

    /// Count one consult; returns the edge to log, or nil. A blind consult never moves the stamp,
    /// so the next readable one is compared with the last stamp actually read.
    public mutating func note(available: Bool, newestTeardownAt: Date?) -> Edge? {
        consults += 1
        guard available else {
            blindConsults += 1
            return consults == 1 ? .first : nil
        }
        defer { lastStamp = newestTeardownAt }
        if consults == 1 { return .first }
        return newestTeardownAt != lastStamp ? .stampChanged : nil
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
    /// The Leave button or the call window reads ended, having gone no earlier than
    /// `TeardownHoldPolicy.secondSignalLeadSec` before the release.
    public let callWindowBacksRelease: Bool

    public init(
        processAudio: PrimarySignalState?,
        releasedAt: Date?,
        liveSinceRelease: Bool,
        callWindowBacksRelease: Bool
    ) {
        self.processAudio = processAudio
        self.releasedAt = releasedAt
        self.liveSinceRelease = liveSinceRelease
        self.callWindowBacksRelease = callWindowBacksRelease
    }
}
