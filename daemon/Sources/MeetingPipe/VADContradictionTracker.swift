import Foundation

/// MIC10 part 2: a *confidently-wrong* app-mute detector. The AX window watcher reads `.muted`
/// from the meeting client's control, but the OS voice-activity detector (independent of the app
/// UI) reports sustained voice. That contradiction means the AX read is stale - the live control
/// moved into a UI our matchers do not recognise (Teams' mini window), so the button we are
/// reading is a backgrounded/pre-join one. The blind-clear path only fires when the read goes
/// *blind*; this covers the case where the read stays confidently `.muted` while the user speaks.
///
/// The response is to DISCREDIT the read (re-resolve / `clearAxMute`), never a blanket unmute:
/// widening `MicGate.decide` to let VAD override app-mute would weaken the regulated gate on a
/// genuine muted side-conversation (the scope guard from q4-final MIC10). Mode-gating the discredit
/// lives in the host, not here.
///
/// Pure + clock-injected (the `RMSGateProbe` / `IdleStopBackstop` idiom) so the dwell is testable
/// without sleeping. Fires once per sustained streak and re-arms only when the contradiction ends,
/// so the discredit runs once rather than on every poll.
struct VADContradictionTracker {
    typealias Clock = () -> Date

    /// Seconds of sustained contradiction before the read is treated as stale. A few seconds:
    /// long enough that a transient VAD blip on room noise does not trip it, short enough to
    /// recover the user's voice within a sentence or two.
    static let defaultDwellSeconds: Double = 4.0

    let dwell: TimeInterval
    private let clock: Clock
    private var contradictionSince: Date?
    private var fired = false

    init(dwellSeconds: Double = VADContradictionTracker.defaultDwellSeconds, clock: @escaping Clock = { Date() }) {
        self.dwell = dwellSeconds
        self.clock = clock
    }

    /// Drop any in-flight streak. Call at engage/stop so a prior meeting's accumulator cannot bleed.
    mutating func reset() {
        contradictionSince = nil
        fired = false
    }

    /// Feed one observation. Returns true exactly on the tick the contradiction (app says muted,
    /// VAD says voice) has been sustained for `dwell`; false afterwards until the contradiction
    /// clears, so the caller discredits the read once rather than every poll.
    mutating func observe(appMuted: Bool, vadActive: Bool) -> Bool {
        guard appMuted && vadActive else {
            contradictionSince = nil
            fired = false
            return false
        }
        let now = clock()
        let start = contradictionSince ?? now
        contradictionSince = start
        if !fired && now.timeIntervalSince(start) >= dwell {
            fired = true
            return true
        }
        return false
    }
}
