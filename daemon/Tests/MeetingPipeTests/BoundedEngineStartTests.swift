import XCTest
@testable import MeetingPipe

/// Tests for `boundedEngineStart`, the wrapper that bounds the blocking
/// `AVAudioEngine.start()` so a wedged audio device can't freeze the recorder.
/// `start()` / `recoverCapture` aren't unit testable without a real wedged
/// device, so this covers the timeout / throw / success branching directly.
final class BoundedEngineStartTests: XCTestCase {

    private struct StartError: Error, LocalizedError {
        let errorDescription: String?
    }

    func test_started_when_engine_start_returns_in_time() async {
        let outcome = await boundedEngineStart(seconds: 5) {
            // Returns immediately, like a healthy ~25 ms start.
        }
        XCTAssertEqual(outcome, .started)
    }

    func test_failed_carries_the_thrown_message() async {
        let outcome = await boundedEngineStart(seconds: 5) {
            throw StartError(errorDescription: "device unavailable")
        }
        XCTAssertEqual(outcome, .failed("device unavailable"))
    }

    func test_timed_out_and_returns_promptly_when_engine_start_wedges() async {
        let start = Date()
        let outcome = await boundedEngineStart(seconds: 0.2) {
            Thread.sleep(forTimeInterval: 10) // a wedged CoreAudio start
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertLessThan(elapsed, 3.0, "must return at the timeout, not wait for the wedged start")
    }
}
