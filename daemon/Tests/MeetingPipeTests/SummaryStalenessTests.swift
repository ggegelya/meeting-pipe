import XCTest
@testable import MeetingPipe

/// UX65. The grading window read `<stem>.summary.json` once and never again, so
/// a regenerate landing while it was open left it grading prose that was no
/// longer the summary, and the record it then wrote carried that prose as
/// `original_summary`, which is what `CorrectionsTab.performRevert` restores
/// over the live file under a button labelled Revert.
final class SummaryStalenessTests: XCTestCase {

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ux65-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func identity(_ text: String, in dir: URL, named name: String = "s.json") throws -> (URL, SummaryIdentity?) {
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return (url, SummaryIdentity.read(at: url))
    }

    // MARK: - The predicate, pinned directly rather than through a window

    func test_an_untouched_file_reads_as_fresh() throws {
        let dir = try tempDir()
        let (url, loaded) = try identity("{\"title\":\"a\"}", in: dir)
        XCTAssertFalse(SummaryStaleness.hasMoved(loaded: loaded, current: SummaryIdentity.read(at: url)))
    }

    func test_a_file_rewritten_in_place_with_new_content_reads_as_stale() throws {
        let dir = try tempDir()
        let (url, loaded) = try identity("{\"title\":\"a\"}", in: dir)
        try "{\"title\":\"b\"}".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertTrue(SummaryStaleness.hasMoved(loaded: loaded, current: SummaryIdentity.read(at: url)))
    }

    /// The documented choice the spec asked for by name: identity is the file's
    /// **bytes**, so a rewrite that reproduces them reads as **fresh**. An mtime
    /// guard would call it stale and stop a save over a change that did not
    /// happen, which is the fires-on-everything failure the owner walkthrough's
    /// last step exists to catch. The prose is the same, so the record would be
    /// correct, so there is nothing to ask about.
    func test_a_file_rewritten_with_identical_bytes_reads_as_fresh_by_design() throws {
        let dir = try tempDir()
        let (url, loaded) = try identity("{\"title\":\"a\"}", in: dir)
        // A real rewrite: removed and recreated, so the mtime and inode move.
        try FileManager.default.removeItem(at: url)
        try "{\"title\":\"a\"}".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertFalse(SummaryStaleness.hasMoved(loaded: loaded, current: SummaryIdentity.read(at: url)))
    }

    /// A summary that has vanished is certainly not the one that was graded, and
    /// writing a record whose `summary_json_path` points at nothing is the same
    /// defect with an extra step.
    func test_a_vanished_file_reads_as_stale() throws {
        let dir = try tempDir()
        let (url, loaded) = try identity("{\"title\":\"a\"}", in: dir)
        try FileManager.default.removeItem(at: url)
        XCTAssertTrue(SummaryStaleness.hasMoved(loaded: loaded, current: SummaryIdentity.read(at: url)))
    }

    /// The one fail-open, documented: with no baseline there is nothing to
    /// compare, and prompting on no evidence is a guard firing on a condition it
    /// cannot describe. `SummaryTab`'s editor rides this branch on purpose, since
    /// UX65 scopes that path out and it keeps its own mtime.
    func test_no_captured_identity_reads_as_fresh() throws {
        let dir = try tempDir()
        let (url, _) = try identity("{\"title\":\"a\"}", in: dir)
        XCTAssertFalse(SummaryStaleness.hasMoved(loaded: nil, current: SummaryIdentity.read(at: url)))
    }

    // MARK: - The copy, and the owner's per-verdict split

    func test_an_edit_defaults_to_keeping_what_the_owner_typed() {
        let choice = SummaryStaleness.choice(verdict: .edited)
        XCTAssertTrue(choice.defaultIsKeep)
        XCTAssertEqual(choice.keepButton, "Keep my edits")
        XCTAssertTrue(choice.message.contains("Nothing is saved until you choose."), choice.message)
    }

