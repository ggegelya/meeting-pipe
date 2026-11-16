import XCTest
@testable import MeetingPipe
@testable import MeetingPipeCore

/// END20: the start latch's rules, without a controller.
final class RecordingStartLatchTests: XCTestCase {

    private let end = EndingReason(leadingSignal: "shareable_content_window_gone")

    func test_nothingDuringTheBringUp_commits() {
        var latch = RecordingStartLatch()
        latch.begin(origin: .idle, bundleID: "com.microsoft.teams2")
        XCTAssertTrue(latch.isInFlight)
        XCTAssertEqual(latch.resolve(), .commit)
        XCTAssertFalse(latch.isInFlight, "resolve clears the latch")
    }

    func test_anEndOfTheStartsOwnApp_isLatched_forEveryOrigin() {
        for origin in [RecordingStartLatch.Origin.prompt, .resume, .idle] {
            var latch = RecordingStartLatch()
            latch.begin(origin: origin, bundleID: "com.microsoft.teams2")
            XCTAssertEqual(latch.noteEnd(bundleID: "com.microsoft.teams2", reason: end), .latched, "\(origin)")
            XCTAssertEqual(latch.resolve(), .endedDuringStart(end), "\(origin)")
        }
    }

    func test_aForeignEnd_andAnyEndDuringASourcelessStart_areIgnored() {
        var sourced = RecordingStartLatch()
        sourced.begin(origin: .resume, bundleID: "com.microsoft.teams2")
        XCTAssertEqual(sourced.noteEnd(bundleID: "us.zoom.xos", reason: end), .ignored)
        XCTAssertEqual(sourced.resolve(), .commit)

        var sourceless = RecordingStartLatch()
        sourceless.begin(origin: .idle, bundleID: nil)
        XCTAssertEqual(sourceless.noteEnd(bundleID: "com.google.Chrome", reason: end), .ignored,
                       "a source-less start never takes a foreign end (END19's question)")
        XCTAssertEqual(sourceless.resolve(), .commit)
    }

    func test_withNoStartInFlight_endsAndStopsAreNotTheLatchs() {
        var latch = RecordingStartLatch()
        XCTAssertEqual(latch.noteEnd(bundleID: "com.microsoft.teams2", reason: end), .notInFlight)
        XCTAssertFalse(latch.cancel(by: "hotkey"))
    }

    func test_aCancelOutranksAnEnd_andTheFirstReasonOfEachIsKept() {
        var latch = RecordingStartLatch()
        latch.begin(origin: .prompt, bundleID: "com.microsoft.teams2")
        _ = latch.noteEnd(bundleID: "com.microsoft.teams2", reason: end)
        XCTAssertTrue(latch.cancel(by: "hotkey"))
        XCTAssertTrue(latch.cancel(by: "toggle"))
        XCTAssertEqual(latch.resolve(), .cancelled(by: "hotkey"))
    }

    func test_clear_dropsAFailedStart() {
        var latch = RecordingStartLatch()
        latch.begin(origin: .idle, bundleID: nil)
        _ = latch.cancel(by: "toggle")
        latch.clear()
        XCTAssertFalse(latch.isInFlight)
        XCTAssertEqual(latch.resolve(), .commit, "nothing stale reaches the next start")
    }
}
