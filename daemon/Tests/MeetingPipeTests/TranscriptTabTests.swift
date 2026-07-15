import XCTest
@testable import MeetingPipe

/// Pure-logic coverage for the transcript tab: the `<stem>.json` parser,
/// the playback-time → segment-index binary search, and the display
/// helpers. The SwiftUI view itself can't be exercised without AppKit;
/// these helpers carry the load-bearing logic so the tests cover it
/// without rendering anything.
final class TranscriptTabTests: XCTestCase {

    // MARK: parse

    func test_parse_extracts_segments_with_speakers() {
        let payload: [String: Any] = [
            "language": "en",
            "segments": [
                [
                    "start": 1.0, "end": 2.5,
                    "text": "Hello.", "speaker": "speaker_0",
                ],
                [
                    "start": 3.0, "end": 4.0,
                    "text": "Hi there!", "speaker": "speaker_1",
                ],
            ],
        ]
        let result = TranscriptLoader.parse(payload)
        XCTAssertEqual(result.language, "en")
        XCTAssertEqual(result.segments.count, 2)
        XCTAssertEqual(result.segments[0].text, "Hello.")
        XCTAssertEqual(result.segments[0].speakerID, "speaker_0")
        XCTAssertEqual(result.segments[1].speakerID, "speaker_1")
        XCTAssertEqual(result.speakerOrder, ["speaker_0", "speaker_1"])
    }

    func test_parse_skips_empty_and_malformed_segments() {
        let payload: [String: Any] = [
            "segments": [
                ["start": 1.0, "end": 2.0, "text": "   "],     // blank
                ["start": 3.0, "text": "missing end"],          // dropped
                ["start": 4.0, "end": 5.0, "text": "kept"],
            ],
        ]
        let result = TranscriptLoader.parse(payload)
        XCTAssertEqual(result.segments.count, 1)
        XCTAssertEqual(result.segments.first?.text, "kept")
    }

    func test_parse_trims_text_whitespace() {
        let payload: [String: Any] = [
            "segments": [
                ["start": 0.0, "end": 1.0, "text": "  hello world  "],
            ],
        ]
        let result = TranscriptLoader.parse(payload)
        XCTAssertEqual(result.segments.first?.text, "hello world")
    }

    func test_parse_records_speakers_in_first_seen_order() {
        let payload: [String: Any] = [
            "segments": [
                ["start": 0.0, "end": 1.0, "text": "a", "speaker": "speaker_1"],
                ["start": 1.0, "end": 2.0, "text": "b", "speaker": "speaker_0"],
                ["start": 2.0, "end": 3.0, "text": "c", "speaker": "speaker_1"],
            ],
        ]
        let result = TranscriptLoader.parse(payload)
        XCTAssertEqual(result.speakerOrder, ["speaker_1", "speaker_0"])
    }

    // MARK: index lookup

    func test_index_returns_nil_for_empty_segments() {
        XCTAssertNil(TranscriptSegmentLookup.index(at: 5.0, in: []))
    }

    func test_index_returns_nil_when_time_precedes_first_segment() {
        let segs = [seg(0, start: 10.0, end: 11.0)]
        XCTAssertNil(TranscriptSegmentLookup.index(at: 5.0, in: segs))
    }

    func test_index_finds_active_segment() {
        let segs = [
            seg(0, start: 0.0, end: 2.0),
            seg(1, start: 2.0, end: 5.0),
            seg(2, start: 5.0, end: 8.0),
        ]
        XCTAssertEqual(TranscriptSegmentLookup.index(at: 1.0, in: segs), 0)
        XCTAssertEqual(TranscriptSegmentLookup.index(at: 3.0, in: segs), 1)
        XCTAssertEqual(TranscriptSegmentLookup.index(at: 7.99, in: segs), 2)
    }

    func test_index_clings_to_last_segment_in_gaps() {
        // A 5-second silence between segments: the lookup should hold
        // on to the previously-active row instead of unhighlighting.
        let segs = [
            seg(0, start: 0.0, end: 2.0),
            seg(1, start: 10.0, end: 12.0),
        ]
        XCTAssertEqual(TranscriptSegmentLookup.index(at: 5.0, in: segs), 0)
    }

    func test_index_handles_boundary_at_segment_start() {
        let segs = [
            seg(0, start: 0.0, end: 2.0),
            seg(1, start: 2.0, end: 4.0),
        ]
        // Half-open [start, end): `2.0` lands in the second segment.
        XCTAssertEqual(TranscriptSegmentLookup.index(at: 2.0, in: segs), 1)
    }

    func test_index_scales_to_large_corpora() {
        // Mirrors the 1287-segment fixture seen in real recordings —
        // binary search should be sub-millisecond.
        let segs = (0..<2000).map { i in
            seg(i, start: Double(i), end: Double(i) + 0.9)
        }
        XCTAssertEqual(TranscriptSegmentLookup.index(at: 1234.5, in: segs), 1234)
    }

    // MARK: display helpers

