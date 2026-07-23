import XCTest
@testable import MeetingPipe

/// DV3: the People projection. The rail's identity spine is the roster, and the
/// only link between a roster entry and a meeting is the resolved display name,
/// so these tests pin what counts as "this person's meeting" and what a rename
/// has to do to keep that link intact.
final class PeopleRailTests: XCTestCase {

    // MARK: - Builders

    private func person(_ name: String, samples: Int = 1) -> RosterProfile.Person {
        RosterProfile.Person(name: name, sampleCount: samples)
    }

    private func day(_ d: Int) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + Double(d) * 86_400)
    }

    private func meeting(
        _ stem: String,
        day dayOffset: Int,
        people: [String] = [],
        actions: [PeopleRail.OpenAction] = []
    ) -> PeopleRail.MeetingFacts {
        PeopleRail.MeetingFacts(
            stem: stem, title: "Meeting \(stem)", date: day(dayOffset),
            people: people, openActions: actions
        )
    }

    private func action(
        _ index: Int, _ task: String, owner: String?, due: String? = nil
    ) -> PeopleRail.OpenAction {
        PeopleRail.OpenAction(index: index, task: task, owner: owner, due: due)
    }

    private func overlay(labels: [String: String] = [:], segments: [Int: String] = [:])
        -> SpeakerLabelStore.Overlay {
        SpeakerLabelStore.Overlay(labels: labels, segments: segments)
    }

    // MARK: - derive

    func test_empty_roster_yields_no_rows() {
        // The rail is roster-shaped: with nobody enrolled there is no identity to
        // show, however many meetings exist. The view's empty state covers this.
        let rows = PeopleRail.derive(
            roster: [], meetings: [meeting("a", day: 0, people: ["Ivan"])]
        )
        XCTAssertTrue(rows.isEmpty)
    }

    func test_row_per_enrolled_person_in_roster_order() {
        let rows = PeopleRail.derive(
            roster: [person("Ivan"), person("Rana")],
            meetings: [meeting("a", day: 0, people: ["Ivan"])]
        )
        XCTAssertEqual(rows.map(\.name), ["Ivan", "Rana"])
        // Enrolled but never matched: a row with an honest zero, not an omission.
        XCTAssertTrue(rows[1].meetings.isEmpty)
        XCTAssertNil(rows[1].lastSeen)
    }

    func test_attendance_matches_case_and_whitespace_insensitively() {
        let rows = PeopleRail.derive(
            roster: [person("Ivan")],
            meetings: [meeting("a", day: 0, people: ["  ivan "])]
        )
        XCTAssertEqual(rows[0].meetings.map(\.stem), ["a"])
    }

    func test_a_different_name_never_matches() {
        // Guard against loosening this to substring / first-token matching: two
        // Ivans folding into one row is the wrong-name failure the roster's own
        // two-gate match rule exists to avoid.
        let rows = PeopleRail.derive(
            roster: [person("Ivan")],
            meetings: [meeting("a", day: 0, people: ["Ivanna", "Ivan Petrov", "THEM-A"])]
        )
        XCTAssertTrue(rows[0].meetings.isEmpty)
    }

    func test_owning_an_action_counts_as_being_in_the_meeting() {
        // The summarizer names owners the diarizer never labelled, so attendance
        // alone would hide a meeting whose action the rail is already showing.
        let rows = PeopleRail.derive(
            roster: [person("Ivan")],
            meetings: [meeting("a", day: 0, people: ["THEM-A"],
                               actions: [action(0, "ship it", owner: "Ivan")])]
        )
        XCTAssertEqual(rows[0].meetings.map(\.stem), ["a"])
        XCTAssertEqual(rows[0].actions.map(\.task), ["ship it"])
    }

    func test_a_meeting_is_listed_once_even_when_attended_and_owning() {
        let rows = PeopleRail.derive(
            roster: [person("Ivan")],
            meetings: [meeting("a", day: 0, people: ["Ivan"],
                               actions: [action(0, "x", owner: "Ivan"),
                                         action(1, "y", owner: "Ivan")])]
        )
        XCTAssertEqual(rows[0].meetings.count, 1)
        XCTAssertEqual(rows[0].actions.count, 2)
    }

    func test_meetings_are_newest_first_and_last_seen_is_the_newest() {
        let rows = PeopleRail.derive(
            roster: [person("Ivan")],
            meetings: [
                meeting("old", day: 0, people: ["Ivan"]),
                meeting("new", day: 5, people: ["Ivan"]),
                meeting("mid", day: 3, people: ["Ivan"]),
            ]
        )
        XCTAssertEqual(rows[0].meetings.map(\.stem), ["new", "mid", "old"])
        XCTAssertEqual(rows[0].lastSeen, day(5))
    }

    func test_open_actions_sort_soonest_due_first_then_undated() {
        let rows = PeopleRail.derive(
            roster: [person("Ivan")],
            meetings: [
                meeting("a", day: 0, actions: [action(0, "no date", owner: "Ivan")]),
                meeting("b", day: 1, actions: [action(0, "later", owner: "Ivan", due: "2026-09-01")]),
                meeting("c", day: 2, actions: [action(0, "sooner", owner: "Ivan", due: "2026-08-01T09:00:00")]),
            ]
        )
        XCTAssertEqual(rows[0].actions.map(\.task), ["sooner", "later", "no date"])
    }

    func test_unowned_actions_belong_to_nobody() {
        let rows = PeopleRail.derive(
            roster: [person("Ivan")],
            meetings: [meeting("a", day: 0, people: ["Ivan"],
                               actions: [action(0, "orphan", owner: nil)])]
        )
        XCTAssertTrue(rows[0].actions.isEmpty)
    }

    // MARK: - resolvedPeople

    func test_attendee_is_mapped_through_the_overlay_cluster_name() {
        // The summary was written before the in-app naming, so it still lists the
        // raw cluster; the overlay is what makes it a person.
        let names = PeopleRail.resolvedPeople(
            attendees: ["THEM-A", "speaker_unknown"],
            overlay: overlay(labels: ["THEM-A": "Ivan"])
        )
        XCTAssertEqual(names, ["Ivan", "speaker_unknown"])
    }

    func test_overlay_introduces_a_person_the_summary_never_listed() {
        // A per-segment "New person" exists only as an overlay value, so a scan of
        // the summary's attendees alone would never see them (the MeetingCast bug).
        let names = PeopleRail.resolvedPeople(
            attendees: ["THEM-A"],
            overlay: overlay(labels: ["THEM-B": "Rana"], segments: [7: "Anisha"])
        )
        XCTAssertEqual(Set(names), ["THEM-A", "Rana", "Anisha"])
    }

    func test_resolution_dedupes_by_identity() {
        let names = PeopleRail.resolvedPeople(
            attendees: ["Ivan", "ivan "],
            overlay: overlay(labels: ["THEM-A": "Ivan"])
        )
        XCTAssertEqual(names, ["Ivan"])
    }

    func test_no_sidecars_resolves_to_nobody() {
        XCTAssertTrue(PeopleRail.resolvedPeople(attendees: [], overlay: .empty).isEmpty)
    }

    // MARK: - renamed (the carry's pure half)

    func test_rename_maps_a_baked_transcript_label_to_the_new_name() {
        // The pipeline's roster match baked "Ivan" into <stem>.json at finalize, so
        // there is no overlay entry to rewrite: map the raw label instead.
        let next = PeopleRail.renamed(
            .empty, attendees: ["Ivan", "THEM-A"], from: "Ivan", to: "Ivan K."
        )
        XCTAssertEqual(next?.labels, ["Ivan": "Ivan K."])
        XCTAssertEqual(next?.segments, [:])
    }

    func test_rename_rewrites_an_overlay_name_in_place() {
        // Named in-app: the raw label is still THEM-A, and that entry is what has
        // to move. The summary predates the naming, so attendees know nothing.
        let next = PeopleRail.renamed(
            overlay(labels: ["THEM-A": "Ivan"], segments: [3: "Ivan"]),
            attendees: ["THEM-A"], from: "Ivan", to: "Ivan K."
        )
        XCTAssertEqual(next?.labels, ["THEM-A": "Ivan K."])
        XCTAssertEqual(next?.segments, [3: "Ivan K."])
    }

    func test_rename_covers_a_summary_regenerated_after_the_naming() {
        // The third shape: the overlay names THEM-A "Ivan" AND a regenerate baked
        // "Ivan" into attendees. Both halves have to move or the row half-empties.
        let next = PeopleRail.renamed(
            overlay(labels: ["THEM-A": "Ivan"]),
            attendees: ["Ivan"], from: "Ivan", to: "Ivan K."
        )
        XCTAssertEqual(next?.labels, ["THEM-A": "Ivan K.", "Ivan": "Ivan K."])
    }

    func test_renaming_back_collapses_what_the_rename_added() {
        // Reversibility is what keeps the carry safe: renaming A->B->A must not
        // leave "A displays as B" behind, which would rename the wrong cluster.
        let first = PeopleRail.renamed(
            overlay(labels: ["THEM-A": "Ivan"]),
            attendees: ["Ivan"], from: "Ivan", to: "Ivan K."
        )
        let back = PeopleRail.renamed(
            first!, attendees: ["Ivan"], from: "Ivan K.", to: "Ivan"
        )
        XCTAssertEqual(back?.labels, ["THEM-A": "Ivan"])
    }

    func test_rename_leaves_an_unrelated_meeting_untouched() {
        XCTAssertNil(PeopleRail.renamed(
            overlay(labels: ["THEM-A": "Rana"]),
            attendees: ["THEM-A"], from: "Ivan", to: "Ivan K."
        ))
    }

    func test_renaming_to_the_same_name_is_a_no_op() {
        XCTAssertNil(PeopleRail.renamed(
            overlay(labels: ["THEM-A": "Ivan"]),
            attendees: ["Ivan"], from: "Ivan", to: " ivan "
        ))
    }

    // MARK: - Last-seen wording

    func test_last_seen_reads_relatively_inside_a_week() {
        let now = day(10)
        XCTAssertEqual(PeopleDate.lastSeen(day(10), now: now), "today")
        XCTAssertEqual(PeopleDate.lastSeen(day(9), now: now), "yesterday")
        XCTAssertEqual(PeopleDate.lastSeen(day(7), now: now), "3d ago")
        XCTAssertEqual(PeopleDate.lastSeen(day(0), now: now), PeopleDate.short(day(0)))
    }
}
