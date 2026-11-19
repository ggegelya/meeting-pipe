import XCTest
@testable import MeetingPipe

/// SEC21: NDA classification no longer fails silently. The matcher says why it chose, broken or
/// mistyped workflow files stay visible instead of vanishing, the editor refuses an uncompilable
/// regex and drops a blank rule, and a missing title is countable. By the owner's decision
/// (2026-11-16) an undecided NDA classification is logged and changes no capture posture.
final class WorkflowFailClosedTests: XCTestCase {

    private let zoom = AppSource(bundleID: "us.zoom.xos", displayName: "Zoom")
    private func zoomTitled(_ title: String) -> AppSource {
        AppSource(bundleID: "us.zoom.xos", displayName: "Zoom", meetingTitle: title)
    }

    private func nda(_ rules: [WorkflowMatchingRule]) -> Workflow {
        var wf = Workflow(name: "Client NDA")
        wf.flags.ndaMode = true
        wf.matchingRules = rules
        return wf
    }

    private let general = Workflow(name: "General", isDefault: true)

    // MARK: - Item 1: the matcher's reason

    func test_anNDARuleWithAnUnknownTitle_isUndecided() {
        let client = nda([WorkflowMatchingRule(bundleID: "us.zoom.xos", titleRegex: "acme")])
        let result = WorkflowMatcher.resolveWithReason(source: zoom, workflows: [general, client])
        XCTAssertEqual(result.workflow?.id, general.id, "the posture is unchanged: the default still records")
        XCTAssertEqual(result.reason, .fallback(undecided: [client]))
    }

    func test_anNDARuleWithAnUncompilableRegex_isUndecided() {
        let client = nda([WorkflowMatchingRule(bundleID: "us.zoom.xos", titleRegex: "([unclosed")])
        let result = WorkflowMatcher.resolveWithReason(source: zoomTitled("Acme sync"), workflows: [general, client])
        XCTAssertEqual(result.reason, .fallback(undecided: [client]))
    }

    func test_aNonNDARuleIsNeverUndecided() {
        var client = Workflow(name: "Client")
        client.matchingRules = [WorkflowMatchingRule(bundleID: "us.zoom.xos", titleRegex: "acme")]
        XCTAssertEqual(WorkflowMatcher.resolveWithReason(source: zoom, workflows: [general, client]).reason, .fallback)
    }

    /// The owner's decision: a title-only NDA rule is not undecided.
    func test_aTitleOnlyNDARuleIsNotUndecided() {
        let client = nda([WorkflowMatchingRule(titleRegex: "acme")])
        XCTAssertEqual(WorkflowMatcher.resolveWithReason(source: zoom, workflows: [general, client]).reason, .fallback)
    }

    func test_aMatchingTitleStillMatchesAtThree() {
        let client = nda([WorkflowMatchingRule(bundleID: "us.zoom.xos", titleRegex: "acme")])
        let result = WorkflowMatcher.resolveWithReason(source: zoomTitled("ACME weekly"), workflows: [general, client])
        XCTAssertEqual(result.workflow?.id, client.id)
        XCTAssertEqual(result.reason, .matched(score: 3))
    }

    func test_aManualRecordingIsAPlainFallback() {
        let client = nda([WorkflowMatchingRule(bundleID: "us.zoom.xos", titleRegex: "acme")])
        XCTAssertEqual(WorkflowMatcher.resolveWithReason(source: nil, workflows: [general, client]).reason, .fallback)
    }

    // MARK: - Items 3 and 11: the editor's save

    func test_aBlankRuleIsDroppedAtSave_andAFilledOneKept() throws {
        let rules = [
            WorkflowMatchingRule(),
            WorkflowMatchingRule(bundleID: " us.zoom.xos "),
            WorkflowMatchingRule(titleRegex: "1:1"),
        ]
        let saved = try WorkflowRuleValidation.prepareForSave(rules).get()
        XCTAssertEqual(saved.map(\.bundleID), ["us.zoom.xos", ""])
        XCTAssertEqual(saved.map(\.titleRegex), ["", "1:1"])
    }

    func test_anUncompilableRegexCannotBeSaved() {
        let result = WorkflowRuleValidation.prepareForSave([WorkflowMatchingRule(bundleID: "us.zoom.xos", titleRegex: "([unclosed")])
        XCTAssertEqual(result, .failure(.regexDoesNotCompile("([unclosed")))
    }

