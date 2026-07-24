import XCTest
@testable import MeetingPipe

/// FEAT10: evidence anchors on the daemon side.
///
/// Three things have to hold. The field decodes and, critically, *survives* the
/// two write paths that rewrite `<stem>.summary.json` in place (a mark-done and a
/// correction save), because `jsonObject()` re-serializes only what the struct
/// models and an unmodeled field is deleted rather than preserved. The
/// corrections editor re-aligns anchors instead of leaving them pointing at text
/// that changed. And the chip presentation resolves to a real transcript row.
final class EvidenceTests: XCTestCase {

    /// A summary carrying anchors in both shapes: inline on an action, and in the
    /// index-aligned map for the string sections.
    private let evidenceJSON = """
    {
      "title": "Export sync",
      "summary": ["Agreed the export ships Friday.", "SOP revision is in flight."],
      "decisions": ["Ship the export on Friday."],
      "actions": [
        {"task": "Send revised SOP to QA", "owner": "Alice", "due": null, "confidence": "high",
         "evidence": [{"quote": "send the revised SOP to QA", "t": 40.0}]},
        {"task": "Book the room", "owner": null, "due": null, "confidence": "low", "evidence": []}
      ],
      "questions": ["Is the QMS export green?"],
      "attendees": ["Alice", "Bob"],
      "detected_language": "en",
      "evidence": {
        "summary": [[{"quote": "We will ship the export on Friday", "t": 12.0}], []],
        "decisions": [[{"quote": "ship the export on Friday", "t": 12.0}]],
        "questions": [[{"quote": "Is the QMS export green yet", "t": 754.0}]]
      }
    }
    """

    private func decode(_ json: String) throws -> MeetingSummary {
        try JSONDecoder().decode(MeetingSummary.self, from: Data(json.utf8))
    }

    // MARK: - Decode

    func test_decodes_anchors_for_every_section() throws {
        let s = try decode(evidenceJSON)
        XCTAssertEqual(s.evidence(section: "summary", at: 0).first?.t, 12.0)
        XCTAssertEqual(s.evidence(section: "summary", at: 0).first?.quote,
                       "We will ship the export on Friday")
        XCTAssertEqual(s.evidence(section: "summary", at: 1), [])
        XCTAssertEqual(s.evidence(section: "decisions", at: 0).first?.t, 12.0)
        XCTAssertEqual(s.evidence(section: "questions", at: 0).first?.t, 754.0)
        XCTAssertEqual(s.actions[0].evidence.first?.quote, "send the revised SOP to QA")
        XCTAssertEqual(s.actions[1].evidence, [])
        XCTAssertTrue(s.hasEvidence)
    }

    func test_legacy_summary_without_evidence_decodes_empty() throws {
        let s = try decode("""
        {"title": "t", "summary": ["a"], "decisions": [], "actions": [
          {"task": "x", "owner": null, "due": null, "confidence": "low"}],
         "questions": [], "attendees": [], "detected_language": "en"}
        """)
        XCTAssertEqual(s.evidence, [:])
        XCTAssertEqual(s.actions[0].evidence, [])
        XCTAssertFalse(s.hasEvidence)
    }

    func test_wrong_typed_evidence_falls_back_to_empty() throws {
        // Tolerant decode: a malformed field costs its own value, never the parse.
        let s = try decode("""
        {"title": "t", "summary": ["a"], "evidence": "nonsense",
         "actions": [{"task": "x", "evidence": 7}]}
        """)
        XCTAssertEqual(s.evidence, [:])
        XCTAssertEqual(s.actions[0].evidence, [])
    }

    func test_out_of_range_index_returns_no_anchors() throws {
        // A hand-edited file can carry a shorter anchor list than its section.
        let s = try decode(evidenceJSON)
        XCTAssertEqual(s.evidence(section: "decisions", at: 5), [])
        XCTAssertEqual(s.evidence(section: "nope", at: 0), [])
    }

    // MARK: - The write bridge (the hazard FEAT10 names)

    func test_evidence_survives_the_write_bridge() throws {
        let s = try decode(evidenceJSON)
        let round = try XCTUnwrap(MeetingSummary(jsonObject: s.jsonObject()))
        XCTAssertEqual(round.evidence, s.evidence)
        XCTAssertEqual(round.actions.map(\.evidence), s.actions.map(\.evidence))
        XCTAssertEqual(round, s)
    }

