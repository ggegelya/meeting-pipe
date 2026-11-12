import XCTest
import os
@testable import MeetingPipe

/// PERF13 items 1 and 2: the People rail's derivation ran on main (146 samples in the
/// 2026-10-23 rail-switch trace) and both rails computed each commitment's "due" label in a
/// row's `body` (81 samples under `OpenActionRow.body`). These pin the derivation off main,
/// latest wins, and the labels computed once per derivation and refreshed on a new day.
@MainActor
final class LibraryRailsPERF13Tests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func day(_ offset: Int, from base: Date? = nil) -> Date {
        Calendar.current.date(byAdding: .day, value: offset, to: base ?? now)!
    }

    private func cluster(_ stem: String, dueIn: Int?, owner: String? = nil) -> ActionCluster {
        ActionCluster(instances: [OpenActionFact(
            stem: stem,
            summaryURL: URL(fileURLWithPath: "/tmp/raw/\(stem).summary.json"),
            meetingTitle: "Standup",
            meetingDate: now,
            actionIndex: 0,
            task: "Task \(stem)",
            owner: owner,
            due: dueIn.map { FactsDate.dayParser.string(from: day($0)) }
        )])
    }

    // MARK: - Item 2: aging labels once per derivation

    func test_the_snapshot_carries_every_dated_commitments_label() {
        let clusters = [cluster("a", dueIn: -3), cluster("b", dueIn: 0), cluster("c", dueIn: 2), cluster("d", dueIn: nil)]
        var snapshot = FactsSnapshot.empty
        snapshot.setClusters(clusters, now: now)
        for c in clusters {
            XCTAssertEqual(snapshot.aging.label(for: c), c.agingLabel(now: now), c.id)
        }
        XCTAssertEqual(snapshot.aging.label(for: clusters[0])?.text, "3d overdue")
        XCTAssertNil(snapshot.aging.label(for: clusters[3]))
        XCTAssertEqual(snapshot.overdueCount, 2, "the badge counts the amber labels: overdue and due today")
    }

    func test_a_new_day_refreshes_the_labels_and_the_badge() {
        let dueToday = cluster("a", dueIn: 0)
        var snapshot = FactsSnapshot.empty
        snapshot.setClusters([dueToday], now: now)
        let sameDay = snapshot
        snapshot.refreshAging(now: now.addingTimeInterval(60))
        XCTAssertEqual(snapshot, sameDay, "a refresh on the same day is a no-op")

        snapshot.refreshAging(now: day(1))
        XCTAssertEqual(snapshot.aging.label(for: dueToday)?.text, "1d overdue")
        XCTAssertTrue(snapshot.aging.isCurrent(now: day(1)))
        XCTAssertEqual(snapshot.overdueCount, 1)
    }

    func test_removing_a_commitment_recomputes_the_badge() {
        let a = cluster("a", dueIn: -1), b = cluster("b", dueIn: -2)
        var snapshot = FactsSnapshot.empty
        snapshot.setClusters([a, b], now: now)
        snapshot.setClusters(snapshot.clusters.filter { $0.id != a.id }, now: now)
        XCTAssertEqual(snapshot.overdueCount, 1)
        XCTAssertNil(snapshot.aging.label(for: a))
    }

    /// The fence: neither rail's view computes a label itself.
    func test_no_rail_view_computes_an_aging_label() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MeetingPipe")
        for file in ["FactsView.swift", "PeopleView.swift"] {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            XCTAssertFalse(text.contains("agingLabel("), "\(file) computes an aging label in a view")
        }
    }

    // MARK: - Item 1: the People derivation off main

    func test_the_people_derivation_runs_off_main() async {
        let onMain = OSAllocatedUnfairLock(initialState: [Bool]())
        let projection = PeopleProjection(
            loader: { _, cache in PeopleLoader.Pass(cache: cache) },
            deriver: { roster, meetings, commitments in
                onMain.withLock { $0.append(pthread_main_np() != 0) }
                return PeopleRail.derive(roster: roster, meetings: meetings, commitments: commitments)
            }
        )
        var landed: [PeopleRail.Person] = []
        let roster = [RosterProfile.Person(name: "Alice", sampleCount: 3)]
        let meeting = PeopleRail.MeetingFacts(stem: "m1", title: "Standup", date: now, people: ["alice"])
        await projection.derive(
            roster: roster, meetings: [meeting], commitments: [cluster("a", dueIn: 1, owner: "Alice")]
        ) { landed = $0 }.value
        XCTAssertEqual(onMain.withLock { $0 }, [false], "PeopleRail.derive must not run on main")
        XCTAssertEqual(landed.map(\.name), ["Alice"])
        XCTAssertEqual(landed.first?.meetings.map(\.stem), ["m1"])
        XCTAssertEqual(landed.first?.actions.count, 1)
    }

    /// Latest wins is `ProjectionPass`'s own property (pinned by PERF23's suite with a held
    /// pass); this pins only that two derivations started back to back deliver the second.
    func test_back_to_back_derivations_deliver_the_newer() async {
        let projection = PeopleProjection(loader: { _, cache in PeopleLoader.Pass(cache: cache) })
        var landed: [String] = []
        let older = projection.derive(
            roster: [RosterProfile.Person(name: "Old", sampleCount: 1)], meetings: [], commitments: []
        ) { landed = $0.map(\.name) }
        let newer = projection.derive(
            roster: [RosterProfile.Person(name: "New", sampleCount: 1)], meetings: [], commitments: []
        ) { landed = $0.map(\.name) }
        await older.value
        await newer.value
        XCTAssertEqual(landed, ["New"])
    }
}
