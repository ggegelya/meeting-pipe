import Foundation

/// REC8: the pure re-arm decision for the mic-tap liveness watchdog, lifted onto its
/// own type (the `MicGate.decide` idiom) so the un-gating is unit-tested without an
/// `AVAudioEngine`. Before REC8 the watchdog was gated on `engine.isRunning`, so a
/// silently STOPPED engine, the exact failure the watchdog exists to catch (a
/// sleep/wake or a HAL glitch can stop it without a configuration-change
/// notification), also disabled the check and was never re-armed. Now a stopped
/// engine re-arms regardless of the buffer counter, and a running-but-dry tap still
/// re-arms on the stall.
enum TapWatchdogPolicy {
    enum Action: Equatable {
        case ignore
        case rearm
    }

    /// `stalled` is the tap-liveness monitor's verdict, meaningful only while the
    /// engine is running (a stopped engine delivers no buffers, so its counter must
    /// not be consulted). The host passes `stalled: false` when the engine is stopped.
    ///
    /// `micAbandoned` is REC15's stop, and it is checked before everything else because it is
    /// the only input that says asking again cannot help. REC8's un-gating above is what makes
    /// it necessary: a stopped engine re-arms unconditionally, and every terminal return from
    /// `MeetingRecorder.recoverCapture` leaves the engine stopped, so a recovery that could not
    /// succeed re-armed once a second for the rest of the meeting (12 consecutive refusals
    /// measured 2026-08-19). REC8's reasoning is untouched: a stopped engine is still the
    /// strongest re-arm trigger there is, right up until the host has given up on the mic.
    static func decide(
        isRecording: Bool,
        engineRunning: Bool,
        stalled: Bool,
        micAbandoned: Bool = false
    ) -> Action {
        guard isRecording else { return .ignore }
        guard !micAbandoned else { return .ignore }
        if !engineRunning { return .rearm }
        return stalled ? .rearm : .ignore
    }

    /// REC15: whether this many consecutive failed recoveries has spent the budget.
    ///
    /// Here rather than inline at the call site so the off-by-one is pinned by a test: the
    /// budget counts failures, so a budget of 5 abandons on the fifth, not the sixth.
    static func budgetExhausted(consecutiveFailures: Int, budget: Int) -> Bool {
        consecutiveFailures >= budget
    }
}
