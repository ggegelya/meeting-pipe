import XCTest
@testable import MeetingPipe

/// UX26: resolving an action item from the Summary tab.
///
/// Two halves, both of which have a way of going quietly wrong. The shared writer
/// (`MeetingLibraryService.setActionResolved`) edits a file the pipeline owns, so
/// the failure mode is a lost field or a resolved-the-wrong-row, neither of which
/// shows up until a republish. The renderer's rows carry the index that writer is
/// called with, so a mapping that drifts closes somebody else's commitment.
final class ActionResolveTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ux26-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Fixtures

    private func summaryURL(_ stem: String = "20270101-100000") -> URL {
        dir.appendingPathComponent("\(stem).summary.json")
    }

    /// A summary with something in every field, so a write that drops one is visible.
    /// That deliberately includes FEAT10's evidence, on both surfaces it lives on
    /// (the section map and inline on an action), because the anchors are the field
    /// this writer is most likely to quietly delete: the pipeline verifies them and
    /// nothing in a done/reopen toggle has any business touching them.
    private func fullSummary() -> MeetingSummary {
        MeetingSummary(
            title: "Weekly sync",
            summary: ["Shipped the installer", "Cut scope on search"],
            decisions: ["Ship on Friday"],
            actions: [
                MeetingSummary.ActionItem(
                    task: "Send the deck", owner: "Sam", due: "2027-01-20",
                    evidence: [MeetingSummary.Evidence(quote: "i'll send the deck monday", t: 61.5)]
                ),
                MeetingSummary.ActionItem(task: "Book the venue", confidence: "high"),
            ],
            questions: ["Who owns the rollout?"],
            attendees: ["Sam", "You"],
            detectedLanguage: "en",
            extraSections: [
                MeetingSummary.ExtraSection(name: "Billable follow-ups", content: ["Invoice the workshop"]),
            ],
            evidence: [
                "summary": [[MeetingSummary.Evidence(quote: "the installer is out", t: 12.25)], []],
            ]
        )
    }

    @discardableResult
    private func write(_ summary: MeetingSummary, to url: URL) throws -> [String: Any] {
        let dict = summary.jsonObject()
        try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
            .write(to: url)
        return dict
    }

    private func readJSON(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - The shared writer

    func testResolvingWritesTheFlag() throws {
        let url = summaryURL()
        try write(fullSummary(), to: url)

        XCTAssertTrue(MeetingLibraryService.setActionResolved(
            summaryURL: url, actionIndex: 0, taskText: "Send the deck", resolved: true
        ))

        let reloaded = try XCTUnwrap(MeetingSummary.load(from: url))
        XCTAssertTrue(reloaded.actions[0].resolved)
        XCTAssertFalse(reloaded.actions[1].resolved, "an unrelated action must not move")
    }

    func testReopenFlipsItBack() throws {
        let url = summaryURL()
        var summary = fullSummary()
        summary.actions[0].resolved = true
        try write(summary, to: url)

        XCTAssertTrue(MeetingLibraryService.setActionResolved(
            summaryURL: url, actionIndex: 0, taskText: "Send the deck", resolved: false
        ))

        let reloaded = try XCTUnwrap(MeetingSummary.load(from: url))
        XCTAssertFalse(reloaded.actions[0].resolved, "the toggle is reversible, not one-way")
    }

    /// The interlock clause of the spec, and the reason the writer round-trips
    /// through `MeetingSummary.jsonObject()` instead of rebuilding the file from the
    /// fields it happens to know about. Asserted as a general property (every
    /// top-level key except `actions` survives byte-identical), so it keeps meaning
    /// something as the model grows: FEAT10's `evidence` landed first and is covered
    /// by the same loop, with no per-field assertion to remember to add.
    func testTogglePreservesEveryFieldItDoesNotEdit() throws {
        let url = summaryURL()
        let before = try write(fullSummary(), to: url)
        // Guard against a vacuous pass: the property is only worth anything if the
        // fixture actually carried the fields it claims to protect.
        XCTAssertFalse((before["evidence"] as? [String: Any])?.isEmpty ?? true)
        XCTAssertFalse((before["extra_sections"] as? [Any])?.isEmpty ?? true)

        XCTAssertTrue(MeetingLibraryService.setActionResolved(
            summaryURL: url, actionIndex: 0, taskText: "Send the deck", resolved: true
        ))
        let after = try readJSON(url)

        XCTAssertEqual(
            Set(before.keys), Set(after.keys),
            "a toggle must not add or drop a top-level key"
        )
        for key in before.keys where key != "actions" {
            XCTAssertEqual(
                before[key] as? NSObject, after[key] as? NSObject,
                "\(key) is not the toggle's to edit"
            )
        }

        // Within the actions, only the one flag moves: the other keys on the
        // touched row (owner, due, confidence, group, evidence) and the whole
        // untouched row.
        let beforeActions = try XCTUnwrap(before["actions"] as? [[String: Any]])
        let afterActions = try XCTUnwrap(after["actions"] as? [[String: Any]])
        XCTAssertEqual(beforeActions.count, afterActions.count)
        XCTAssertEqual(afterActions[0]["resolved"] as? Bool, true)
        XCTAssertFalse(
            (afterActions[0]["evidence"] as? [Any])?.isEmpty ?? true,
            "the row's verified anchors must survive being ticked done"
        )
        for key in beforeActions[0].keys where key != "resolved" {
            XCTAssertEqual(beforeActions[0][key] as? NSObject, afterActions[0][key] as? NSObject)
        }
        XCTAssertEqual(beforeActions[1] as NSDictionary, afterActions[1] as NSDictionary)
    }

    func testFallsBackToTaskTextWhenTheIndexMoved() throws {
        // A regenerate between the render and the click shifts the array, so a stale
        // index must never resolve whatever now sits at that position.
        let url = summaryURL()
        try write(MeetingSummary(title: "s", actions: [
            MeetingSummary.ActionItem(task: "Newly extracted thing"),
            MeetingSummary.ActionItem(task: "Send the deck"),
        ]), to: url)

        XCTAssertTrue(MeetingLibraryService.setActionResolved(
            summaryURL: url, actionIndex: 0, taskText: "Send the deck", resolved: true
        ))

        let reloaded = try XCTUnwrap(MeetingSummary.load(from: url))
        XCTAssertFalse(reloaded.actions[0].resolved, "the stale index must not close the wrong row")
        XCTAssertTrue(reloaded.actions[1].resolved)
    }

    func testReopenFallsBackToTheFirstResolvedTextMatch() throws {
        // Same guard in the other direction: the fallback looks for a row in the
        // opposite state, so reopening skips the ones that are already open.
        let url = summaryURL()
        try write(MeetingSummary(title: "s", actions: [
            MeetingSummary.ActionItem(task: "Send the deck"),
            MeetingSummary.ActionItem(task: "Send the deck", resolved: true),
        ]), to: url)

        XCTAssertTrue(MeetingLibraryService.setActionResolved(
            summaryURL: url, actionIndex: 7, taskText: "Send the deck", resolved: false
        ))

        let reloaded = try XCTUnwrap(MeetingSummary.load(from: url))
        XCTAssertFalse(reloaded.actions[1].resolved, "the resolved twin is the one to reopen")
    }

    func testCapturedIndexWinsOverAnEarlierTextMatch() throws {
        // Two rows with the same wording: the click was on the second, so the second
        // is what closes, not the first one the text search would find.
        let url = summaryURL()
        try write(MeetingSummary(title: "s", actions: [
            MeetingSummary.ActionItem(task: "Send the deck"),
            MeetingSummary.ActionItem(task: "Send the deck"),
        ]), to: url)

        XCTAssertTrue(MeetingLibraryService.setActionResolved(
            summaryURL: url, actionIndex: 1, taskText: "Send the deck", resolved: true
        ))

        let reloaded = try XCTUnwrap(MeetingSummary.load(from: url))
        XCTAssertFalse(reloaded.actions[0].resolved)
        XCTAssertTrue(reloaded.actions[1].resolved)
    }

    func testAlreadyInTheRequestedStateIsANoOp() throws {
        let url = summaryURL()
        var summary = fullSummary()
        summary.actions[0].resolved = true
        try write(summary, to: url)
        let before = try Data(contentsOf: url)

        XCTAssertFalse(MeetingLibraryService.setActionResolved(
            summaryURL: url, actionIndex: 0, taskText: "Send the deck", resolved: true
        ))
        XCTAssertEqual(try Data(contentsOf: url), before, "a no-op must not rewrite the file")
    }

    func testUnknownTaskAndMissingFileAreNoOps() throws {
        let url = summaryURL()
        try write(fullSummary(), to: url)

        XCTAssertFalse(MeetingLibraryService.setActionResolved(
            summaryURL: url, actionIndex: 0, taskText: "Never said this", resolved: true
        ))
        XCTAssertFalse(MeetingLibraryService.setActionResolved(
            summaryURL: dir.appendingPathComponent("gone.summary.json"),
            actionIndex: 0, taskText: "Send the deck", resolved: true
        ))
    }

    /// Both events, in the existing `library` category, snake_case, naming the
    /// meeting whose file actually changed.
    func testEmitsResolvedAndReopenedEvents() throws {
        let logs = dir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        setenv("MEETINGPIPE_LOGS_DIR", logs.path, 1)
        defer { unsetenv("MEETINGPIPE_LOGS_DIR") }

        let url = summaryURL("20270102-090000")
        try write(fullSummary(), to: url)
        MeetingLibraryService.setActionResolved(
            summaryURL: url, actionIndex: 0, taskText: "Send the deck", resolved: true
        )
        MeetingLibraryService.setActionResolved(
            summaryURL: url, actionIndex: 0, taskText: "Send the deck", resolved: false
        )

        let lines = try String(contentsOf: logs.appendingPathComponent("events.jsonl"), encoding: .utf8)
            .split(separator: "\n")
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        let rows = lines.filter { $0["category"] as? String == "library" }
        XCTAssertEqual(rows.map { $0["action"] as? String }, ["action_resolved", "action_reopened"])
        XCTAssertEqual(rows.map { $0["stem"] as? String }, ["20270102-090000", "20270102-090000"])
    }

    // MARK: - The renderer

    /// The row index is what the writer is called with, so it has to be the position
    /// in `summary.actions`, not the position in the rendered list. An action with an
    /// empty task is dropped from the render (it always was) and an AI10 digest
    /// splits the list into runs, both of which shift those two apart.
    func testActionRowsCarryTheirIndexIntoTheSummary() {
        let summary = MeetingSummary(actions: [
            MeetingSummary.ActionItem(task: "First", group: "Client work"),
            MeetingSummary.ActionItem(task: "", group: "Client work"),
            MeetingSummary.ActionItem(task: "Second", group: "Internal"),
            MeetingSummary.ActionItem(task: "Third", group: "Internal"),
        ])
        let runs = SummaryRenderedView(summary: summary).actionRuns

        XCTAssertEqual(runs.map(\.group), ["Client work", "Internal"])
        let rows = runs.flatMap(\.actions)
        XCTAssertEqual(rows.map(\.task), ["First", "Second", "Third"])
        XCTAssertEqual(rows.map(\.index), [0, 2, 3], "the empty row still occupies index 1 on disk")
    }

    // MARK: - UX75: the flattened row sequence

    /// The reported digest's shape: four groups, one of them a single row, the
    /// rest with several. Every group after the first drew its heading and then
    /// reserved its rows' height and nothing else, because the container was
    /// handed one compound subtree per run rather than one child per row.
    ///
    /// What is pinned here is the sequence the container is handed: every action
    /// from every run, in the writer's order, with each run's heading immediately
    /// before the rows it heads. A unit test cannot prove SwiftUI then realizes
    /// and draws them; that is what the owner walkthrough is for.
    private func reportedDigestSummary() -> MeetingSummary {
        MeetingSummary(actions: [
            MeetingSummary.ActionItem(task: "General one", group: "General"),
            MeetingSummary.ActionItem(task: "General two", group: "General"),
            MeetingSummary.ActionItem(task: "Personal one", group: "Personal"),
            MeetingSummary.ActionItem(task: "Personal two", group: "Personal"),
            MeetingSummary.ActionItem(task: "Standup one", group: "Team Standup: Portal Updates"),
            MeetingSummary.ActionItem(task: "Client one", group: "Client work"),
            MeetingSummary.ActionItem(task: "Client two", group: "Client work"),
        ])
    }

    /// Describes a flattened row as a comparable string, so a failure names what
    /// the sequence actually was rather than dumping an enum.
    private func describe(_ rows: [SummaryRenderedView.ActionListRow]) -> [String] {
        rows.map { row in
            switch row {
            case .groupHeader(let name, _): return "# \(name)"
            case .action(let a): return a.task
            }
        }
    }

    func testTheFlattenedListInterleavesEveryHeadingWithItsOwnRows() {
        let rows = SummaryRenderedView(summary: reportedDigestSummary()).actionListRows

        XCTAssertEqual(describe(rows), [
            "# General", "General one", "General two",
            "# Personal", "Personal one", "Personal two",
            "# Team Standup: Portal Updates", "Standup one",
            "# Client work", "Client one", "Client two",
        ], "the container has to be handed one child per row, in the writer's order")
    }

    /// The whole defect in one assertion: the runs after the first contribute
    /// their rows, not just their headings.
    func testEveryRunAfterTheFirstContributesItsRows() {
        let rows = SummaryRenderedView(summary: reportedDigestSummary()).actionListRows
        let tasks = rows.compactMap { row -> String? in
            if case .action(let a) = row { return a.task }
            return nil
        }

        XCTAssertEqual(tasks.count, 7, "the screenshot showed 2 of 7: only the first group's rows drew")
    }

    /// UX26's correctness clause carried through the flatten. The index is the
    /// position in `summary.actions`, which is what the toggle writes back
    /// through, so an off-by-one here resolves somebody else's commitment. The
    /// empty-task row is dropped from the render and still occupies its index on
    /// disk, and the headings must not consume one.
    func testFlattenedRowsKeepTheirIndexIntoTheSummaryAcrossEveryRun() {
        let summary = MeetingSummary(actions: [
            MeetingSummary.ActionItem(task: "First", group: "Client work"),
            MeetingSummary.ActionItem(task: "", group: "Client work"),
            MeetingSummary.ActionItem(task: "Second", group: "Internal"),
            MeetingSummary.ActionItem(task: "Third", group: "Internal"),
        ])
        let rows = SummaryRenderedView(summary: summary).actionListRows

        XCTAssertEqual(describe(rows), ["# Client work", "First", "# Internal", "Second", "Third"])
        let actions = rows.compactMap { row -> ActionItemRow.Action? in
            if case .action(let a) = row { return a }
            return nil
        }
        XCTAssertEqual(actions.map(\.index), [0, 2, 3], "the empty row still occupies index 1 on disk")
        XCTAssertEqual(
            actions.map(\.index),
            SummaryRenderedView(summary: summary).actionRuns.flatMap(\.actions).map(\.index),
            "the flatten must carry `actionRuns`' mapping unchanged, not re-derive it"
        )
    }

    /// Walkthrough step 4: a meeting's own summary is one run with a nil group and
    /// must keep rendering as the flat list it always was. This is the case the
    /// flattening could plausibly break by inventing an empty heading.
    func testAMeetingsOwnSummaryFlattensToRowsWithNoHeading() {
        let summary = MeetingSummary(actions: [
            MeetingSummary.ActionItem(task: "Send the deck"),
            MeetingSummary.ActionItem(task: "Book the room"),
        ])
        let rows = SummaryRenderedView(summary: summary).actionListRows

        XCTAssertEqual(describe(rows), ["Send the deck", "Book the room"])
        XCTAssertFalse(rows.contains { if case .groupHeader = $0 { return true } else { return false } },
                       "a nil group must not produce a heading row, empty or otherwise")
    }

    /// An empty-string group is folded to nil by `actionRuns`, so it must not
    /// produce a blank heading either.
    func testAnEmptyGroupNameProducesNoHeading() {
        let summary = MeetingSummary(actions: [
            MeetingSummary.ActionItem(task: "Send the deck", group: ""),
        ])

        XCTAssertEqual(describe(SummaryRenderedView(summary: summary).actionListRows), ["Send the deck"])
    }

    /// `ForEach` needs unique ids, and `actionRuns` splits into runs rather than
    /// buckets, so `A, B, A` legitimately yields two headings reading `A`. Naming
    /// a heading by its text would collide there; naming it by the index of the
    /// first row it heads does not.
    func testRowIdentitiesAreUniqueEvenWhenTwoRunsShareAGroupName() {
        let summary = MeetingSummary(actions: [
            MeetingSummary.ActionItem(task: "First", group: "Client work"),
            MeetingSummary.ActionItem(task: "Second", group: "Internal"),
            MeetingSummary.ActionItem(task: "Third", group: "Client work"),
        ])
        let rows = SummaryRenderedView(summary: summary).actionListRows

        XCTAssertEqual(describe(rows), ["# Client work", "First", "# Internal", "Second", "# Client work", "Third"])
        let ids = rows.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate ids make ForEach drop or reuse rows: \(ids)")
    }

    /// The empty case still renders nothing, since `body` gates the whole section
    /// on this list now rather than on `actionRuns`.
    func testNoActionsFlattensToNoRows() {
        XCTAssertTrue(SummaryRenderedView(summary: MeetingSummary()).actionListRows.isEmpty)
        XCTAssertTrue(SummaryRenderedView(summary: MeetingSummary(actions: [
            MeetingSummary.ActionItem(task: "", group: "General"),
        ])).actionListRows.isEmpty, "a run left with no rows must not leave its heading behind")
    }

    func testActionRowsCarryTheResolvedFlag() {
        let summary = MeetingSummary(actions: [
            MeetingSummary.ActionItem(task: "Open one"),
            MeetingSummary.ActionItem(task: "Closed one", resolved: true),
        ])
        let rows = SummaryRenderedView(summary: summary).actionRuns.flatMap(\.actions)

        XCTAssertEqual(rows.map(\.resolved), [false, true], "the reader used to drop this flag")
    }

    func testToggleCallbackReceivesTheSummaryIndexAndTheRequestedState() {
        var seen: [(Int, Bool)] = []
        let summary = MeetingSummary(actions: [
            MeetingSummary.ActionItem(task: ""),
            MeetingSummary.ActionItem(task: "Send the deck"),
        ])
        let view = SummaryRenderedView(summary: summary) { index, resolved in
            seen.append((index, resolved))
        }
        let row = view.actionRuns.flatMap(\.actions)[0]

        view.onToggleAction?(row.index, !row.resolved)

        XCTAssertEqual(seen.map(\.0), [1])
        XCTAssertEqual(seen.map(\.1), [true])
    }

    func testAReaderWithNoWritableSummaryGetsNoToggle() {
        // The digest reader and the A16 compare pane construct it this way; the
        // default has to stay the static render they have always had.
        XCTAssertNil(SummaryRenderedView(summary: MeetingSummary()).onToggleAction)

        let row = ActionItemRow(action: .init(index: 0, task: "Send the deck", owner: "", due: "", confidence: "medium"))
        XCTAssertFalse(row.isInteractive)
        XCTAssertNotNil(row.body)
    }

    /// State rides on the glyph and the strikethrough, never on colour alone: the
    /// symbol changes shape (open circle to filled checkmark) and the task text is
    /// struck. The strikethrough itself is a render-time modifier and T2 deliberately
    /// removed image snapshots, so what is pinned here is the state the render reads.
    func testResolvedRowSwapsTheGlyphAndSpeaksTheOppositeAction() {
        let open = ActionItemRow(
            action: .init(index: 0, task: "Send the deck", owner: "", due: "", confidence: "medium"),
            onToggle: { _ in }
        )
        let done = ActionItemRow(
            action: .init(index: 0, task: "Send the deck", owner: "", due: "", confidence: "medium", resolved: true),
            onToggle: { _ in }
        )

        XCTAssertEqual(open.glyphName, "circle")
        XCTAssertEqual(done.glyphName, "checkmark.circle.fill")
        XCTAssertEqual(open.toggleLabel, "Mark done: Send the deck")
        XCTAssertEqual(done.toggleLabel, "Reopen: Send the deck")
        XCTAssertTrue(open.isInteractive)
        XCTAssertNotNil(open.body)
        XCTAssertNotNil(done.body)
    }

    func testTheToggleAsksForTheOppositeState() {
        var requested: [Bool] = []
        let open = ActionItemRow(
            action: .init(index: 0, task: "t", owner: "", due: "", confidence: "medium"),
            onToggle: { requested.append($0) }
        )
        let done = ActionItemRow(
            action: .init(index: 0, task: "t", owner: "", due: "", confidence: "medium", resolved: true),
            onToggle: { requested.append($0) }
        )

        open.onToggle?(!open.action.resolved)
        done.onToggle?(!done.action.resolved)

        XCTAssertEqual(requested, [true, false])
    }
}
