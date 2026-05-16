import XCTest
@testable import MeetingPipeCore

final class EventLogTests: XCTestCase {

    func test_noop_event_log_drops_silently() {
        let log = NoopEventLog()
        log.emit(category: "lifecycle", action: "starting", attributes: ["bundle_id": "us.zoom.xos"])
    }

    func test_recording_event_log_captures_entries_in_order() {
        let log = RecordingEventLog()
        log.emit(category: "lifecycle", action: "starting", attributes: ["bundle_id": "us.zoom.xos"])
        log.emit(category: "lifecycle", action: "in_meeting", attributes: ["bundle_id": "us.zoom.xos"])

        let entries = log.entries
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].category, "lifecycle")
        XCTAssertEqual(entries[0].action, "starting")
        XCTAssertEqual(entries[0].attributes["bundle_id"], "us.zoom.xos")
        XCTAssertEqual(entries[1].action, "in_meeting")
    }

    func test_recording_event_log_clear_resets_buffer() {
        let log = RecordingEventLog()
        log.emit(category: "lifecycle", action: "idle", attributes: [:])
        log.clear()
        XCTAssertEqual(log.entries.count, 0)
    }
}