    func test_theEditorCaptions() {
        XCTAssertEqual(WorkflowRuleValidation.caption(for: WorkflowMatchingRule(titleRegex: "(["), ndaMode: false), "This pattern is not valid.")
        XCTAssertNotNil(WorkflowRuleValidation.caption(for: WorkflowMatchingRule(titleRegex: "acme"), ndaMode: true))
        XCTAssertNil(WorkflowRuleValidation.caption(for: WorkflowMatchingRule(titleRegex: "acme"), ndaMode: false))
        XCTAssertNil(WorkflowRuleValidation.caption(for: WorkflowMatchingRule(bundleID: "us.zoom.xos"), ndaMode: true))
    }

    // MARK: - Items 5 and 6: the load path

    private func makeDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mp-sec21-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func test_brokenAndMistypedFiles_loadAsBrokenEntries() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = UUID()
        try "id = \"\(good.uuidString)\"\nname = \"Good\"\n".write(to: dir.appendingPathComponent("\(good.uuidString).toml"), atomically: true, encoding: .utf8)
        try "name = [unterminated".write(to: dir.appendingPathComponent("garbled.toml"), atomically: true, encoding: .utf8)
        try "id = \"\(UUID().uuidString)\"\nname = \"Stringly NDA\"\n[flags]\nnda_mode = \"true\"\n".write(to: dir.appendingPathComponent("stringly.toml"), atomically: true, encoding: .utf8)
        try "id = \"\(UUID().uuidString)\"\nname = \"Typo\"\nbackend = \"locl\"\n".write(to: dir.appendingPathComponent("typo.toml"), atomically: true, encoding: .utf8)
        try "name = \"No id\"\n".write(to: dir.appendingPathComponent("no-id.toml"), atomically: true, encoding: .utf8)

        let store = WorkflowStore(directory: dir)
        store.load()
        XCTAssertEqual(store.workflows.map(\.name), ["Good"])
        XCTAssertEqual(store.broken.map(\.fileName), ["garbled.toml", "no-id.toml", "stringly.toml", "typo.toml"])
        XCTAssertTrue(store.broken.allSatisfy { !$0.reason.isEmpty })
    }

    func test_aFileWithNoFlagsStillDecodes_andAMissingIDIsTakenFromTheName() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let named = UUID()
        try "name = \"Named by file\"\n".write(to: dir.appendingPathComponent("\(named.uuidString).toml"), atomically: true, encoding: .utf8)

        let store = WorkflowStore(directory: dir)
        store.load()
        store.load()
        XCTAssertEqual(store.workflows.map(\.id), [named])
        XCTAssertFalse(store.workflows[0].flags.ndaMode)
        XCTAssertTrue(store.broken.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(files.count, 1, "loading twice writes no second copy")
    }
}

/// SEC21 items 9 and the owner's decision: a record start with a source and no title is countable,
/// and an undecided NDA classification is logged with no change to the capture posture.
@MainActor
final class RoutingUncertaintySessionTests: XCTestCase {

    private var tempDir: URL!
    private var logs: URL!
    private var hosts: [FakeSessionHost] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sec21-\(UUID().uuidString)", isDirectory: true)
        logs = tempDir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        setenv("MEETINGPIPE_LOGS_DIR", logs.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("MEETINGPIPE_LOGS_DIR")
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private func rows(_ action: String) -> [[String: Any]] {
        let text = (try? String(contentsOf: logs.appendingPathComponent("events.jsonl"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }.filter { $0["action"] as? String == action }
    }

    func test_anUntitledStart_isCounted_andAnUndecidedNDAChangesNoPosture() async {
        let general = Workflow(name: "General", isDefault: true)
        var client = Workflow(name: "Client NDA")
        client.flags.ndaMode = true
        client.matchingRules = [WorkflowMatchingRule(bundleID: "us.zoom.xos", titleRegex: "acme")]
        let host = FakeSessionHost(tempDir: tempDir, workflows: [general, client])
        host.recorderSpy.lastSystemFires = 1
        hosts.append(host)
        let controller = MeetingSessionController(coordinator: host)

        controller.beginRecording(source: AppSource(bundleID: "us.zoom.xos", displayName: "Zoom"), summaryMode: .auto)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, controller.activeWorkflow == nil {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 500_000)
        }

        XCTAssertEqual(controller.activeWorkflow?.id, general.id)
        XCTAssertNotEqual(controller.activeCaptureMode, .regulatedGate, "the owner's decision: no posture change")
        let untitled = rows("meeting_title_unresolved")
        XCTAssertEqual(untitled.first?["bundle_id"] as? String, "us.zoom.xos")
        XCTAssertNil(untitled.first?["title"])
        let undecided = rows("nda_classification_undecided")
        XCTAssertEqual(undecided.first?["undecided_workflow_ids"] as? [String], [client.id.uuidString])
        XCTAssertEqual(undecided.first?["posture_changed"] as? Bool, false)
    }
}