    func test_displayName_normalizes_pipeline_speaker_ids() {
        XCTAssertEqual(TranscriptDisplay.displayName(for: "speaker_0"), "Speaker 1")
        XCTAssertEqual(TranscriptDisplay.displayName(for: "speaker_3"), "Speaker 4")
    }

    func test_displayName_passes_custom_labels_through() {
        XCTAssertEqual(TranscriptDisplay.displayName(for: "Heorhii"), "Heorhii")
        XCTAssertEqual(TranscriptDisplay.displayName(for: nil), "Unknown")
        XCTAssertEqual(TranscriptDisplay.displayName(for: ""), "Unknown")
    }

    func test_displayName_renders_roster_unknown_clusters() {
        XCTAssertEqual(TranscriptDisplay.displayName(for: "THEM-A"), "Unknown A")
        XCTAssertEqual(TranscriptDisplay.displayName(for: "THEM-AA"), "Unknown AA")
    }

    func test_voiceprintLabels_reads_embedding_keys() throws {
        // Only labels with a voiceprint can be enrolled; the transcript menu and
        // nameSpeaker's guard both branch on this to keep a voiceprint-less
        // `speaker_unknown` off the enroll path (which hard-failed "pipeline exited 2").
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceprintTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stem = "20260501-101500"

        // No sidecar yet -> no enrollable labels.
        XCTAssertEqual(MeetingStore.voiceprintLabels(stem: stem, in: dir), [])

        let payload: [String: Any] = ["embeddings": [
            "THEM-A": [0.1, 0.2], "Heorhii": [0.3, 0.4],
        ]]
        try JSONSerialization.data(withJSONObject: payload)
            .write(to: dir.appendingPathComponent("\(stem).embeddings.json"))
        XCTAssertEqual(MeetingStore.voiceprintLabels(stem: stem, in: dir), ["THEM-A", "Heorhii"])
        // The junk-drawer label is never a key, so it is correctly not enrollable.
        XCTAssertFalse(MeetingStore.voiceprintLabels(stem: stem, in: dir).contains("speaker_unknown"))
    }

    func test_load_threads_voiceprint_labels_from_the_sidecar() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceprintLoadTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stem = "20260501-101500"

        let transcript: [String: Any] = ["segments": [
            ["start": 0.0, "end": 1.0, "text": "hi", "speaker": "THEM-A"],
            ["start": 1.0, "end": 2.0, "text": "yo", "speaker": "speaker_unknown"],
        ]]
        try JSONSerialization.data(withJSONObject: transcript)
            .write(to: dir.appendingPathComponent("\(stem).json"))
        try JSONSerialization.data(withJSONObject: ["embeddings": ["THEM-A": [0.1]]])
            .write(to: dir.appendingPathComponent("\(stem).embeddings.json"))

        let result = try XCTUnwrap(TranscriptLoader.load(stem: stem, in: dir))
        XCTAssertEqual(result.voiceprintLabels, ["THEM-A"])
    }

    func test_timestamp_formats_short_and_long_durations() {
        XCTAssertEqual(TranscriptDisplay.timestamp(0), "0:00")
        XCTAssertEqual(TranscriptDisplay.timestamp(75), "1:15")
        XCTAssertEqual(TranscriptDisplay.timestamp(3725), "1:02:05")
    }

    // MARK: load + overlay on reload (TECH-A14)

    func test_load_overlays_a_saved_correction_on_reload() throws {
        // End-to-end through the same path TranscriptTab uses on reopen:
        // pipeline JSON on disk + a saved transcript correction -> the loaded
        // segments show the edited text. This is the "survives a reload" half
        // of the corrections acceptance against the real loader, not just the
        // store round-trip.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptTabTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stem = "20260501-101500"

        let payload: [String: Any] = [
            "language": "en",
            "segments": [
                ["start": 0.0, "end": 1.5, "text": "good morning", "speaker": "speaker_0"],
                ["start": 1.5, "end": 4.0, "text": "lets start", "speaker": "speaker_1"],
            ],
        ]
        try JSONSerialization.data(withJSONObject: payload)
            .write(to: dir.appendingPathComponent("\(stem).json"))

        // What TranscriptTab.saveCorrection persists when the user edits a line.
        _ = try TranscriptCorrectionStore.upsert(
            segmentIndex: 1,
            pipelineOriginal: "lets start",
            edited: "let's start",
            stem: stem,
            in: dir
        )

        let result = try XCTUnwrap(TranscriptLoader.load(stem: stem, in: dir))
        XCTAssertEqual(result.segments[0].text, "good morning", "untouched segment unchanged")
        XCTAssertEqual(result.segments[1].text, "let's start", "edited segment overlaid on reload")
    }

    // MARK: helpers

    private func seg(_ index: Int, start: TimeInterval, end: TimeInterval) -> TranscriptSegment {
        TranscriptSegment(
            index: index, start: start, end: end,
            text: "x", speakerID: nil
        )
    }
}