    func test_mark_done_preserves_evidence() throws {
        // The FactsView mark-done path: load, flip resolved, write jsonObject().
        // Before FEAT10 modeled the field this silently deleted every anchor.
        var s = try decode(evidenceJSON)
        s.actions[0].resolved = true
        let round = try XCTUnwrap(MeetingSummary(jsonObject: s.jsonObject()))
        XCTAssertTrue(round.actions[0].resolved)
        XCTAssertEqual(round.actions[0].evidence.first?.t, 40.0)
        XCTAssertEqual(round.evidence(section: "summary", at: 0).first?.t, 12.0)
    }

    func test_write_bridge_omits_empty_sections() throws {
        // An uncited summary writes an empty map, not three empty lists, so a
        // pre-FEAT10 file that gets marked done does not sprout hollow sections.
        let s = try decode("""
        {"title": "t", "summary": ["a"], "attendees": [], "detected_language": "en"}
        """)
        let evidence = try XCTUnwrap(s.jsonObject()["evidence"] as? [String: Any])
        XCTAssertTrue(evidence.isEmpty)
    }

    // MARK: - Correction save remap

    func test_untouched_lines_keep_their_anchors() {
        let carried = MeetingSummary.carryEvidence(
            original: ["one", "two", "three"],
            anchors: [[.init(quote: "a", t: 1)], [.init(quote: "b", t: 2)], [.init(quote: "c", t: 3)]],
            edited: ["one", "two", "three"]
        )
        XCTAssertEqual(carried.map { $0.first?.t }, [1, 2, 3])
    }

    func test_edited_line_drops_its_anchors() {
        let carried = MeetingSummary.carryEvidence(
            original: ["one", "two"],
            anchors: [[.init(quote: "a", t: 1)], [.init(quote: "b", t: 2)]],
            edited: ["one", "two, revised"]
        )
        XCTAssertEqual(carried[0].first?.t, 1)
        XCTAssertEqual(carried[1], [], "a rewritten line's quote no longer supports it")
    }

    func test_deleting_a_line_realigns_the_rest() {
        let carried = MeetingSummary.carryEvidence(
            original: ["one", "two", "three"],
            anchors: [[.init(quote: "a", t: 1)], [.init(quote: "b", t: 2)], [.init(quote: "c", t: 3)]],
            edited: ["one", "three"]
        )
        XCTAssertEqual(carried.map { $0.first?.t }, [1, 3])
    }

    func test_inserted_line_starts_uncited_and_does_not_shift_others() {
        let carried = MeetingSummary.carryEvidence(
            original: ["one", "two"],
            anchors: [[.init(quote: "a", t: 1)], [.init(quote: "b", t: 2)]],
            edited: ["brand new", "one", "two"]
        )
        XCTAssertEqual(carried[0], [])
        XCTAssertEqual(carried[1].first?.t, 1)
        XCTAssertEqual(carried[2].first?.t, 2)
    }

    func test_duplicate_lines_do_not_both_claim_one_anchor_set() {
        let carried = MeetingSummary.carryEvidence(
            original: ["same"],
            anchors: [[.init(quote: "a", t: 1)]],
            edited: ["same", "same"]
        )
        XCTAssertEqual(carried[0].first?.t, 1)
        XCTAssertEqual(carried[1], [])
    }

    func test_correction_save_remaps_all_sections_and_actions() throws {
        let original = try decode(evidenceJSON)
        let model = CorrectionViewModel(
            stem: "20260722-1000",
            recordingsDir: URL(fileURLWithPath: "/tmp"),
            runMeta: [:],
            originalSummary: original
        )
        // Touch one bullet, leave the decision and question alone, rewrite one
        // action's task and only the owner of the other.
        model.summary[0] = "Agreed the export ships Monday."
        model.actions[0].task = "Send the revised SOP to Quality"
        model.actions[1].owner = "Bob"

        let corrected = model.makeCorrectedSummary()
        XCTAssertEqual(corrected.evidence(section: "summary", at: 0), [],
                       "the edited bullet drops its anchor")
        XCTAssertEqual(corrected.evidence(section: "decisions", at: 0).first?.t, 12.0)
        XCTAssertEqual(corrected.evidence(section: "questions", at: 0).first?.t, 754.0)
        XCTAssertEqual(corrected.actions[0].evidence, [],
                       "the rewritten task drops its anchor")
        XCTAssertEqual(corrected.actions[1].evidence, [])
    }

