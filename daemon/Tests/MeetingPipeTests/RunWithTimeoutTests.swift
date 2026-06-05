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
}
