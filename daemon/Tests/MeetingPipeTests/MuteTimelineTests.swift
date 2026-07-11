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

    // MARK: - MIC14: span source (mute | manual)

    func test_a_manual_span_abutting_an_auto_span_does_not_coalesce() {
        var timeline = MuteTimeline()
        timeline.add(startSec: 0.0, endSec: 0.1, muted: true, source: .mute)
        // Contiguous, but a different source: the two must stay distinct, not merge.
        timeline.add(startSec: 0.1, endSec: 0.2, muted: true, source: .manual)
        timeline.add(startSec: 0.2, endSec: 0.3, muted: true, source: .manual)  // this one coalesces
        timeline.finalize()
        XCTAssertEqual(timeline.spans, [
            MuteTimeline.Span(startSec: 0.0, endSec: 0.1, source: .mute),
            MuteTimeline.Span(startSec: 0.1, endSec: 0.3, source: .manual),
        ])
    }

    func test_hasManualSpan_tracks_the_open_and_closed_manual_span() {
        var timeline = MuteTimeline()
        timeline.add(startSec: 0.0, endSec: 0.1, muted: true, source: .mute)
        XCTAssertFalse(timeline.hasManualSpan, "an auto span is not a manual span")
        timeline.add(startSec: 0.1, endSec: 0.2, muted: true, source: .manual)
        XCTAssertTrue(timeline.hasManualSpan, "the open manual span counts")
        timeline.finalize()
        XCTAssertTrue(timeline.hasManualSpan, "the closed manual span still counts")
    }

    func test_source_round_trips_through_disk() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mute-timeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let final = dir.appendingPathComponent("rec.wav")

        let spans = [
            MuteTimeline.Span(startSec: 1.0, endSec: 2.0, source: .mute),
            MuteTimeline.Span(startSec: 3.0, endSec: 4.0, source: .manual),
        ]
        MuteTimelineFile.write(spans: spans, forFinal: final)

        let read = try XCTUnwrap(MuteTimelineFile.read(forFinal: final))
        XCTAssertEqual(read.version, 2)
        XCTAssertEqual(read.spans, spans)
        XCTAssertEqual(read.spans.map(\.source), [.mute, .manual])

        let json = try String(contentsOf: MuteTimelineFile.url(forFinal: final), encoding: .utf8)
        XCTAssertTrue(json.contains("\"source\""))
        XCTAssertTrue(json.contains("manual"))
    }

    func test_a_v1_file_without_source_decodes_as_mute() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mute-timeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let final = dir.appendingPathComponent("rec.wav")

        // A pre-MIC14 file: version 1, spans with no `source` key.
        let v1 = "{\"version\":1,\"spans\":[{\"start_sec\":1.0,\"end_sec\":2.0}]}"
        try v1.write(to: MuteTimelineFile.url(forFinal: final), atomically: true, encoding: .utf8)

        let read = try XCTUnwrap(MuteTimelineFile.read(forFinal: final))
        XCTAssertEqual(read.spans.first?.source, .mute, "an absent source is the auto mute kind")
    }

    func test_off_record_marker_round_trips() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("offrecord-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let final = dir.appendingPathComponent("rec.wav")

        XCTAssertFalse(OffRecordMarker.exists(forFinal: final))
        OffRecordMarker.write(forFinal: final)
        XCTAssertTrue(OffRecordMarker.exists(forFinal: final))
        XCTAssertEqual(OffRecordMarker.url(forFinal: final).lastPathComponent, "rec.offrecord")
        OffRecordMarker.remove(forFinal: final)
        XCTAssertFalse(OffRecordMarker.exists(forFinal: final))
    }
}