    /// The sharper half of the defect: a bad verdict against a summary that has
    /// already been replaced is meaningless, and the owner has almost nothing
    /// typed to lose, so this one defaults the other way.
    func test_a_bad_verdict_defaults_to_reloading_and_looking() {
        let choice = SummaryStaleness.choice(verdict: .bad)
        XCTAssertFalse(choice.defaultIsKeep)
        XCTAssertEqual(choice.reopenButton, "Reload and look")
        XCTAssertTrue(choice.message.contains("may be fine"), choice.message)
    }

    func test_both_options_are_offered_on_both_verdicts() {
        for verdict in [CorrectionStore.Verdict.edited, .bad, .good] {
            let choice = SummaryStaleness.choice(verdict: verdict)
            XCTAssertFalse(choice.keepButton.isEmpty)
            XCTAssertFalse(choice.reopenButton.isEmpty)
            XCTAssertNotEqual(choice.keepButton, choice.reopenButton)
            XCTAssertFalse(choice.title.contains("\u{2014}"))
            XCTAssertFalse(choice.message.contains("\u{2014}"))
        }
    }

    // MARK: - The save, pinned on the bytes of corrections/<stem>.json

    private struct Fixture {
        let model: CorrectionViewModel
        let summaryURL: URL
        let correctionsDir: URL
        var recordURL: URL { correctionsDir.appendingPathComponent("\(model.stem).json") }
    }

    private func fixture(summary: String = "{\"title\":\"first\",\"summary\":[\"one\"]}") throws -> Fixture {
        let dir = try tempDir()
        let corrections = try tempDir()
        let stem = "20260816-101500"
        let summaryURL = dir.appendingPathComponent("\(stem).summary.json")
        try summary.write(to: summaryURL, atomically: true, encoding: .utf8)
        let loaded = MeetingSummary.load(from: summaryURL)
        XCTAssertNotNil(loaded)
        let model = CorrectionViewModel(
            stem: stem,
            recordingsDir: dir,
            runMeta: ["backend": "local", "model": "fake"],
            originalSummary: loaded!,
            loadedIdentity: SummaryIdentity.read(at: summaryURL)
        )
        return Fixture(model: model, summaryURL: summaryURL, correctionsDir: corrections)
    }

    private func save(
        _ f: Fixture,
        verdict: CorrectionStore.Verdict = .edited,
        choose: @escaping (CorrectionStore.Verdict) -> CorrectionWindow.StaleSaveChoice
    ) throws -> CorrectionWindow.SaveOutcome {
        try CorrectionWindow.performSave(
            model: f.model,
            verdict: verdict,
            corrected: verdict == .bad ? nil : f.model.makeCorrectedSummary().jsonObject(),
            resolveStale: choose,
            correctionsDirectoryOverride: f.correctionsDir
        )
    }