    func test_correction_save_keeps_anchors_when_only_metadata_changes() throws {
        let original = try decode(evidenceJSON)
        let model = CorrectionViewModel(
            stem: "s", recordingsDir: URL(fileURLWithPath: "/tmp"),
            runMeta: [:], originalSummary: original
        )
        model.actions[0].due = "2026-08-01"
        model.actions[0].confidence = "medium"

        let corrected = model.makeCorrectedSummary()
        XCTAssertEqual(corrected.actions[0].evidence.first?.t, 40.0,
                       "changing a due date is not a text edit")
        XCTAssertEqual(corrected.evidence(section: "summary", at: 0).first?.t, 12.0)
    }

    func test_evidence_free_summary_stays_evidence_free_through_an_edit() throws {
        let original = try decode("""
        {"title": "t", "summary": ["a"], "attendees": [], "detected_language": "en"}
        """)
        let model = CorrectionViewModel(
            stem: "s", recordingsDir: URL(fileURLWithPath: "/tmp"),
            runMeta: [:], originalSummary: original
        )
        XCTAssertEqual(model.makeCorrectedSummary().evidence, [:])
    }

    // MARK: - Chip presentation + the pending-seek mapping

    func test_chip_labels_use_the_shared_timestamp_format() {
        XCTAssertEqual(TranscriptDisplay.timestamp(12), "0:12")
        XCTAssertEqual(TranscriptDisplay.timestamp(754), "12:34")
        XCTAssertEqual(TranscriptDisplay.timestamp(3723), "1:02:03")
    }

    func test_markdown_suffix_mirrors_the_python_renderer() throws {
        let s = try decode(evidenceJSON)
        let md = AppleIntelligenceSummarizer.renderMarkdown(s)
        XCTAssertTrue(md.contains("- Agreed the export ships Friday. [0:12]"), md)
        XCTAssertTrue(md.contains("- SOP revision is in flight.\n"), md)
        XCTAssertTrue(md.contains("1. Ship the export on Friday. [0:12]"), md)
        XCTAssertTrue(md.contains("_(confidence: high)_ [0:40]"), md)
        XCTAssertTrue(md.contains("- Is the QMS export green? [12:34]"), md)
        // Timestamps only: the quote is in-app hover detail, never note content.
        XCTAssertFalse(md.contains("We will ship the export on Friday"), md)
    }

    func test_multiple_anchors_render_in_one_bracket() {
        XCTAssertEqual(
            AppleIntelligenceSummarizer.evidenceSuffix([
                .init(quote: "a", t: 12), .init(quote: "b", t: 754),
            ]),
            " [0:12, 12:34]"
        )
        XCTAssertEqual(AppleIntelligenceSummarizer.evidenceSuffix([]), "")
    }

    /// A chip hands the Transcript tab a time; the tab maps it to a row with the
    /// same lookup the play head uses. A stored anchor is always snapped to a
    /// segment start by the pipeline, so it must land on that exact row.
    func test_anchor_time_maps_to_the_cited_row() {
        let segments = [
            TranscriptSegment(index: 0, start: 0, end: 12, text: "Morning.", speakerID: "s0"),
            TranscriptSegment(index: 1, start: 12, end: 40, text: "We will ship Friday.", speakerID: "s1"),
            TranscriptSegment(index: 2, start: 754, end: 800, text: "QMS green?", speakerID: "s1"),
        ]
        XCTAssertEqual(TranscriptSegmentLookup.index(at: 12, in: segments), 1)
        XCTAssertEqual(TranscriptSegmentLookup.index(at: 754, in: segments), 2)
        // Mid-segment still resolves to the row that contains it.
        XCTAssertEqual(TranscriptSegmentLookup.index(at: 30, in: segments), 1)
    }
}
