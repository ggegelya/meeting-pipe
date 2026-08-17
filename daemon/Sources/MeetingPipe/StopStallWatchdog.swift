import Foundation

/// Says out loud when a stop the user asked for has not completed.
///
/// REC13(4). On 2026-08-14 `state_change recording -> stopping` was the last event
/// for 52 minutes. The recording never finished, `system.wav` kept growing at
/// ~394 KB/s toward the 4 GiB RIFF ceiling, and the whole of that produced **no
/// event, no notification and no UI affordance**: the only symptom the owner could
/// see was a Library row that never settled, and diagnosing it needed a live
/// `sample` of the running process.
///
/// This is a canary, not the fix. The fix is that every `AVAudioEngine` call on the
/// stop path is bounded now (`EngineTeardown`), so `.stopping` can no longer be
/// indefinite the way it was. The watchdog exists because that argument covers the
/// paths this task bounded, and the next wedge will be on one nobody has bounded
/// yet: when that happens the ceiling makes it readable from `events.jsonl` instead
/// of needing the process to still be alive.
///
/// Main-queue confined by convention, like the recovery-retry timer in
/// `MeetingRecorder` it is modelled on and like its owner `MeetingSessionController`
/// (which carries a documented `@unchecked Sendable` for the same invariant, so
/// `@MainActor` here would not compile at its call site). Every `arm` / `disarm` is
/// on main, and the fire path is scheduled onto main. `arm` and `disarm` pair;
/// re-arming replaces a pending fire.
final class StopStallWatchdog {

    /// How long a stop may take before it is reported. Real stops finish in well
    /// under a second; the two waits that legitimately take time are already
    /// bounded well below this (the writer drain at 10 s, the ffmpeg merge at its
    /// own ceiling), so a stop still running at 90 s is stuck, not slow.
    static let defaultCeilingSeconds: TimeInterval = 90

    private let ceilingSeconds: TimeInterval
    private var pending: DispatchWorkItem?

    init(ceilingSeconds: TimeInterval = StopStallWatchdog.defaultCeilingSeconds) {
        self.ceilingSeconds = ceilingSeconds
    }

    /// Start watching a stop of `file`. `onStall` fires on the main queue with the
    /// elapsed seconds if `disarm()` has not been called by the ceiling; the
    /// auditable event is emitted here so it lands whether or not the caller
    /// surfaces anything.
    func arm(file: URL, onStall: @escaping (TimeInterval) -> Void) {
        disarm()
        let armedAt = Date()
        let ceiling = ceilingSeconds
        let name = file.lastPathComponent
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pending != nil else { return }
            self.pending = nil
            let elapsed = Date().timeIntervalSince(armedAt)
            Log.event(category: "recorder", action: "stop_exceeded_ceiling", attributes: [
                "file": name,
                "elapsed_s": elapsed,
                "ceiling_s": ceiling,
            ])
            Log.writeLine(
                "recorder",
                "WARN: stop has not completed after \(Int(elapsed))s (ceiling \(Int(ceiling))s) for \(name) - the recording is still in stopping"
            )
            onStall(elapsed)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + ceilingSeconds, execute: work)
    }

    /// The stop completed (or was abandoned by its own bounds). Cancels a pending fire.
    func disarm() {
        pending?.cancel()
        pending = nil
    }

    /// The owner-facing sentence for a stall. Derived here rather than at the call
    /// site so the copy and the event stay one decision.
    static func stallMessage(elapsed: TimeInterval) -> String {
        "Still finishing a recording after \(Int(elapsed)) seconds. It is taking much longer than usual; check Diagnostics if it does not settle."
    }
}
