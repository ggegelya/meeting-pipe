import XCTest
@testable import MeetingPipe

/// Tests for `runWithTimeout`, the abandon-on-timeout helper that keeps
/// `MeetingRecorder.stop()` from hanging on a stuck ScreenCaptureKit teardown.
final class RunWithTimeoutTests: XCTestCase {

    func test_returns_true_when_operation_finishes_in_time() async {
        let done = await runWithTimeout(seconds: 5) {
            try? await Task.sleep(nanoseconds: 10_000_000) // 10 ms
        }
        XCTAssertTrue(done, "a fast operation should report completion")
    }

    func test_times_out_and_returns_promptly_when_operation_hangs() async {
        let start = Date()
        let done = await runWithTimeout(seconds: 0.2) {
            try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 s "hang"
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertFalse(done, "a hung operation should report a timeout")
        XCTAssertLessThan(elapsed, 3.0, "must return at the timeout, not wait for the hung operation")
    }

    // MARK: - runBoundedSync (REC13)

    /// The synchronous sibling, for the paths that cannot suspend: `MicLevelMonitor`'s
    /// private queue and `flushIntermediatesForTermination` under SIGTERM.
    func test_boundedSync_returns_true_when_operation_finishes_in_time() {
        let ran = OSAllocatedUnfairLockBox<Bool>(false)
        let done = runBoundedSync(seconds: 5) { ran.value = true }
        XCTAssertTrue(done)
        XCTAssertTrue(ran.value)
    }

    func test_boundedSync_times_out_and_returns_promptly_when_operation_hangs() {
        let start = Date()
        let done = runBoundedSync(seconds: 0.2) { Thread.sleep(forTimeInterval: 10) }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertFalse(done, "a hung operation should report a timeout")
        XCTAssertLessThan(elapsed, 3.0, "must return at the timeout, not wait for the hung operation")
    }

    /// It runs the operation off the caller's thread. That is what makes it safe to
    /// hand a blocking `AVAudioEngine` call: the wedge lands on a global thread, not
    /// on the private queue or main thread that called in.
    func test_boundedSync_runs_the_operation_off_the_callers_thread() {
        let onMain = OSAllocatedUnfairLockBox<Bool>(true)
        _ = runBoundedSync(seconds: 5) { onMain.value = Thread.isMainThread }
        XCTAssertFalse(onMain.value)
    }

    // MARK: - runBlockingWithTimeout (CI8)

    /// The async form for a closure that BLOCKS its thread (a synchronous `AVAudioEngine`
    /// call) rather than suspending.
    func test_blocking_returns_true_when_operation_finishes_in_time() async {
        let ran = OSAllocatedUnfairLockBox<Bool>(false)
        let done = await runBlockingWithTimeout(seconds: 5) { ran.value = true }
        XCTAssertTrue(done)
        XCTAssertTrue(ran.value)
    }

    func test_blocking_times_out_and_returns_promptly_when_operation_hangs() async {
        let start = Date()
        let done = await runBlockingWithTimeout(seconds: 0.2) { Thread.sleep(forTimeInterval: 10) }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertFalse(done, "a hung operation should report a timeout")
        XCTAssertLessThan(elapsed, 3.0, "must return at the timeout, not wait for the hung operation")
    }

    func test_blocking_runs_the_operation_off_the_main_thread() async {
        let onMain = OSAllocatedUnfairLockBox<Bool>(true)
        _ = await runBlockingWithTimeout(seconds: 5) { onMain.value = Thread.isMainThread }
        XCTAssertFalse(onMain.value)
    }

    /// The property that broke CI from 2026-08 to 2026-10. Swift's cooperative pool has
    /// one thread per core and never grows, so a blocking closure run as a `Task` holds a
    /// pool thread until it returns. Once more calls have wedged than the pool has threads,
    /// the deadline that is meant to abandon the next one cannot be scheduled, and every
    /// later call waits out a whole wedge. `EngineTeardown.run`'s three wedged steps took
    /// 5.4 s against a 2.45 s bound on the 3-core runner.
    ///
    /// One more wedge than there are cores, in sequence, the way a teardown runs its steps.
    /// Each must still come back at its own budget. Deterministic on any core count, and
    /// red against the `Task` form (`runWithTimeout`) on every machine, not just a small one.
    func test_blocking_stays_bounded_when_more_calls_wedge_than_the_pool_has_threads() async {
        let budget = 0.1
        let calls = ProcessInfo.processInfo.activeProcessorCount + 1
        let start = Date()
        for _ in 0..<calls {
            let done = await runBlockingWithTimeout(seconds: budget) { Thread.sleep(forTimeInterval: 5) }
            XCTAssertFalse(done)
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(
            elapsed, budget * Double(calls) + 2.0,
            "\(calls) wedged calls must each return at their \(budget) s budget, not wait out a wedge"
        )
    }
}
