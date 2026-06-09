import Foundation

/// The single meeting-idle backstop (TECH-END3). Supersedes both the raw-RMS
/// `SilenceDetector` and the older `MicOnlySilenceBackstop`: one timing-pure unit,
/// gated on the MicGate verdict (which already fuses HAL VAD + RMS) rather than raw
/// level, so ambient room noise no longer resets the timer the way the RMS backstops
/// did (they fired 2x / 0x in 19.8 days). It catches the "everyone left and the user
/// forgot" case at a long horizon, the way the mature notetakers do (Granola ~15 min,
/// Otter ~10 min).
///
/// Two horizons off one idle streak: a "still meeting?" nudge, then the auto-stop. The
/// confidently-unmuted floor (TECH-MIC5) still counts as silence so a forgotten
/// recording auto-stops; real speech/activity (`voiceActivityDetected` /
/// `rmsAboveOpenThreshold`) or live system audio resets the streak.
///
/// Pure logic: the host feeds `ingest`, shows the nudge on `onNotify`, applies the
/// native-lifecycle stand-down on `onAutoStop` (stopping or re-arming via `keepAlive`),
/// and `reset`s at recording start. Not internally synchronised; host owns queue access.
public final class IdleStopBackstop {

    public typealias Clock = () -> Date

    /// Idle seconds before the "still meeting?" nudge (fires once per streak).
    public let notifySeconds: TimeInterval
    /// Idle seconds before the auto-stop fires.
    public let autoStopSeconds: TimeInterval

    /// "Still meeting?" nudge. Host shows the banner; the user can keep recording.
    public var onNotify: ((Date) -> Void)?
    /// Auto-stop. Host applies the native-lifecycle stand-down, then stops or re-arms.
    public var onAutoStop: ((Date) -> Void)?

    /// True once the auto-stop has fired; sticky until `reset`/`keepAlive` so trailing
    /// samples during an async recorder teardown cannot re-fire it.
    public private(set) var triggered: Bool = false

    private let clock: Clock
    private var silenceStart: Date?
    private var didNotify: Bool = false

    /// Granola stops after ~15 min of no new audio, Otter after ~10. 15 min default.
    public static let defaultAutoStopSeconds: TimeInterval = 900
    /// Mid-streak nudge so the user can confirm before the auto-stop.
    public static let defaultNotifySeconds: TimeInterval = 480

    /// A nudge horizon guaranteed to precede `autoStop`. The auto-stop horizon is
    /// user-configurable (Preferences slider, 60...1800 s); a fixed 480 s nudge would
    /// sit at or past the auto-stop for any setting <= 480 s and never fire (`ingest`
    /// checks the auto-stop first). Cap at the default but never exceed half the
    /// auto-stop, so the warning always lands before the stop.
    public static func safeNotifySeconds(forAutoStop autoStop: TimeInterval) -> TimeInterval {
        min(defaultNotifySeconds, autoStop / 2)
    }

    public init(
        notifySeconds: TimeInterval = IdleStopBackstop.defaultNotifySeconds,
        autoStopSeconds: TimeInterval = IdleStopBackstop.defaultAutoStopSeconds,
        clock: @escaping Clock = { Date() }
    ) {
        self.notifySeconds = notifySeconds
        self.autoStopSeconds = autoStopSeconds
        self.clock = clock
    }

    /// Reset accumulated idle. Call at recording start.
    public func reset() {
        triggered = false
        silenceStart = nil
        didNotify = false
    }

    /// Restart the idle countdown without ending: the native stand-down kept the
    /// recording, or the user tapped "Keep recording" on the nudge. The streak
    /// re-arms from the next sample and the nudge can fire again.
    public func keepAlive() {
        triggered = false
        silenceStart = nil
        didNotify = false
    }

    /// Feed the current verdict and whether the SCStream right channel carries live
    /// audio (host computes `hasSystemAudio` from its system-level mirror).
    public func ingest(
        verdict: MicGateVerdict,
        hasSystemAudio: Bool,
        at now: Date? = nil
    ) {
        if triggered { return }
        let timestamp = now ?? clock()
        if !isSilent(verdict) || hasSystemAudio {
            silenceStart = nil
            didNotify = false
            return
        }
        let start = silenceStart ?? timestamp
        silenceStart = start
        let elapsed = timestamp.timeIntervalSince(start)
        if elapsed >= autoStopSeconds {
            triggered = true
            onAutoStop?(timestamp)
            return
        }
        if elapsed >= notifySeconds && !didNotify {
            didNotify = true
            onNotify?(timestamp)
        }
    }

    private func isSilent(_ verdict: MicGateVerdict) -> Bool {
        switch verdict {
        case .hot(let reason):
            // The confidently-unmuted floor (TECH-MIC5) reports `.hot` to keep audio,
            // but the user is quiet, so it counts as silence for the forgotten-recording
            // backstop. Real activity (VAD / RMS) does not.
            return reason == .confidentlyUnmuted
        case .silentByRMS, .mutedByApp, .mutedByHardware, .uncertain:
            return true
        }
    }
}
