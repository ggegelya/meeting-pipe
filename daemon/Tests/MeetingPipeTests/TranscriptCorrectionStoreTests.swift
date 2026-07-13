import XCTest
@testable import MeetingPipe

/// Round-trip + overlay tests for `TranscriptCorrectionStore`. Covers:
///   - The overlay is a pure no-op when no corrections exist.
///   - An edit replaces the segment text without touching start/end/
///     speaker.
///   - Re-editing preserves the pipeline-original snapshot across
///     multiple round-trips (so a sequence of edits doesn't lose the
///     pipeline truth).
///   - Saving an edit equal to the resolved original removes the
///     sidecar entirely so the next load behaves as if no override
///     was ever made.
///   - A missing or malformed sidecar yields an empty correction
///     dict instead of throwing.
final class TranscriptCorrectionStoreTests: XCTestCase {

    private var dir: URL!
    private let stem = "20260501-101500"

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "TranscriptCorrectionStoreTests-\(UUID())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
        dir = nil
        try super.tearDownWithError()
    }

    // MARK: - apply (pure)

    func test_apply_with_no_corrections_returns_segments_unchanged() {
        let segs = [segment(0, "hello"), segment(1, "world")]
        let out = TranscriptCorrectionStore.apply(corrections: [:], to: segs)
        XCTAssertEqual(out.map { $0.text }, ["hello", "world"])
    }

    func test_apply_replaces_text_for_matching_index_only() {
        let segs = [segment(0, "hello"), segment(1, "world")]
        let corrections: [Int: TranscriptCorrectionStore.Correction] = [
            1: .init(segmentIndex: 1, originalText: "world", editedText: "WORLD!"),
        ]
        let out = TranscriptCorrectionStore.apply(corrections: corrections, to: segs)
        XCTAssertEqual(out[0].text, "hello", "unedited segments pass through")
        XCTAssertEqual(out[1].text, "WORLD!")
        XCTAssertEqual(out[1].start, segs[1].start)
        XCTAssertEqual(out[1].end, segs[1].end)
        XCTAssertEqual(out[1].speakerID, segs[1].speakerID)
    }

    // MARK: - upsert + read round-trip

    func test_upsert_then_read_returns_the_correction() throws {
        _ = try TranscriptCorrectionStore.upsert(
            segmentIndex: 2,
            pipelineOriginal: "hellp world",
            edited: "hello world",
            stem: stem,
            in: dir
        )
        let dict = TranscriptCorrectionStore.read(stem: stem, in: dir)
        XCTAssertEqual(dict[2]?.originalText, "hellp world")
        XCTAssertEqual(dict[2]?.editedText, "hello world")
    }

    func test_re_editing_preserves_the_original_pipeline_text() throws {
        // First edit: pipeline says "hellp", user types "hello".
        _ = try TranscriptCorrectionStore.upsert(
            segmentIndex: 0,
            pipelineOriginal: "hellp",
            edited: "hello",
            stem: stem,
            in: dir
        )
        // Second edit comes from the overlaid value ("hello") not the
        // pipeline truth. The store has to remember the real original.
        _ = try TranscriptCorrectionStore.upsert(
            segmentIndex: 0,
            pipelineOriginal: "hello",
            edited: "hello!",
            stem: stem,
            in: dir
        )
        let dict = TranscriptCorrectionStore.read(stem: stem, in: dir)
        XCTAssertEqual(dict[0]?.originalText, "hellp",
                       "the pipeline-original snapshot must survive re-edits")
        XCTAssertEqual(dict[0]?.editedText, "hello!")
    }

    func test_reverting_to_original_removes_the_correction() throws {
        _ = try TranscriptCorrectionStore.upsert(
            segmentIndex: 5,
            pipelineOriginal: "first cut",
            edited: "final cut",
            stem: stem,
            in: dir
        )
        XCTAssertNotNil(TranscriptCorrectionStore.read(stem: stem, in: dir)[5])

        // User edits back to the pipeline text. From the UI's point of
        // view the input is the overlay ("final cut"); the store has
        // to resolve via the saved original.
        _ = try TranscriptCorrectionStore.upsert(
            segmentIndex: 5,
            pipelineOriginal: "final cut",
            edited: "first cut",
            stem: stem,
            in: dir
        )
        XCTAssertNil(TranscriptCorrectionStore.read(stem: stem, in: dir)[5])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: TranscriptCorrectionStore.path(stem: stem, in: dir).path),
            "sidecar should be removed when no overrides remain")
    }

    func test_multiple_segments_round_trip_independently() throws {
        _ = try TranscriptCorrectionStore.upsert(
            segmentIndex: 0, pipelineOriginal: "a", edited: "A", stem: stem, in: dir)
        _ = try TranscriptCorrectionStore.upsert(
            segmentIndex: 3, pipelineOriginal: "c", edited: "C", stem: stem, in: dir)
        _ = try TranscriptCorrectionStore.upsert(
            segmentIndex: 1, pipelineOriginal: "b", edited: "B", stem: stem, in: dir)
        let dict = TranscriptCorrectionStore.read(stem: stem, in: dir)
        XCTAssertEqual(dict.count, 3)
        XCTAssertEqual(dict[0]?.editedText, "A")
        XCTAssertEqual(dict[1]?.editedText, "B")
        XCTAssertEqual(dict[3]?.editedText, "C")
    }

    // MARK: - Failure modes

    func test_missing_sidecar_reads_as_empty() {
        let dict = TranscriptCorrectionStore.read(stem: "nope", in: dir)
        XCTAssertTrue(dict.isEmpty)
    }

    func test_malformed_sidecar_reads_as_empty() throws {
        let url = TranscriptCorrectionStore.path(stem: stem, in: dir)
        try Data("not json".utf8).write(to: url)
        let dict = TranscriptCorrectionStore.read(stem: stem, in: dir)
        XCTAssertTrue(dict.isEmpty)
    }

    // MARK: - Acceptance flow

    func test_acceptance_edit_close_reopen_persists() throws {
        // Source-of-truth segments as if just parsed from the pipeline JSON.
        let pipelineSegments = [
            segment(0, "good morning"),
            segment(1, "let's start with the agenda"),
        ]
        // First "session": user edits segment 1.
        _ = try TranscriptCorrectionStore.upsert(
            segmentIndex: 1,
            pipelineOriginal: pipelineSegments[1].text,
            edited: "let's start with the agenda.",
            stem: stem,
            in: dir
        )
        // Second "session": reload from disk and apply.
        let storedCorrections = TranscriptCorrectionStore.read(stem: stem, in: dir)
        let displayed = TranscriptCorrectionStore.apply(
            corrections: storedCorrections,
            to: pipelineSegments
        )
        XCTAssertEqual(displayed[0].text, "good morning")
        XCTAssertEqual(displayed[1].text, "let's start with the agenda.")
    }

    // MARK: - Schema version (PIPE9)

    func test_write_stamps_schema_version() throws {
        _ = try TranscriptCorrectionStore.upsert(
            segmentIndex: 0, pipelineOriginal: "a", edited: "A", stem: stem, in: dir)
        let url = TranscriptCorrectionStore.path(stem: stem, in: dir)
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(obj?["schema_version"] as? Int, TranscriptCorrectionStore.schemaVersion)
    }

    // MARK: - Cross-language parity (PIPE9)

    /// The Swift-to-Python contract: the same golden fixture Python's
    /// `test_transcript_corrections.py` reads is applied here, so a change to
    /// either resolver breaks the other tree's test.
    func test_golden_parity_with_python() throws {
        let fixture = try XCTUnwrap(
            Bundle.module.url(forResource: "transcript-corrections-golden", withExtension: "json"),
            "missing transcript-corrections golden fixture")
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any]
        let cases = try XCTUnwrap(root?["cases"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty, "golden fixture has no cases")

        for c in cases {
            let name = (c["name"] as? String) ?? "?"
            let rawSegments = try XCTUnwrap(c["segments"] as? [[String: Any]], "\(name): segments")
            let corrections = try XCTUnwrap(c["corrections"] as? [String: Any], "\(name): corrections")
            let expected = try XCTUnwrap(c["expected"] as? [String], "\(name): expected")

            // Write the correction payload exactly as the daemon would, read it back.
            let caseStem = "golden-\(name)"
            let sidecar = TranscriptCorrectionStore.path(stem: caseStem, in: dir)
            try JSONSerialization.data(withJSONObject: corrections).write(to: sidecar)
            let dict = TranscriptCorrectionStore.read(stem: caseStem, in: dir)

            let segs = rawSegments.enumerated().map { i, raw in
                segment(i, (raw["text"] as? String) ?? "")
            }
            let out = TranscriptCorrectionStore.apply(corrections: dict, to: segs)
            XCTAssertEqual(out.map { $0.text }, expected, "golden case \(name)")
        }
    }

    // MARK: helpers

    private func segment(_ index: Int, _ text: String) -> TranscriptSegment {
        TranscriptSegment(
            index: index,
            start: TimeInterval(index) * 2.0,
            end: TimeInterval(index) * 2.0 + 1.5,
            text: text,
            speakerID: "speaker_0"
        )
    }
}
