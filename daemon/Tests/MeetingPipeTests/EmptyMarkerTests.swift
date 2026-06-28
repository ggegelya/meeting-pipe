import XCTest
@testable import MeetingPipe

/// `EmptyMarker` / `EmptyReason` back the terminal "finished with no summary"
/// states (PIPE3). The read path must tolerate every malformed input and a
/// pre-reason marker, and the reason wording is the single source of truth the
/// Library row, detail pane, and notification all read.
final class EmptyMarkerTests: XCTestCase {

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mp-emptymarker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func test_reason_init_is_tolerant() {
        XCTAssertEqual(EmptyReason(marker: "no_speech"), .noSpeech)
        XCTAssertEqual(EmptyReason(marker: "suspect_transcript"), .suspectTranscript)
        XCTAssertEqual(EmptyReason(marker: nil), .noSpeech, "absent reason falls back to no-speech")
        XCTAssertEqual(EmptyReason(marker: "future_reason"), .noSpeech, "unknown reason falls back")
    }

    func test_wording_is_distinct_and_nonempty() {
        XCTAssertNotEqual(EmptyReason.noSpeech.pillLabel, EmptyReason.suspectTranscript.pillLabel)
        for reason in [EmptyReason.noSpeech, .suspectTranscript] {
            XCTAssertFalse(reason.pillLabel.isEmpty)
            XCTAssertFalse(reason.detail.isEmpty)
            XCTAssertFalse(reason.notificationTitle.isEmpty)
            XCTAssertFalse(reason.notificationBody.isEmpty)
        }
    }

    func test_read_parses_reason() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stem = "20260511-143110"
        let url = EmptyMarker.url(forStem: stem, in: dir)
        try Data(#"{"stem":"20260511-143110","reason":"suspect_transcript"}"#.utf8).write(to: url)
        XCTAssertEqual(EmptyMarker.read(at: url), .suspectTranscript)
        XCTAssertEqual(EmptyMarker.read(stem: stem, in: dir), .suspectTranscript)
    }

    func test_read_of_present_marker_without_reason_is_noSpeech() throws {
        // A legacy / minimal marker with no reason key reads as no-speech.
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = EmptyMarker.url(forStem: "x", in: dir)
        try Data("{}".utf8).write(to: url)
        XCTAssertEqual(EmptyMarker.read(at: url), .noSpeech)
    }

    func test_read_of_missing_or_corrupt_returns_nil() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(EmptyMarker.read(stem: "nope", in: dir), "missing file")
        let bad = EmptyMarker.url(forStem: "x", in: dir)
        try Data("{not json".utf8).write(to: bad)
        XCTAssertNil(EmptyMarker.read(at: bad), "corrupt JSON")
    }
}
