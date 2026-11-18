import XCTest
@testable import MeetingPipe

/// PIPE34: `<stem>.publish.json` holding the `unknown` marker (written before any sink runs, left
/// when the final write failed) is read as an unrecorded outcome everywhere, never as the previous
/// run's and never as settled.
final class PublishUnknownPIPE34Tests: XCTestCase {

    func test_unknown_wins_over_a_run_sidecar_that_says_full() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mp-pipe34-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"schema_version": 1, "state": "unknown", "page_url": null, "ts": "2026-11-18T10:00:00+00:00", "sinks": {}}"#.utf8)
            .write(to: dir.appendingPathComponent("m.publish.json"))

        let publish = try XCTUnwrap(PublishResult.load(stem: "m", in: dir))
        XCTAssertEqual(PublishResult.resolveState(publish: publish, runPublishState: "full"), "unknown")
        XCTAssertNil(publish.pageURL)
        XCTAssertEqual(PublishLanding.decide(publish: publish, pageURL: publish.pageURL), .nowhere,
                       "the done banner names no destination")
    }

    func test_unknown_is_not_settled_so_retention_waits() {
        XCTAssertFalse(AudioRetention.isSettled(status: .done, publishState: PublishResult.unknownState))
    }

    func test_unknown_is_badged_like_unpublished() {
        let badge = DonePublishBadge.decide(publishState: "unknown")
        XCTAssertEqual(badge.kind, DonePublishBadge.decide(publishState: "none").kind)
        XCTAssertEqual(badge.label, "Unpublished")
        XCTAssertTrue(badge.help?.contains("Publish outcome unknown") == true)
    }
}
