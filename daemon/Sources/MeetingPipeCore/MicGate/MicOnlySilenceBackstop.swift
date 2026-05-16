import Foundation

/// Mic-only-silence backstop (TECH-C7).
///
/// Catches the scenario where the user joins a meeting, every other
/// participant drops, and the user forgets to stop the recording.
/// The backstop fires when the writer has been emitting zero-amp
/// frames (any non-`.hot` MicGateVerdict) AND the system-audio
/// channel has been silent for longer than the configured window
/// (default 8 minutes).
///
/// Pure-logic type with explicit `ingest(verdict:hasSystemAudio:at:)`
/// + `reset()`. The host (RecordingStateMachine) feeds events and
/// stops the recording when `onTriggered` fires.
///
/// Threading: not internally synchronised. The host owns single-queue
/// access (writer thread or main).
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

    /// Reset to "no accumulated silence". Call at recording start.
    public func reset() {
        triggered = false
        silenceStart = nil
    }

    /// Feed the current MicGateVerdict + whether the SCStream
    /// right-channel buffer contains live audio. The host computes
    /// `hasSystemAudio` from its own buffer-level peak detector;
    /// the backstop does not have access to the right channel.
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
        case .hot:
            return false
        case .silentByRMS, .mutedByApp, .mutedByHardware, .uncertain:
            return true
        }
    }
}
