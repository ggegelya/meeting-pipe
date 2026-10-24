import Foundation

/// Which steps of a capture-engine teardown completed within their budget.
/// A step that timed out is ABANDONED (it keeps running on a global thread);
/// the caller proceeds to finalize the intermediates either way.
struct EngineTeardownOutcome: Equatable {
    var removedTap: Bool
    var stopped: Bool
    var revertedVoiceProcessing: Bool

    /// Every step returned inside its budget.
    var isClean: Bool { removedTap && stopped && revertedVoiceProcessing }

    /// The steps that timed out, in teardown order, for a log line and an event
    /// attribute. Empty when clean.
    var timedOutSteps: [String] {
        var steps: [String] = []
        if !removedTap { steps.append("remove_tap") }
        if !stopped { steps.append("engine_stop") }
        if !revertedVoiceProcessing { steps.append("voice_processing_revert") }
        return steps
    }
}

/// Bounded teardown of `MeetingRecorder`'s capture engine, shared by the three
/// paths that take it down: `stop()`, `recoverCapture` (device-change restart) and
/// `flushIntermediatesForTermination`.
///
/// REC13. Those three sites called `removeTap` / `engine.stop()` /
/// `setVoiceProcessingEnabled(false)` synchronously on the main thread. Each of
/// those serializes on AVAudioEngine's own queue, so when that queue wedged on
/// 2026-08-14 the stop path had no way past it and `.stopping` never completed.
/// REC11 left this deliberately: "bounding all three is REC13's, not this task's".
///
/// Every step runs off the caller's thread with its own budget and is abandoned on
/// timeout, so a wedged engine costs a bounded delay rather than the recording. The
/// steps stay in order and each one still waits for its predecessor, because the
/// order is load-bearing: the tap has to be gone before the engine stops, and voice
/// processing is reverted last so the HAL device is not left degraded for other apps
/// (a real symptom on 2026-05-13: the system mic stayed quiet until the app was
/// restarted). A step whose predecessor timed out still gets its own attempt; they
/// are separate calls into the engine and the second can succeed when the first did
/// not.
///
/// Lifted out of `MeetingRecorder` so the timeout branching is unit-testable with
/// injected closures and no wedged audio device, the way `boundedEngineStart` is.
/// The closures are `@Sendable` and take no arguments: the caller captures the
/// engine it owns (`AVAudioEngine` predates `Sendable`, hence `@preconcurrency` at
/// the recorder's import).
enum EngineTeardown {

    /// Per-step budget for the async paths (`stop()`, `recoverCapture`). A healthy
    /// `removeTap` / `stop` is sub-millisecond, so this is "how long before we give up
    /// on a wedged engine", not expected cost. Every wait there is a suspension, so
    /// spending it costs latency, not a frozen UI.
    static let defaultBudgetSeconds = 2.0

    /// Per-step budget for the termination path, tighter for the same reason
    /// `MeetingRecorder.terminationDrainTimeoutSeconds` is tighter than the graceful
    /// drain: `runSync` blocks the main thread for real, and the whole quit has to fit
    /// under the ceiling in `AppDelegate.flushAndExit` before launchd escalates to
    /// SIGKILL. Three steps at this budget is 1.5 s, which leaves the two writer drains
    /// their 3 s each inside a 9 s ceiling. `AppDelegateRelaunchTests` fences that sum.
    static let terminationBudgetSeconds = 0.5

    /// Synchronous form, for `flushIntermediatesForTermination`, which runs under
    /// `applicationWillTerminate` / the SIGTERM source and cannot suspend. Worst
    /// case blocks the caller for `3 * budgetSeconds`.
    static func runSync(
        budgetSeconds: Double = terminationBudgetSeconds,
        removeTap: @escaping @Sendable () -> Void,
        stop: @escaping @Sendable () -> Void,
        revertVoiceProcessing: (@Sendable () -> Void)?
    ) -> EngineTeardownOutcome {
        EngineTeardownOutcome(
            removedTap: runBoundedSync(seconds: budgetSeconds, removeTap),
            stopped: runBoundedSync(seconds: budgetSeconds, stop),
            revertedVoiceProcessing: revertVoiceProcessing.map {
                runBoundedSync(seconds: budgetSeconds, $0)
            } ?? true
        )
    }

    /// Asynchronous form, for the `@MainActor async` paths (`stop()` and
    /// `recoverCapture`). Every wait is a suspension, so the UI stays live for the
    /// whole budget instead of freezing on it. Each step is a blocking call, so it goes
    /// through `runBlockingWithTimeout`, never `runWithTimeout`: the `Task` form parks a
    /// wedged step on the cooperative pool, and three of them starved the deadline on
    /// the 3-core CI runner (CI8).
    static func run(
        budgetSeconds: Double = defaultBudgetSeconds,
        removeTap: @escaping @Sendable () -> Void,
        stop: @escaping @Sendable () -> Void,
        revertVoiceProcessing: (@Sendable () -> Void)?
    ) async -> EngineTeardownOutcome {
        let removedTap = await runBlockingWithTimeout(seconds: budgetSeconds, removeTap)
        let stopped = await runBlockingWithTimeout(seconds: budgetSeconds, stop)
        var reverted = true
        if let revertVoiceProcessing {
            reverted = await runBlockingWithTimeout(seconds: budgetSeconds, revertVoiceProcessing)
        }
        return EngineTeardownOutcome(
            removedTap: removedTap, stopped: stopped, revertedVoiceProcessing: reverted
        )
    }
}
