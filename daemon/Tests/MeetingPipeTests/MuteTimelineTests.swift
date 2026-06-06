import XCTest
@testable import MeetingPipe

final class MuteTimelineTests: XCTestCase {

    func test_no_muted_buffers_yields_no_spans() {
        var timeline = MuteTimeline()
        timeline.add(startSec: 0.0, endSec: 0.1, muted: false)
        timeline.add(startSec: 0.1, endSec: 0.2, muted: false)
        timeline.finalize()
        XCTAssertEqual(timeline.spans, [])
    }

    func test_contiguous_muted_buffers_coalesce_into_one_span() {
        var timeline = MuteTimeline()
        timeline.add(startSec: 0.0, endSec: 0.1, muted: false)
        timeline.add(startSec: 0.1, endSec: 0.2, muted: true)
        timeline.add(startSec: 0.2, endSec: 0.3, muted: true)
        timeline.add(startSec: 0.3, endSec: 0.4, muted: false)
        timeline.finalize()
        XCTAssertEqual(timeline.spans, [MuteTimeline.Span(startSec: 0.1, endSec: 0.3)])
    }

    func test_two_separate_mute_spans_are_kept_distinct() {
        var timeline = MuteTimeline()
        timeline.add(startSec: 0.0, endSec: 0.1, muted: true)
        timeline.add(startSec: 0.1, endSec: 0.2, muted: false)
        timeline.add(startSec: 0.2, endSec: 0.3, muted: true)
        timeline.finalize()
        XCTAssertEqual(timeline.spans, [
            MuteTimeline.Span(startSec: 0.0, endSec: 0.1),
            MuteTimeline.Span(startSec: 0.2, endSec: 0.3),
        ])
    }

    func test_a_span_open_at_stop_is_closed_by_finalize() {
        var timeline = MuteTimeline()
        timeline.add(startSec: 1.0, endSec: 1.5, muted: true)
        // Recording stops while still muted; finalize closes the span.
        timeline.finalize()
        XCTAssertEqual(timeline.spans, [MuteTimeline.Span(startSec: 1.0, endSec: 1.5)])
    }

    func test_zero_length_buffers_are_ignored() {
        var timeline = MuteTimeline()
        timeline.add(startSec: 0.5, endSec: 0.5, muted: true)
        timeline.finalize()
        XCTAssertEqual(timeline.spans, [])
    }

    // MARK: - sidecar contract (TECH-MIC4 writes, TECH-MIC5 reads)

    func test_sidecar_url_is_stem_dot_mute_timeline_json() {
        let final = URL(fileURLWithPath: "/tmp/Meetings/raw/20260607-120000.wav")
        XCTAssertEqual(
            MuteTimelineFile.url(forFinal: final).lastPathComponent,
            "20260607-120000.mute-timeline.json"
        )
    }

    func test_sidecar_round_trips_spans_through_disk() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mute-timeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let final = dir.appendingPathComponent("rec.wav")

        let spans = [
            MuteTimeline.Span(startSec: 1.25, endSec: 3.5),
            MuteTimeline.Span(startSec: 10.0, endSec: 12.75),
        ]
        MuteTimelineFile.write(spans: spans, forFinal: final)

        guard let read = MuteTimelineFile.read(forFinal: final) else {
            return XCTFail("read returned nil")
        }
        XCTAssertEqual(read.spans, spans)
    }

    func test_sidecar_uses_snake_case_keys() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mute-timeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let final = dir.appendingPathComponent("rec.wav")

        MuteTimelineFile.write(spans: [MuteTimeline.Span(startSec: 1.0, endSec: 2.0)], forFinal: final)
        let json = try String(contentsOf: MuteTimelineFile.url(forFinal: final), encoding: .utf8)
        XCTAssertTrue(json.contains("start_sec"))
        XCTAssertTrue(json.contains("end_sec"))
    }

    func test_read_returns_nil_when_no_timeline_exists() {
        let final = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).wav")
        XCTAssertNil(MuteTimelineFile.read(forFinal: final))
    }
}
