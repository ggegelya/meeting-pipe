import Foundation

/// Silence backstop (TECH-C7): fires when the mic is non-`.hot` AND system audio has been silent for longer than the configured window (default 8 min), catching the "last person in a call" forgotten-recording scenario. Pure logic; the host (RecordingStateMachine) feeds `ingest` and stops recording on `onTriggered`. Not internally synchronised; host owns queue access.
public final class MicOnlySilenceBackstop {

    public typealias Clock = () -> Date

    public let windowSeconds: TimeInterval
    public var onTriggered: ((Date) -> Void)?
    public private(set) var triggered: Bool = false

    private let clock: Clock
    private var silenceStart: Date?

    public static let defaultWindowSeconds: TimeInterval = 480

    public init(
        windowSeconds: TimeInterval = MicOnlySilenceBackstop.defaultWindowSeconds,
        clock: @escaping Clock = { Date() }
    ) {
        self.windowSeconds = windowSeconds
        self.clock = clock
    }

    /// Reset accumulated silence. Call at recording start.
    public func reset() {
        triggered = false
        silenceStart = nil
    }

    /// Feed the current verdict and whether the SCStream right channel has live audio. Host computes `hasSystemAudio` via its own peak detector; backstop has no direct right-channel access.
    public func ingest(
        verdict: MicGateVerdict,
        hasSystemAudio: Bool,
        at now: Date? = nil
    ) {
        if triggered { return }
        let timestamp = now ?? clock()
        let micSilent = isSilent(verdict)
        if !micSilent || hasSystemAudio {
            silenceStart = nil
            return
        }
        if silenceStart == nil {
            silenceStart = timestamp
            return
        }
        guard let start = silenceStart else { return }
        if timestamp.timeIntervalSince(start) >= windowSeconds {
            triggered = true
            onTriggered?(timestamp)
        }
    }

    private func isSilent(_ verdict: MicGateVerdict) -> Bool {
        switch verdict {
        case .hot(let reason):
            // The confidently-unmuted floor (TECH-MIC5) reports `.hot` to keep
            // audio, but the user is quiet, so it still counts as silence for the
            // forgotten-recording backstop. Real activity (VAD / RMS) does not.
            return reason == .confidentlyUnmuted
        case .silentByRMS, .mutedByApp, .mutedByHardware, .uncertain:
            return true
        }
    }
}
