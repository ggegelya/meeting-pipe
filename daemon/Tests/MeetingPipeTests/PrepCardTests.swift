import XCTest
@testable import MeetingPipe

/// CAL2. Two surfaces under test: the pure projection (`PrepCard.make`), which
/// decides whether there is anything worth showing at all, and the disk scan
/// (`PrepCardStore.scan`), which decides which meeting the card is about. The
/// view's geometry is checked against its own metrics so the panel can never
/// animate to a frame the content does not fill.
final class PrepCardTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prepcard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Fixtures

    private func write(stem: String, workflowID: String?, workflowName: String?,
                       summary: [String: Any]?) throws {
        var meta: [String: Any] = ["source_bundle_id": "com.microsoft.teams2"]
        if let workflowID { meta["workflow_id"] = workflowID }
        if let workflowName { meta["workflow_name"] = workflowName }
        try JSONSerialization.data(withJSONObject: meta)
            .write(to: dir.appendingPathComponent("\(stem).meta.json"))
        if let summary {
            try JSONSerialization.data(withJSONObject: summary)
                .write(to: dir.appendingPathComponent("\(stem).summary.json"))
        }
    }

    private func summary(title: String, points: [String], decisions: [String] = [],
                         actions: [[String: Any]] = []) -> [String: Any] {
        ["title": title, "summary": points, "decisions": decisions, "actions": actions]
    }

    private func decoded(_ object: [String: Any]) throws -> MeetingSummary {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(MeetingSummary.self, from: data)
    }

    private let started = Date(timeIntervalSince1970: 1_784_000_000)

    // MARK: - Projection

    func test_make_caps_points_and_actions_and_counts_the_rest() throws {
        let model = try decoded(summary(
            title: "Weekly sync",
            points: ["one", "two", "three", "four"],
            actions: [
                ["task": "Send SOW", "owner": "Georgy", "due": "2026-07-25"],
                ["task": "Book room"],
                ["task": "Draft plan"],
                ["task": "Chase invoice"],
                ["task": "Already done", "resolved": true],
                ["task": "Legacy done", "done": true],
                ["task": "   "],
            ]
        ))
        let card = try XCTUnwrap(PrepCard.make(
            workflowName: "Client work", stem: "20260720-143000",
            startedAt: started, summary: model
        ))
        XCTAssertEqual(card.title, "Weekly sync")
        XCTAssertEqual(card.points, ["one", "two", "three"])
        XCTAssertEqual(card.actions.map(\.task), ["Send SOW", "Book room", "Draft plan"])
        XCTAssertEqual(card.actions[0].owner, "Georgy")
        XCTAssertEqual(card.actions[0].due, "2026-07-25")
        XCTAssertNil(card.actions[1].owner)
        // Resolved, legacy-done and blank rows are not open actions, so 1 remains.
        XCTAssertEqual(card.moreActions, 1)
    }

    func test_make_falls_back_to_decisions_when_the_recap_is_empty() throws {
        let model = try decoded(summary(title: "Design call", points: [],
                                        decisions: ["Ship on Friday"]))
        let card = try XCTUnwrap(PrepCard.make(
            workflowName: "W", stem: "20260720-143000", startedAt: started, summary: model
        ))
        XCTAssertEqual(card.points, ["Ship on Friday"])
    }

    func test_make_is_nil_when_there_is_nothing_to_say() throws {
        let model = try decoded(summary(title: "Standup", points: [], decisions: [],
                                        actions: [["task": "Done", "resolved": true]]))
        XCTAssertNil(PrepCard.make(workflowName: "W", stem: "20260720-143000",
                                   startedAt: started, summary: model))
    }

    func test_make_falls_back_to_the_stem_when_the_summary_has_no_title() throws {
        let model = try decoded(["summary": ["only this"]])
        let card = try XCTUnwrap(PrepCard.make(
            workflowName: "W", stem: "20260720-143000", startedAt: started, summary: model
        ))
        XCTAssertEqual(card.title, "20260720-143000")
        XCTAssertTrue(card.actions.isEmpty)
    }

    // MARK: - Scan

    func test_scan_picks_the_newest_meeting_of_that_workflow() throws {
        let id = UUID().uuidString
        try write(stem: "20260701-090000", workflowID: id, workflowName: "Client work",
                  summary: summary(title: "Kickoff", points: ["old"]))
        try write(stem: "20260715-090000", workflowID: id, workflowName: "Client work",
                  summary: summary(title: "Review", points: ["new"]))
        try write(stem: "20260716-090000", workflowID: UUID().uuidString,
                  workflowName: "Personal", summary: summary(title: "Dentist", points: ["other"]))

        let card = try XCTUnwrap(PrepCardStore.scan(
            recordingsDir: dir, workflowID: id, workflowName: "Client work"
        ))
        XCTAssertEqual(card.stem, "20260715-090000")
        XCTAssertEqual(card.points, ["new"])
    }

    func test_scan_matches_by_id_across_a_rename() throws {
        let id = UUID().uuidString
        // Recorded under the old name; the workflow has since been renamed.
        try write(stem: "20260715-090000", workflowID: id, workflowName: "Old name",
                  summary: summary(title: "Review", points: ["still mine"]))
        let card = try XCTUnwrap(PrepCardStore.scan(
            recordingsDir: dir, workflowID: id, workflowName: "New name"
        ))
        XCTAssertEqual(card.points, ["still mine"])
        // And the card is labelled with the workflow you are about to record under.
        XCTAssertEqual(card.workflowName, "New name")
    }

    func test_scan_falls_back_to_the_name_when_the_sidecar_predates_workflow_id() throws {
        try write(stem: "20260715-090000", workflowID: nil, workflowName: "Client work",
                  summary: summary(title: "Review", points: ["legacy"]))
        let card = try XCTUnwrap(PrepCardStore.scan(
            recordingsDir: dir, workflowID: UUID().uuidString, workflowName: "Client work"
        ))
        XCTAssertEqual(card.points, ["legacy"])
    }

    func test_scan_falls_through_a_last_meeting_with_nothing_to_recap() throws {
        let id = UUID().uuidString
        try write(stem: "20260701-090000", workflowID: id, workflowName: "Client work",
                  summary: summary(title: "Kickoff", points: ["real content"]))
        try write(stem: "20260715-090000", workflowID: id, workflowName: "Client work",
                  summary: summary(title: "No speech", points: []))
        let card = try XCTUnwrap(PrepCardStore.scan(
            recordingsDir: dir, workflowID: id, workflowName: "Client work"
        ))
        XCTAssertEqual(card.stem, "20260701-090000")
    }

    func test_scan_skips_unsummarized_and_malformed_meetings() throws {
        let id = UUID().uuidString
        try write(stem: "20260716-090000", workflowID: id, workflowName: "Client work",
                  summary: nil)                                   // recorded, not yet summarized
        try "nope".write(to: dir.appendingPathComponent("20260717-090000.meta.json"),
                         atomically: true, encoding: .utf8)
        try "{}".write(to: dir.appendingPathComponent("20260717-090000.summary.json"),
                       atomically: true, encoding: .utf8)
        try write(stem: "not-a-stem", workflowID: id, workflowName: "Client work",
                  summary: summary(title: "Bad stem", points: ["ignored"]))
        XCTAssertNil(PrepCardStore.scan(recordingsDir: dir, workflowID: id,
                                        workflowName: "Client work"))
    }

    func test_scan_returns_nil_for_a_workflow_with_no_meetings() throws {
        try write(stem: "20260715-090000", workflowID: UUID().uuidString,
                  workflowName: "Client work", summary: summary(title: "Review", points: ["a"]))
        XCTAssertNil(PrepCardStore.scan(recordingsDir: dir, workflowID: UUID().uuidString,
                                        workflowName: "Personal"))
        XCTAssertNil(PrepCardStore.scan(recordingsDir: dir.appendingPathComponent("gone"),
                                        workflowID: UUID().uuidString, workflowName: "Any"))
    }

    // MARK: - Elapsed phrasing

    func test_elapsed_buckets() {
        let cal = Calendar(identifier: .gregorian)
        func at(_ y: Int, _ m: Int, _ d: Int) -> Date {
            cal.date(from: DateComponents(year: y, month: m, day: d, hour: 9))!
        }
        let meeting = at(2026, 7, 20)
        func bucket(_ now: Date) -> RelativeMeetingDateFormatter.Elapsed {
            RelativeMeetingDateFormatter.elapsed(for: meeting, now: now, calendar: cal)
        }
        XCTAssertEqual(bucket(at(2026, 7, 20)), .today)
        XCTAssertEqual(bucket(at(2026, 7, 21)), .yesterday)
        XCTAssertEqual(bucket(at(2026, 7, 23)), .days(3))
        XCTAssertEqual(bucket(at(2026, 8, 10)), .weeks(3))
        XCTAssertEqual(bucket(at(2026, 11, 20)), .months(4))
        // A stem in the future (clock skew) reads as today, never a negative gap.
        XCTAssertEqual(bucket(at(2026, 7, 19)), .today)
    }

    // MARK: - Card view geometry

    func test_card_height_grows_with_each_section() throws {
        let base = PrepCard(workflowName: "W", stem: "20260720-143000", startedAt: started,
                            title: "T", points: ["a"], actions: [], moreActions: 0)
        let withPoints = PrepCard(workflowName: "W", stem: "20260720-143000", startedAt: started,
                                  title: "T", points: ["a", "b"], actions: [], moreActions: 0)
        let withActions = PrepCard(
            workflowName: "W", stem: "20260720-143000", startedAt: started, title: "T",
            points: ["a"], actions: [PrepCard.Action(task: "x", owner: nil, due: nil)],
            moreActions: 0
        )
        let withMore = PrepCard(
            workflowName: "W", stem: "20260720-143000", startedAt: started, title: "T",
            points: ["a"], actions: [PrepCard.Action(task: "x", owner: nil, due: nil)],
            moreActions: 2
        )
        XCTAssertGreaterThan(PrepCardView.height(for: withPoints), PrepCardView.height(for: base))
        XCTAssertGreaterThan(PrepCardView.height(for: withActions), PrepCardView.height(for: base))
        XCTAssertGreaterThan(PrepCardView.height(for: withMore),
                             PrepCardView.height(for: withActions))
    }

    func test_card_height_covers_the_lowest_row() throws {
        let card = PrepCard(
            workflowName: "Client work", stem: "20260720-143000", startedAt: started,
            title: "Weekly sync", points: ["a", "b", "c"],
            actions: [PrepCard.Action(task: "x", owner: "Georgy", due: "2026-07-25"),
                      PrepCard.Action(task: "y", owner: nil, due: nil)],
            moreActions: 2
        )
        let layout = PrepCardView.layout(for: card)
        let lowest = layout.moreTop ?? layout.actionTops.last ?? layout.titleTop
        XCTAssertGreaterThan(layout.height, lowest,
                             "the card must be taller than the top of its last row")
        XCTAssertEqual(layout.pointTops.count, 3)
        XCTAssertEqual(layout.actionTops.count, 2)
        XCTAssertEqual(PrepCardView.height(for: card), layout.height)
    }

    func test_action_line_degrades_as_fields_go_missing() {
        XCTAssertEqual(
            PrepCardView.actionLine(PrepCard.Action(task: "Send SOW", owner: "Georgy",
                                                    due: "2026-07-25")),
            "Send SOW  ·  Georgy  ·  due 2026-07-25"
        )
        XCTAssertEqual(
            PrepCardView.actionLine(PrepCard.Action(task: "Send SOW", owner: nil,
                                                    due: "2026-07-25")),
            "Send SOW  ·  due 2026-07-25"
        )
        XCTAssertEqual(
            PrepCardView.actionLine(PrepCard.Action(task: "Send SOW", owner: nil, due: nil)),
            "Send SOW"
        )
    }
}
