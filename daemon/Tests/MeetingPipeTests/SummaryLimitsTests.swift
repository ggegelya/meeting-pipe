import XCTest
@testable import MeetingPipe

/// PIPE54: Swift writes `<stem>.summary.json` only in shapes the pipeline's `MeetingSummary` schema
/// accepts. `mp publish` re-validates the file before any sink, and an exit there used to land the
/// row at stage `.pipeline`, whose Retry re-summarized over the user's edit.
final class SummaryLimitsTests: XCTestCase {

    // MARK: - The limits are the pipeline's

    func test_the_swift_limits_equal_the_pipelines_schema() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "summary-limits-golden", withExtension: "json"),
                                "missing fixture summary-limits-golden.json")
        let doc = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let contract = try XCTUnwrap(doc["contract"] as? [String: Any])
        XCTAssertEqual(contract["title_max_length"] as? Int, MeetingSummary.titleMaxLength)
        XCTAssertEqual(contract["summary_max_items"] as? Int, MeetingSummary.summaryMaxItems)
        XCTAssertEqual(contract["confidence_values"] as? [String], MeetingSummary.confidenceValues)
        XCTAssertEqual(contract["title_min_length"] as? Int, MeetingSummary.titleMinLength)
        XCTAssertEqual(contract["summary_min_items"] as? Int, MeetingSummary.summaryMinItems)
    }

    /// PIPE43: the editor refuses a save `mp publish` would now refuse: no title, or no bullet
    /// once blank ones are discounted.
    func test_an_empty_title_or_no_bullet_is_refused_by_the_editor() {
        XCTAssertEqual(editor(MeetingSummary(title: "  ", summary: ["b"])).schemaRefusal,
                       "The title is empty. Add one before saving.")
        XCTAssertEqual(editor(MeetingSummary(title: "T", summary: ["  ", ""])).schemaRefusal,
                       "The summary needs at least one bullet. Add one before saving.")
        XCTAssertNil(editor(MeetingSummary(title: "T", summary: ["b"])).schemaRefusal)
    }

    // MARK: - The write backstop

    private func overLimit() -> MeetingSummary {
        MeetingSummary(
            title: String(repeating: "t", count: 130),
            summary: (1...11).map { "bullet \($0)" },
            decisions: [], actions: [
                .init(task: "ship it", confidence: "Very high"),
                .init(task: "check it", confidence: "High"),
                .init(task: "keep it", confidence: "low"),
            ],
            questions: [], attendees: [], detectedLanguage: "en", extraSections: [],
            evidence: ["summary": (1...11).map { [MeetingSummary.Evidence(quote: "q\($0)", t: Double($0))] }]
        )
    }

    func test_jsonObject_clamps_bullets_title_and_confidence() throws {
        let obj = overLimit().jsonObject()
        XCTAssertEqual((obj["summary"] as? [String])?.count, 10)
        XCTAssertEqual((obj["summary"] as? [String])?.last, "bullet 10", "the first ten, in order")
        XCTAssertEqual((obj["title"] as? String)?.unicodeScalars.count, 120)
        let confidences = (obj["actions"] as? [[String: Any]])?.compactMap { $0["confidence"] as? String }
        // Case-sensitive like `digest._clamp_confidence`: "High" is outside the enum too.
        XCTAssertEqual(confidences, ["medium", "medium", "low"])
        let anchors = (obj["evidence"] as? [String: Any])?["summary"] as? [Any]
        XCTAssertEqual(anchors?.count, 10, "the anchors stay index-aligned with the bullets")
    }

    func test_the_title_clamp_counts_as_python_counts() {
        // Python's len() counts Unicode scalars; a grapheme count would let this through at 121.
        let flagged = String(repeating: "a", count: 119) + "\u{1F1FA}\u{1F1E6}"   // 119 + one flag (2 scalars)
        XCTAssertEqual(flagged.count, 120)
        XCTAssertEqual(MeetingSummary.schemaLength(flagged), 121)
        XCTAssertEqual(MeetingSummary.schemaLength(MeetingSummary.clampTitle(flagged)), 120)
    }

    func test_a_summary_inside_the_limits_round_trips_unchanged() {
        var s = overLimit()
        s.title = "Fine"
        s.summary = ["one", "two"]
        s.evidence = [:]
        s.actions = [.init(task: "x", confidence: "high")]
        XCTAssertEqual(s.clampedToSchema(), s)
    }

    // MARK: - The editor refuses rather than truncating

    private func editor(_ summary: MeetingSummary) -> CorrectionViewModel {
        CorrectionViewModel(stem: "m", recordingsDir: FileManager.default.temporaryDirectory,
                            runMeta: [:], originalSummary: summary)
    }

    func test_an_editor_at_ten_bullets_cannot_add_an_eleventh() {
        let model = editor(MeetingSummary(title: "T", summary: (1...9).map { "b\($0)" }))
        XCTAssertTrue(model.canAddSummaryBullet)
        model.summary.append("b10")
        XCTAssertFalse(model.canAddSummaryBullet)
        XCTAssertNil(model.schemaRefusal)
        XCTAssertEqual(CorrectionEditorBody.limitNote(count: 10, limit: 10), "Up to 10.")
        XCTAssertNil(CorrectionEditorBody.limitNote(count: 9, limit: 10))
    }

    func test_a_summary_already_over_the_limit_is_refused_not_cut() {
        let model = editor(MeetingSummary(title: "T", summary: (1...11).map { "b\($0)" }))
        XCTAssertEqual(model.schemaRefusal, "The summary has 11 bullets; the limit is 10. Remove 1 before saving.")
        XCTAssertEqual(CorrectionEditorBody.limitNote(count: 11, limit: 10), "Up to 10. Remove 1 to save.")
        model.summary.removeLast()
        XCTAssertNil(model.schemaRefusal)
    }

    func test_a_130_character_title_is_refused_by_the_editor_and_by_the_rename() throws {
        let long = String(repeating: "t", count: 130)
        XCTAssertEqual(editor(MeetingSummary(title: long)).schemaRefusal,
                       "The title is 130 characters; the limit is 120. Shorten it before saving.")
        XCTAssertEqual(MeetingSummary.titleLimitNote(String(repeating: "t", count: 120)), "Titles stop at 120 characters.")
        XCTAssertNil(MeetingSummary.titleLimitNote("short"))

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pipe54-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let meta = dir.appendingPathComponent("m.meta.json")
        try Data(#"{"schema_version": 1}"#.utf8).write(to: meta)
        let before = try Data(contentsOf: meta)
        guard case .failure(.tooLong) = UserTitleStore.write(title: long, stem: "m", in: dir) else { return XCTFail("expected tooLong") }
        XCTAssertEqual(try Data(contentsOf: meta), before, "the file is unchanged")
        guard case .success = UserTitleStore.write(title: String(repeating: "t", count: 120), stem: "m", in: dir) else { return XCTFail("a 120-character title fits") }
    }

    // MARK: - The publish refusal names the fix on the row

    func test_a_pre_sink_publish_refusal_explains_what_to_edit() {
        let stderr = "2026-11-18 INFO mp.entry: armed\n[FAIL] The summary has 11 bullets; the limit is 10. Edit the summary, then Republish.\n"
        let failure = FailurePresentation(
            error: PipelineLauncher.LaunchError.nonZeroExit(PipelineLauncher.publishFailedExitCode, stderr),
            operation: .publish
        )
        XCTAssertTrue(failure.explanation.hasSuffix("The summary has 11 bullets; the limit is 10. Edit the summary, then Republish."),
                      failure.explanation)
        XCTAssertEqual(SinkDispatcher.stage(for: PipelineLauncher.LaunchError.nonZeroExit(
            PipelineLauncher.publishFailedExitCode, stderr)), .publish)
    }

    /// The Library's detail pane builds the notice from `<stem>.error.json` (stage, reason,
    /// metadata), not from the error, so the sentence has to survive that round trip.
    func test_the_refusal_reaches_the_detail_notice_through_the_failure_sidecar() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pipe54-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let error = PipelineLauncher.LaunchError.nonZeroExit(
            PipelineLauncher.publishFailedExitCode,
            "INFO mp.entry: armed\n[FAIL] The title is 130 characters; the limit is 120. Edit the summary, then Republish.\n"
        )
        // What `performRepublish` writes on a failed publish.
        PipelineFailureSidecar.write(stem: "m", in: dir, stage: SinkDispatcher.stage(for: error),
                                     reason: PipelineLauncher.diagnostics(for: error), metadata: FailureMetadata.from(error))
        let sidecar = try XCTUnwrap(PipelineFailureSidecar.read(stem: "m", in: dir))
        XCTAssertEqual(sidecar.stage, .publish)
        // What `MeetingDetailView.failureNotice` builds from it.
        let notice = FailurePresentation(diagnostics: sidecar.reason, operation: .publish, metadata: sidecar.metadata)
        XCTAssertTrue(notice.explanation.hasSuffix("The title is 130 characters; the limit is 120. Edit the summary, then Republish."),
                      notice.explanation)
    }
}
