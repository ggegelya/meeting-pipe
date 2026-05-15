import Foundation

/// Owns the 1 Hz mic-mute probe that gates `recorder.micPaused` on the
/// meeting client's UI state. Lifted out of `Coordinator` so the seam
/// can be replaced event-driven in TECH-G-MIC without rewriting the
/// orchestrator. The behaviour and event names are preserved verbatim.
///
/// The subsystem captures a `MeetingWindowHandle` at `arm(source:)`,
/// polls it at 1 Hz, and fires `onTransition` whenever the recognised
/// state actually flips. `recorder.micPaused` itself stays the
/// Coordinator's responsibility — the subsystem only signals the
/// transition, the Coordinator flips the flag.
///
/// Threading: every entry point must run on the main queue. The Timer
/// fires there too, so the tick callback inherits main-queue safety.
final class MuteProbeSubsystem {

    enum Transition: Equatable {
        case paused(bundleID: String)
        case resumed(bundleID: String)
    }

    /// Function pointer for the AX evaluation. Defaults to the production
    /// probe; tests inject a stub so they don't need a live AX subtree.
    typealias Evaluator = (MeetingWindowHandle) -> MeetingMuteProbe.State

    /// Factory for the meeting-window capture. Defaults to the production
    /// `MeetingWindowProbe.capture`; tests inject a stub to return a
    /// canned handle (or nil) without driving AX.
    typealias WindowCapture = (AppSource) -> MeetingWindowHandle?

    var onTransition: ((Transition) -> Void)?

    private let evaluator: Evaluator
    private let windowCapture: WindowCapture
    private let pollInterval: TimeInterval

    private var timer: Timer?
    private var window: MeetingWindowHandle?
    private(set) var lastState: MeetingMuteProbe.State = .unknown

    init(
        evaluator: @escaping Evaluator = MeetingMuteProbe.evaluate,
        windowCapture: @escaping WindowCapture = MeetingWindowProbe.capture,
        pollInterval: TimeInterval = 1.0
    ) {
        self.evaluator = evaluator
        self.windowCapture = windowCapture
        self.pollInterval = pollInterval
    }

    /// Capture the meeting window for a native source and arm the timer.
    /// No-op when the probe is disabled by config, when the source is
    /// browser / manual (no native AX window to inspect), or when AX
    /// permission is missing (the capture returns nil and the recorder
    /// behaves as before). Returns true when the probe actually armed,
    /// so the caller can decide whether to log a follow-up event.
    @discardableResult
    func arm(source: AppSource?, enabled: Bool) -> Bool {
        disarmInternal(logIfStateKnown: false)
        guard enabled else { return false }
        guard let source = source, source.kind == .native else { return false }
        guard let handle = windowCapture(source) else {
            Log.writeLine(
                "daemon",
                "mute probe disabled: no AX window handle for \(source.bundleID)"
            )
            return false
        }
        window = handle
        Log.writeLine("daemon", "mute probe armed for \(source.bundleID)")
        Log.event(category: "coordinator", action: "mute_probe_armed", attributes: [
            "bundle_id": source.bundleID,
        ])
        // 1 Hz is responsive enough that a few hundred ms of speech
        // after toggling mute is the worst-case spillover. Faster
        // polling burns AX RPCs without meaningful UX benefit.
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        return true
    }

    func disarm() {
        disarmInternal(logIfStateKnown: true)
    }

    private func disarmInternal(logIfStateKnown: Bool) {
        timer?.invalidate()
        timer = nil
        window = nil
        // Leave the recorder's pause flag alone — it resets on the next
        // `start()`. Resetting here would race the stop flush which is
        // still draining buffered mic frames.
        if logIfStateKnown, lastState != .unknown {
            Log.event(category: "coordinator", action: "mute_probe_disarmed", attributes: [
                "last_state": Self.muteLabel(lastState),
            ])
        }
        lastState = .unknown
    }

    /// Exposed for tests that drive the timer manually rather than
    /// waiting on a wall-clock second. Production reuses this via the
    /// timer callback.
    func tick() {
        guard let handle = window else { return }
        let state = evaluator(handle)
        if state == lastState || state == .unknown { return }
        switch state {
        case .muted:
            Log.writeLine("daemon", "mute probe: user muted → pausing mic capture")
            Log.event(category: "coordinator", action: "mic_paused_due_to_mute", attributes: [
                "bundle_id": handle.bundleID,
            ])
            onTransition?(.paused(bundleID: handle.bundleID))
        case .unmuted:
            Log.writeLine("daemon", "mute probe: user unmuted → resuming mic capture")
            Log.event(category: "coordinator", action: "mic_resumed", attributes: [
                "bundle_id": handle.bundleID,
            ])
            onTransition?(.resumed(bundleID: handle.bundleID))
        case .unknown:
            return
        }
        lastState = state
    }

    private static func muteLabel(_ state: MeetingMuteProbe.State) -> String {
        switch state {
        case .muted: return "muted"
        case .unmuted: return "unmuted"
        case .unknown: return "unknown"
        }
    }
}
