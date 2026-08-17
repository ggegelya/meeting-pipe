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
}
