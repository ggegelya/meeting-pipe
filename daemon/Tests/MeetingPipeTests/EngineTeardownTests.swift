import XCTest
@testable import MeetingPipe

/// REC13(2)+(3): a wedged AVAudioEngine must not strand the stop path or the
/// termination flush. Every engine call those two paths make now goes through
/// `EngineTeardown`, which is closure-injected precisely so the timeout branching is
/// pinned here rather than needing a real contended audio device.
final class EngineTeardownTests: XCTestCase {

    /// A budget short enough to keep the suite fast; the production default is 2 s.
    private let budget = 0.15

    /// Blocks its thread for longer than any budget in these tests, standing in for a
    /// call that serializes on a wedged engine queue. Bounded rather than infinite so a
    /// failing assertion cannot leak a thread for the rest of the run.
    private func wedged() -> @Sendable () -> Void {
        { Thread.sleep(forTimeInterval: 5) }
    }

    // MARK: - Synchronous form (the termination flush)

    func test_runSync_reports_clean_when_every_step_returns() {
        let outcome = EngineTeardown.runSync(
            budgetSeconds: budget,
            removeTap: {}, stop: {}, revertVoiceProcessing: {}
        )
        XCTAssertTrue(outcome.isClean)
        XCTAssertEqual(outcome.timedOutSteps, [])
    }

    /// The termination flush runs to completion under a wedged engine: `runSync`
    /// returns, in bounded time, and says which steps it abandoned. Before REC13 these
    /// three calls were unbounded on the main thread, so this path could not come back
    /// at all and the only escape was `kill -9`.
    func test_runSync_returns_bounded_when_every_step_wedges() {
        let started = Date()
        let outcome = EngineTeardown.runSync(
            budgetSeconds: budget,
            removeTap: wedged(), stop: wedged(), revertVoiceProcessing: wedged()
        )
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertFalse(outcome.isClean)
        XCTAssertEqual(outcome.timedOutSteps, ["remove_tap", "engine_stop", "voice_processing_revert"])
        // Three sequential steps, each bounded by its own budget, plus scheduling slack.
        XCTAssertLessThan(elapsed, budget * 3 + 2.0)
    }

    /// A step whose predecessor timed out still gets its own attempt: they are separate
    /// calls into the engine and the later one can succeed when the earlier did not.
    func test_runSync_still_attempts_later_steps_after_a_timeout() {
        let stopRan = OSAllocatedUnfairLockBox<Bool>(false)
        let revertRan = OSAllocatedUnfairLockBox<Bool>(false)
        let outcome = EngineTeardown.runSync(
            budgetSeconds: budget,
            removeTap: wedged(),
            stop: { stopRan.value = true },
            revertVoiceProcessing: { revertRan.value = true }
        )
        XCTAssertFalse(outcome.removedTap)
        XCTAssertTrue(outcome.stopped)
        XCTAssertTrue(outcome.revertedVoiceProcessing)
        XCTAssertTrue(stopRan.value)
        XCTAssertTrue(revertRan.value)
        XCTAssertEqual(outcome.timedOutSteps, ["remove_tap"])
    }

    /// VoiceProcessing was never enabled for this session, so there is nothing to
    /// revert and the absent step counts as done rather than as a timeout.
    func test_runSync_treats_a_nil_voice_processing_step_as_done() {
        let outcome = EngineTeardown.runSync(
            budgetSeconds: budget,
            removeTap: {}, stop: {}, revertVoiceProcessing: nil
        )
        XCTAssertTrue(outcome.isClean)
    }

    // MARK: - Asynchronous form (stop() and recoverCapture)

    func test_run_reports_clean_when_every_step_returns() async {
        let outcome = await EngineTeardown.run(
            budgetSeconds: budget,
            removeTap: {}, stop: {}, revertVoiceProcessing: {}
        )
        XCTAssertTrue(outcome.isClean)
    }

    /// `stop()` completes even when every engine call it makes times out, which is the
    /// property that keeps a wedged engine from stranding the state machine in
    /// `.stopping`. The teardown returning is what lets `stop()` go on to finalize the
    /// intermediates and return to the controller, which then reaches `.idle`.
    func test_run_returns_bounded_when_every_step_wedges() async {
        let started = Date()
        let outcome = await EngineTeardown.run(
            budgetSeconds: budget,
            removeTap: wedged(), stop: wedged(), revertVoiceProcessing: wedged()
        )
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertFalse(outcome.isClean)
        XCTAssertEqual(outcome.timedOutSteps, ["remove_tap", "engine_stop", "voice_processing_revert"])
        XCTAssertLessThan(elapsed, budget * 3 + 2.0)
    }

    /// Order is load-bearing: the tap comes off before the engine stops, and voice
    /// processing is reverted last so the HAL device is not left degraded for other
    /// apps. Pinned so a later refactor cannot quietly reorder them.
    func test_run_keeps_the_steps_in_order() async {
        let order = OSAllocatedUnfairLockBox<[String]>([])
        _ = await EngineTeardown.run(
            budgetSeconds: budget,
            removeTap: { order.value = order.value + ["remove_tap"] },
            stop: { order.value = order.value + ["engine_stop"] },
            revertVoiceProcessing: { order.value = order.value + ["voice_processing_revert"] }
        )
        XCTAssertEqual(order.value, ["remove_tap", "engine_stop", "voice_processing_revert"])
    }
}
