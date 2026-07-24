import XCTest
@testable import MeetingPipe

/// AI7's commitments loop: the grouping that turns a recurring series' restatements
/// into one commitment, the aging that drives the rail's amber overdue badge, and
/// the resolve-the-cluster write. Every case here exists because the failure mode is
/// either a commitment silently resolved that the owner never finished, or an
/// overdue promise that never resurfaces.
final class FactsClusterTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15 UTC-ish

    private func day(_ offset: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: offset, to: now)!
    }

    private func isoDay(_ offset: Int) -> String {
        FactsDate.dayParser.string(from: day(offset))
    }

    private func action(
        stem: String,
        task: String,
        due: String? = nil,
        owner: String? = nil,
        daysAgo: Int = 0,
        index: Int = 0,
        dir: URL = URL(fileURLWithPath: "/tmp/raw")
    ) -> OpenActionFact {
        OpenActionFact(
            stem: stem,
            summaryURL: dir.appendingPathComponent("\(stem).summary.json"),
            meetingTitle: "Standup",
            meetingDate: day(-daysAgo),
            actionIndex: index,
            task: task,
            owner: owner,
            due: due
        )
    }

    // MARK: - Grouping

    func testUnassignedActionsEachBecomeTheirOwnCluster() {
        let actions = [
            action(stem: "20270101-100000", task: "Send the deck"),
            action(stem: "20270108-100000", task: "Send the deck"),
        ]
        let clusters = ActionClusterBuilder.group(actions)

        XCTAssertEqual(clusters.count, 2, "no assignment means DV1's flat list, not a merge")
        XCTAssertTrue(clusters.allSatisfy { $0.count == 1 })
    }

    func testAssignedRestatementsMergeAndTheNewestRepresents() throws {
        let first = action(stem: "20270101-100000", task: "Send the deck", daysAgo: 14)
        let latest = action(stem: "20270108-100000", task: "Send the deck", daysAgo: 7)
        let other = action(stem: "20270109-100000", task: "Book the venue", daysAgo: 6)
        let assignments = [
            first.clusterKey: 0,
            latest.clusterKey: 0,
            other.clusterKey: 1,
        ]

        let clusters = ActionClusterBuilder.group([first, latest, other], assignments: assignments)

        XCTAssertEqual(clusters.count, 2)
        let merged = try XCTUnwrap(clusters.first { $0.count == 2 })
        XCTAssertEqual(merged.representative.stem, "20270108-100000",
                       "the latest restatement is the wording the series last used")
        XCTAssertEqual(merged.instances.map(\.stem),
                       ["20270108-100000", "20270101-100000"],
                       "instances run newest first")
    }

    func testDistinctStemsWithTheSameTaskGetDistinctClusterKeys() {
        let a = action(stem: "20270101-100000", task: "Send the deck")
        let b = action(stem: "20270108-100000", task: "Send the deck")
        XCTAssertNotEqual(a.clusterKey, b.clusterKey)
    }

    func testDatedCommitmentsSortAheadOfUndatedOnesSoonestFirst() {
        let late = action(stem: "20270101-100000", task: "A", due: isoDay(9))
        let soon = action(stem: "20270102-100000", task: "B", due: isoDay(2))
        let undated = action(stem: "20270103-100000", task: "C")

        let clusters = ActionClusterBuilder.group([late, undated, soon])

        XCTAssertEqual(clusters.map(\.representative.task), ["B", "A", "C"])
    }

    // MARK: - Cluster deadline

    func testClusterUsesTheRepresentativesDue() {
        let old = action(stem: "20270101-100000", task: "Ship it", due: isoDay(1), daysAgo: 14)
        let latest = action(stem: "20270108-100000", task: "Ship it", due: isoDay(5), daysAgo: 7)
        let clusters = ActionClusterBuilder.group(
            [old, latest], assignments: [old.clusterKey: 0, latest.clusterKey: 0]
        )

        XCTAssertEqual(clusters.first?.due, isoDay(5))
    }

    func testClusterFallsBackToTheEarliestMemberDueWhenTheLatestDroppedIt() {
        // A series that restates a commitment without repeating the deadline has not
        // dropped the deadline; forgetting it here would silently un-age the action.
        let dated = action(stem: "20270101-100000", task: "Ship it", due: isoDay(-3), daysAgo: 14)
        let alsoDated = action(stem: "20270104-100000", task: "Ship it", due: isoDay(4), daysAgo: 11)
        let latest = action(stem: "20270108-100000", task: "Ship it", daysAgo: 7)
        let clusters = ActionClusterBuilder.group(
            [dated, alsoDated, latest],
            assignments: [dated.clusterKey: 0, alsoDated.clusterKey: 0, latest.clusterKey: 0]
        )

        XCTAssertEqual(clusters.first?.due, isoDay(-3))
        XCTAssertEqual(clusters.first?.agingLabel(now: now)?.text, "3d overdue")
    }

    // MARK: - Aging + the rail badge

    func testAgingLabelWording() {
        func label(_ offset: Int) -> (text: String, overdue: Bool)? {
            ActionClusterBuilder
                .group([action(stem: "20270101-100000", task: "A", due: isoDay(offset))])
                .first?
                .agingLabel(now: now)
        }

        XCTAssertEqual(label(-2)?.text, "2d overdue")
        XCTAssertEqual(label(-2)?.overdue, true)
        XCTAssertEqual(label(0)?.text, "due today")
        XCTAssertEqual(label(0)?.overdue, true, "due today claims attention like an overdue item")
        XCTAssertEqual(label(3)?.text, "in 3d")
        XCTAssertEqual(label(3)?.overdue, false)
    }

    func testUndatedCommitmentIsNeverOverdue() {
        let clusters = ActionClusterBuilder.group([action(stem: "20270101-100000", task: "A")])
        XCTAssertNil(clusters.first?.agingLabel(now: now))
        XCTAssertFalse(clusters.first!.isOverdue(now: now))
    }

    func testOverdueCountCountsCommitmentsNotRestatements() {
        // The whole point of AI7's badge: a promise restated five times is one thing
        // that is late, not five.
        let instances = (0..<5).map {
            action(stem: "2027010\($0)-100000", task: "Ship it", due: isoDay(-4), daysAgo: 20 - $0)
        }
        let unrelated = action(stem: "20270120-100000", task: "Other", due: isoDay(-1))
        let future = action(stem: "20270121-100000", task: "Later", due: isoDay(6))

        var assignments: [String: Int] = [:]
        for i in instances { assignments[i.clusterKey] = 0 }

        let clusters = ActionClusterBuilder.group(
            instances + [unrelated, future], assignments: assignments
        )
        XCTAssertEqual(ActionClusterBuilder.overdueCount(clusters, now: now), 2)
    }

    // MARK: - Pipeline assignment decoding

    func testAssignmentsDropUnclusteredRowsAndTrimTasks() {
        let rows = [
            ActionClusterAssignment(stem: "a", task: "  Send the deck  ", cluster: 3),
            ActionClusterAssignment(stem: "b", task: "Book the venue", cluster: nil),
            ActionClusterAssignment(stem: "c", task: "   ", cluster: 4),
        ]
        let map = ActionClusterBuilder.assignments(from: rows)

        XCTAssertEqual(map[OpenActionFact.clusterKey(stem: "a", task: "Send the deck")], 3,
                       "the loader trims task text, so the key must be trimmed too")
        XCTAssertNil(map[OpenActionFact.clusterKey(stem: "b", task: "Book the venue")],
                     "an unclustered row falls through to the singleton path")
        XCTAssertEqual(map.count, 1)
    }

    func testAssignmentDecodesThePipelinePayload() throws {
        // Exactly the shape `mp actions --cluster --out` writes, extra keys included:
        // the daemon must ignore what it does not need rather than fail to decode.
        let json = """
        [
          {"stem": "20270101-100000", "title": "Standup", "task": "Send the deck",
           "owner": null, "due": "2027-01-20", "confidence": "medium", "resolved": false,
           "age_days": -5, "overdue": false, "workflow": "Standup", "cluster": 0},
          {"stem": "20270108-100000", "title": "Standup", "task": "Send the deck",
           "owner": null, "due": null, "confidence": "medium", "resolved": false,
           "age_days": null, "overdue": false, "workflow": null, "cluster": null}
        ]
        """
        let rows = try JSONDecoder().decode(
            [ActionClusterAssignment].self, from: Data(json.utf8)
        )

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].cluster, 0)
        XCTAssertNil(rows[1].cluster)
    }

    // MARK: - Resolve the cluster

    func testResolveMarksEveryRestatementDoneAcrossMeetings() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai7-resolve-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        func write(_ stem: String, _ tasks: [String]) throws {
            let summary = MeetingSummary(
                title: stem, actions: tasks.map { MeetingSummary.ActionItem(task: $0) }
            )
            let data = try JSONSerialization.data(withJSONObject: summary.jsonObject())
            try data.write(to: dir.appendingPathComponent("\(stem).summary.json"))
        }
        try write("20270101-100000", ["Send the deck", "Unrelated thing"])
        try write("20270108-100000", ["Send the deck"])

        let first = action(stem: "20270101-100000", task: "Send the deck", daysAgo: 14, dir: dir)
        let latest = action(stem: "20270108-100000", task: "Send the deck", daysAgo: 7, dir: dir)
        let cluster = ActionClusterBuilder.group(
            [first, latest], assignments: [first.clusterKey: 0, latest.clusterKey: 0]
        )[0]

        XCTAssertEqual(FactsResolver.resolve(cluster), 2)

        let a = try XCTUnwrap(MeetingSummary.load(
            from: dir.appendingPathComponent("20270101-100000.summary.json")))
        XCTAssertTrue(a.actions[0].resolved, "the restatement in the older meeting is closed too")
        XCTAssertFalse(a.actions[1].resolved, "an unrelated action in the same file is untouched")

        let b = try XCTUnwrap(MeetingSummary.load(
            from: dir.appendingPathComponent("20270108-100000.summary.json")))
        XCTAssertTrue(b.actions[0].resolved)
    }

    func testResolveFallsBackToTaskTextWhenTheIndexMoved() throws {
        // The summary can be re-generated between the Facts load and the click, so a
        // stale index must never resolve whatever now sits at that position.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai7-resolve-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let summary = MeetingSummary(title: "s", actions: [
            MeetingSummary.ActionItem(task: "Newly extracted thing"),
            MeetingSummary.ActionItem(task: "Send the deck"),
        ])
        let url = dir.appendingPathComponent("20270101-100000.summary.json")
        try JSONSerialization.data(withJSONObject: summary.jsonObject()).write(to: url)

        let stale = action(stem: "20270101-100000", task: "Send the deck", index: 0, dir: dir)
        XCTAssertEqual(FactsResolver.resolve(ActionClusterBuilder.group([stale])[0]), 1)

        let reloaded = try XCTUnwrap(MeetingSummary.load(from: url))
        XCTAssertFalse(reloaded.actions[0].resolved, "the stale index must not close the wrong row")
        XCTAssertTrue(reloaded.actions[1].resolved)
    }

    func testResolveIsANoOpWhenTheSummaryIsGone() {
        let missing = action(
            stem: "20270101-100000", task: "Send the deck",
            dir: URL(fileURLWithPath: "/tmp/ai7-does-not-exist-\(UUID().uuidString)")
        )
        XCTAssertEqual(FactsResolver.resolve(ActionClusterBuilder.group([missing])[0]), 0)
    }

    // MARK: - Rail wiring

    func testFactsScopeCarriesTheOverdueCount() {
        let counts = ScopeCounts.zero.with(factsOverdue: 4)

        XCTAssertEqual(counts.count(for: .facts), 4)
        XCTAssertEqual(counts.count(for: .ask), 0, "Ask and Digests stay uncounted views")
        XCTAssertEqual(counts.count(for: .digests), 0)
        XCTAssertEqual(ScopeCounts.zero.count(for: .facts), 0, "nothing overdue, no badge")
    }

    func testAttentionPillIsSpokenNotJustNumbered() {
        XCTAssertEqual(ScopeAttentionLabel.text(scope: .facts, count: 1), "1 action overdue")
        XCTAssertEqual(ScopeAttentionLabel.text(scope: .facts, count: 3), "3 actions overdue")
        XCTAssertEqual(ScopeAttentionLabel.text(scope: .needsYou, count: 1), "1 meeting needs you")
        XCTAssertEqual(ScopeAttentionLabel.text(scope: .needsYou, count: 2), "2 meetings need you")
    }
}
