import Foundation

/// OBS9: which `MicGate` verdict changes are worth a `verdict_changed` row, and the count of the
/// ones that are not. A verdict carries its reason, so a swap between two reasons that both pass
/// audio (`rms_above_open_threshold` and `confidently_unmuted`) used to be a row; in the field that
/// was 4,354 of 5,949 in-recording rows, and the event log's retention is set by its bytes. Now a
/// row is written only when what the verdict does changes, and the rest are counted into one
/// `verdict_churn` row per minute with activity, plus one when the gate stops. Pure: the caller
/// passes the clock.
struct VerdictChurn: Equatable {
    static let window: TimeInterval = 60

    /// Changes that wrote no `verdict_changed` row (same effect, another reason or label).
    private(set) var reasonSwaps = 0
    /// Transitions out of `silentByRMS`, and into it: the RMS gate opening and closing.
    private(set) var rmsOpens = 0
    private(set) var rmsCloses = 0
    private(set) var windowStart: Date?

    /// True when `next` differs from the last logged verdict in what it does: whether it passes
    /// live audio, or whether it indicates a mute. With nothing logged yet, any verdict counts.
    static func changesEffect(from logged: MicGateVerdict?, to next: MicGateVerdict) -> Bool {
        guard let logged else { return true }
        return logged.passesLiveAudio != next.passesLiveAudio || logged.indicatesMute != next.indicatesMute
    }

    /// Count one verdict change, `previous` to `next`, that was (`logged`) or was not written.
    mutating func note(previous: MicGateVerdict, next: MicGateVerdict, logged: Bool, at time: Date) {
        if windowStart == nil { windowStart = time }
        if !logged { reasonSwaps += 1 }
        let wasRMS = Self.isSilentByRMS(previous), isRMS = Self.isSilentByRMS(next)
        if wasRMS, !isRMS { rmsOpens += 1 }
        if !wasRMS, isRMS { rmsCloses += 1 }
    }

    /// The `verdict_churn` attributes when the window has run its minute (or `force`, at stop)
    /// and anything was counted, resetting the counts; nil otherwise.
    mutating func drain(at time: Date, force: Bool) -> [String: Any]? {
        guard let start = windowStart else { return nil }
        let elapsed = time.timeIntervalSince(start)
        guard force || elapsed >= Self.window else { return nil }
        let row: [String: Any]? = (reasonSwaps + rmsOpens + rmsCloses) > 0 ? [
            "reason_swaps": reasonSwaps,
            "rms_opens": rmsOpens,
            "rms_closes": rmsCloses,
            "window_sec": Int(max(0, elapsed).rounded()),
        ] : nil
        self = VerdictChurn()
        return row
    }

    private static func isSilentByRMS(_ verdict: MicGateVerdict) -> Bool {
        if case .silentByRMS = verdict { return true }
        return false
    }
}
