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
    static func decide(isRecording: Bool, engineRunning: Bool, stalled: Bool) -> Action {
        guard isRecording else { return .ignore }
        if !engineRunning { return .rearm }
        return stalled ? .rearm : .ignore
    }
}
