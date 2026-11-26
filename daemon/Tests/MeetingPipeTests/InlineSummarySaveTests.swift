import XCTest
@testable import MeetingPipe

/// UX99: the Summary tab's inline editor save checks what it read, as UX65's standalone window
/// does, and a failed write keeps the editor open instead of reporting Saved.
final class InlineSummarySaveTests: XCTestCase {

    private var dir: URL!
    private var corrections: URL!
    private var summaryURL: URL { dir.appendingPathComponent("m.summary.json") }
    private var recordURL: URL { corrections.appendingPathComponent("m.json") }

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ux99-\(UUID().uuidString)")
        dir = root.appendingPathComponent("raw")
        corrections = root.appendingPathComponent("corrections")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: corrections, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    }

    private func writeSummary(_ s: MeetingSummary) throws {
        let data = try JSONSerialization.data(withJSONObject: s.jsonObject(), options: [.prettyPrinted, .sortedKeys])
        try data.write(to: summaryURL)
    }

    private let snapshot = MeetingSummary(
        title: "Generated", summary: ["old bullet"], decisions: ["old decision"],
        actions: [.init(task: "ship it")], questions: ["old question"], detectedLanguage: "en"
    )

    /// The editor exactly as `SummaryTab.beginEditing` builds it.
    private func openEditor(_ summary: MeetingSummary? = nil) throws -> CorrectionViewModel {
        try writeSummary(summary ?? snapshot)
        return try XCTUnwrap(CorrectionViewModel.forInlineEditor(stem: "m", recordingsDir: dir, runMeta: [:]))
    }

    private func save(_ model: CorrectionViewModel, choice: CorrectionWindow.StaleSaveChoice? = nil,
                      writer: InlineSummarySave.SummaryWriter? = nil) -> InlineSummarySave.Outcome {
        InlineSummarySave.save(
            model: model, staleChoice: choice,
            writeSummary: writer ?? InlineSummarySave.liveWriter,
            correctionsDirectoryOverride: corrections
        )
    }

    private func record() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as? [String: Any])
    }

    func test_beginEditing_captures_the_identity_of_an_existing_summary() throws {
        XCTAssertNotNil(try openEditor().loadedIdentity)
    }

    func test_an_unchanged_file_saves_one_record_and_one_summary() throws {
        let model = try openEditor()
        model.summary = ["edited bullet"]
        XCTAssertEqual(save(model), .saved)
        XCTAssertEqual(MeetingSummary.load(from: summaryURL)?.summary, ["edited bullet"])
        let original = try XCTUnwrap(try record()["original_summary"] as? [String: Any])
        XCTAssertEqual(original["summary"] as? [String], ["old bullet"])
    }

    func test_a_regenerate_under_the_editor_writes_nothing_until_the_owner_chooses() throws {
        let model = try openEditor()
        model.summary = ["edited bullet"]
        let regenerated = MeetingSummary(
            title: "Regenerated", summary: ["new bullet"], decisions: ["new decision"],
            actions: [.init(task: "ship it", resolved: true)], questions: ["new question"], detectedLanguage: "en"
        )
        try writeSummary(regenerated)
        let before = try Data(contentsOf: summaryURL)

        XCTAssertEqual(save(model), .needsStaleChoice)
        XCTAssertEqual(try Data(contentsOf: summaryURL), before, "nothing written without a choice")
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordURL.path))

        XCTAssertEqual(save(model, choice: .reopen), .reopen)
        XCTAssertEqual(try Data(contentsOf: summaryURL), before, "reopen writes nothing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordURL.path))
    }

    func test_keeping_the_edits_lands_them_on_the_current_summary_and_records_it_as_the_original() throws {
        let model = try openEditor()
        model.summary = ["edited bullet"]
        let regenerated = MeetingSummary(
            title: "Regenerated", summary: ["new bullet"], decisions: ["new decision"],
            actions: [.init(task: "ship it", resolved: true)], questions: ["new question"], detectedLanguage: "en"
        )
        try writeSummary(regenerated)

        XCTAssertEqual(save(model, choice: .keep), .saved)
        let live = try XCTUnwrap(MeetingSummary.load(from: summaryURL))
        XCTAssertEqual(live.summary, ["edited bullet"], "the field the owner edited")
        XCTAssertEqual(live.decisions, ["new decision"], "untouched fields keep the regenerated content")
        XCTAssertEqual(live.questions, ["new question"])
        XCTAssertEqual(live.title, "Regenerated")
        XCTAssertEqual(live.actions.first?.resolved, true, "a tick made since the editor opened survives")
        let original = try XCTUnwrap(try record()["original_summary"] as? [String: Any])
        XCTAssertEqual(original["summary"] as? [String], ["new bullet"], "graded against what is on disk now")
    }

    func test_a_failed_summary_write_is_a_failure_not_saved() throws {
        let model = try openEditor()
        model.summary = ["edited bullet"]
        struct Refused: Error {}
        let outcome = save(model, writer: { _, _ in throw Refused() })
        guard case .failed(let message) = outcome else { return XCTFail("expected failure, got \(outcome)") }
        XCTAssertTrue(message.contains("Your edits are still here"))
        XCTAssertEqual(MeetingSummary.load(from: summaryURL)?.summary, ["old bullet"])
    }

    // MARK: A failed save leaves nothing behind (UX99 amendment, 2026-11-21)

    private var metaURL: URL { MeetingMetaRead.url(stem: "m", in: dir) }

    /// The record and the rename go first and the summary write is the commit point, so a summary
    /// write that fails takes both back: the archive must not claim an edit, or a title, that never
    /// landed, and a second Save after the cause is fixed must not stack on a phantom record.
    func test_a_failed_summary_write_leaves_no_record_and_no_rename() throws {
        let model = try openEditor()
        model.title = "Quarterly planning"
        model.summary = ["edited bullet"]
        let before = try Data(contentsOf: summaryURL)
        struct Refused: Error {}
        let outcome = save(model, writer: { _, _ in throw Refused() })
        guard case .failed(let message) = outcome else { return XCTFail("expected failure, got \(outcome)") }
        XCTAssertTrue(message.contains("nothing was saved"), message)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordURL.path), "no correction record for an edit that never landed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: metaURL.path), "no rename, and no sidecar conjured to hold one")
        XCTAssertEqual(try Data(contentsOf: summaryURL), before)
    }

    /// Undo means the state before this Save, not absence: an earlier correction's record and a
    /// `meta.json` carrying other keys and an older rename come back byte for byte.
    func test_a_failed_summary_write_restores_an_earlier_record_and_rename() throws {
        let model = try openEditor()
        let priorRecord = Data(#"{"verdict":"edited","original_summary":{"title":"Generated"}}"#.utf8)
        let priorMeta = Data(#"{"regulated_mode":true,"user_title":"Older rename"}"#.utf8)
        try priorRecord.write(to: recordURL)
        try priorMeta.write(to: metaURL)
        model.title = "Quarterly planning"
        model.summary = ["edited bullet"]
        struct Refused: Error {}
        guard case .failed = save(model, writer: { _, _ in throw Refused() }) else { return XCTFail("expected failure") }
        XCTAssertEqual(try Data(contentsOf: recordURL), priorRecord)
        XCTAssertEqual(try Data(contentsOf: metaURL), priorMeta)
    }

    /// An undo that cannot land is said, not hidden behind "nothing was saved".
    func test_an_undo_that_cannot_land_says_so() throws {
        let model = try openEditor()
        model.summary = ["edited bullet"]
        addTeardownBlock { [corrections] in
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: corrections!.path)
        }
        struct Refused: Error {}
        let outcome = save(model, writer: { [corrections] _, _ in
            // The record is in; a read-only corrections folder stops the undo from removing it.
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: corrections!.path)
            throw Refused()
        })
        guard case .failed(let message) = outcome else { return XCTFail("expected failure, got \(outcome)") }
        XCTAssertFalse(message.contains("nothing was saved"), message)
        XCTAssertTrue(message.contains("could not be taken back"), message)
    }

    /// The rename step failing is the same defect one step earlier: the record it follows is taken back.
    func test_a_failed_rename_leaves_no_record() throws {
        let model = try openEditor()
        try Data("not json".utf8).write(to: metaURL)
        model.title = "Quarterly planning"
        model.summary = ["edited bullet"]
        let before = try Data(contentsOf: summaryURL)
        guard case .failed(let message) = save(model) else { return XCTFail("expected failure") }
        XCTAssertTrue(message.contains("nothing was saved"), message)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordURL.path))
        XCTAssertEqual(try Data(contentsOf: summaryURL), before)
    }

    /// Fields the editor normalizes (a padded bullet, an action's `group`, an empty row) but the
    /// owner never touched must not read as edited, or "Keep my edits" would put the stale
    /// snapshot back over the regenerated section.
    func test_untouched_sections_the_editor_normalizes_still_take_the_regenerated_content() throws {
        let opened = MeetingSummary(
            title: "Generated", summary: ["  padded bullet  ", ""], decisions: ["old decision"],
            actions: [.init(task: "ship it", group: "Release")], questions: ["old question"], detectedLanguage: "en"
        )
        let model = try openEditor(opened)
        model.questions = ["edited question"]
        let regenerated = MeetingSummary(
            title: "Regenerated", summary: ["new bullet"], decisions: ["new decision"],
            actions: [.init(task: "new task", group: "Launch")], questions: ["new question"], detectedLanguage: "en"
        )
        try writeSummary(regenerated)

        XCTAssertEqual(save(model, choice: .keep), .saved)
        let live = try XCTUnwrap(MeetingSummary.load(from: summaryURL))
        XCTAssertEqual(live.questions, ["edited question"])
        XCTAssertEqual(live.summary, ["new bullet"])
        XCTAssertEqual(live.decisions, ["new decision"])
        XCTAssertEqual(live.actions.map(\.task), ["new task"])
        XCTAssertEqual(live.actions.first?.group, "Launch")
    }

    func test_the_inline_editor_and_the_window_share_the_record_writer() throws {
        // The record goes through `CorrectionWindow.performSave`, so a stale keep files it against
        // the current summary exactly as UX65's window does (its own tests pin that path).
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MeetingPipe/Library/InlineSummarySave.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("CorrectionWindow.performSave("))
        XCTAssertFalse(source.contains("CorrectionStore.write("), "one record writer, not two")
    }

    /// The record carries the typed title (what the owner corrected), the rename lands in
    /// `meta.json`, and `summary.json` keeps the generated title (PIPE55).
    func test_a_typed_title_reaches_the_record_and_the_rename_but_not_the_summary() throws {
        let model = try openEditor()
        model.title = "Quarterly planning"
        XCTAssertEqual(save(model), .saved)
        let corrected = try XCTUnwrap(try record()["corrected_summary"] as? [String: Any])
        XCTAssertEqual(corrected["title"] as? String, "Quarterly planning")
        XCTAssertEqual(MeetingSummary.load(from: summaryURL)?.title, "Generated")
        guard case .loaded(let meta) = MeetingMetaRead.load(stem: "m", in: dir) else { return XCTFail("no meta.json") }
        XCTAssertEqual(meta["user_title"] as? String, "Quarterly planning")
    }
}