    /// The acceptance, on the bytes: after a save attempt against a moved
    /// summary where the owner reopens, `corrections/<stem>.json` must not
    /// exist. A return value alone would pass over a write that happened first.
    func test_reopening_writes_no_correction_record_at_all() throws {
        let f = try fixture()
        try "{\"title\":\"regenerated\"}".write(to: f.summaryURL, atomically: true, encoding: .utf8)

        let outcome = try save(f, choose: { _ in .reopen })

        XCTAssertEqual(outcome, .reopened)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: f.recordURL.path),
            "a stale save that was reopened still wrote a record"
        )
    }

    /// And when a record already existed, reopening leaves its bytes untouched.
    func test_reopening_leaves_an_existing_record_byte_identical() throws {
        let f = try fixture()
        let previous = Data("{\"kept\":true}".utf8)
        try previous.write(to: f.recordURL, options: .atomic)
        try "{\"title\":\"regenerated\"}".write(to: f.summaryURL, atomically: true, encoding: .utf8)

        _ = try save(f, choose: { _ in .reopen })

        XCTAssertEqual(try Data(contentsOf: f.recordURL), previous)
    }

    /// Keeping records the edit against what is on disk **now**, which is what
    /// makes a later Revert restore the current prose rather than write
    /// superseded prose back over it.
    func test_keeping_records_the_edit_against_the_current_summary() throws {
        let f = try fixture()
        try "{\"title\":\"regenerated\",\"summary\":[\"two\"]}"
            .write(to: f.summaryURL, atomically: true, encoding: .utf8)

        _ = try save(f, choose: { _ in .keep })

        let record = try JSONSerialization.jsonObject(
            with: Data(contentsOf: f.recordURL)
        ) as? [String: Any]
        let original = record?["original_summary"] as? [String: Any]
        XCTAssertEqual(original?["title"] as? String, "regenerated")
        XCTAssertNotEqual(
            original?["title"] as? String, "first",
            "the record still carries the prose the window loaded, which is the defect"
        )
    }

    /// The step that catches a guard firing on everything: an untouched summary
    /// saves exactly as it does today, with no dialog consulted and the loaded
    /// summary as the original.
    func test_a_fresh_save_never_asks_and_records_the_loaded_summary() throws {
        let f = try fixture()
        var asked = false

        let outcome = try save(f, choose: { _ in asked = true; return .reopen })

        XCTAssertFalse(asked, "the fresh path consulted the staleness dialog")
        guard case .written = outcome else { return XCTFail("fresh save did not write") }
        let record = try JSONSerialization.jsonObject(
            with: Data(contentsOf: f.recordURL)
        ) as? [String: Any]
        let original = record?["original_summary"] as? [String: Any]
        XCTAssertEqual(original?["title"] as? String, "first")
        XCTAssertEqual(record?["verdict"] as? String, "edited")
    }

    func test_a_bad_verdict_on_a_stale_summary_also_writes_nothing_when_reopened() throws {
        let f = try fixture()
        try "{\"title\":\"regenerated\"}".write(to: f.summaryURL, atomically: true, encoding: .utf8)

        let outcome = try save(f, verdict: .bad, choose: { _ in .reopen })

        XCTAssertEqual(outcome, .reopened)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.recordURL.path))
    }

    // MARK: - Source fence

    /// A capture that is never compared is precisely the failure mode this task
    /// is about, and every write-path test above would still pass with the
    /// comparison deleted, since they inject the resolver. So fence the two ends
    /// in the source: `show()` takes the identity, and the save path reads it.
    func test_the_window_captures_the_identity_on_open_and_reads_it_on_save() throws {
        let source = try daemonSource("Sources/MeetingPipe/CorrectionWindow.swift")

        guard let showRange = source.range(of: "private func show(stem:"),
              // `show()`'s slice stops at the next declaration, or the fence
              // would be satisfied by text anywhere below it in the file.
              let showEnd = source.range(of: "private func handleOutcome(", range: showRange.upperBound..<source.endIndex),
              let saveRange = source.range(of: "static func performSave(") else {
            return XCTFail("CorrectionWindow no longer has the functions this fence names")
        }
        let showBody = String(source[showRange.lowerBound..<showEnd.lowerBound])
        let saveBody = String(source[saveRange.lowerBound...])

        XCTAssertTrue(
            showBody.contains("SummaryIdentity.read(at: summaryURL)"),
            "show() no longer captures what it loaded"
        )
        XCTAssertTrue(
            showBody.contains("loadedIdentity: loadedIdentity"),
            "the captured identity no longer reaches the view model"
        )
        XCTAssertTrue(
            saveBody.contains("SummaryStaleness.hasMoved("),
            "the save path no longer compares the capture, so the capture is dead"
        )
        XCTAssertTrue(
            saveBody.contains("loaded: model.loadedIdentity"),
            "the save path compares something other than what show() captured"
        )
    }

    private func daemonSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MeetingPipeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // daemon
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
