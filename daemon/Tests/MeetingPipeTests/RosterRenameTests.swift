import XCTest
@testable import MeetingPipe

/// DV3: the roster-rename carry. `mp roster rename` renames an entry in
/// `roster.json` and nothing else, so without this step the People rail's own
/// rename would empty the person's history. These tests drive the file half
/// (which meetings get rewritten) against a real directory; the pure overlay
/// edit is pinned by `PeopleRailTests`.
final class RosterRenameTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mp-roster-rename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Helpers

    private func writeSummary(_ stem: String, attendees: [String]) throws {
        let payload: [String: Any] = [
            "title": stem, "summary": [], "decisions": [], "actions": [],
            "questions": [], "attendees": attendees, "detected_language": "en",
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: dir.appendingPathComponent("\(stem).summary.json"))
    }

    private func overlay(_ stem: String) -> SpeakerLabelStore.Overlay {
        SpeakerLabelStore.read(stem: stem, in: dir)
    }

    // MARK: - Tests

    func test_carry_rewrites_only_the_meetings_the_person_is_in() throws {
        try writeSummary("20260101-090000", attendees: ["Ivan", "THEM-A"])
        try writeSummary("20260102-090000", attendees: ["Rana"])

        let touched = RosterRename.carry(from: "Ivan", to: "Ivan K.", in: dir)

        XCTAssertEqual(touched, 1)
        XCTAssertEqual(overlay("20260101-090000").labels, ["Ivan": "Ivan K."])
        XCTAssertTrue(overlay("20260102-090000").isEmpty)
    }

    func test_carry_follows_a_person_named_only_through_the_overlay() throws {
        // No summary at all: the meeting is a candidate through its overlay alone,
        // which is the shape an in-app naming leaves before any regenerate.
        try SpeakerLabelStore.setLabel("THEM-A", to: "Ivan", stem: "20260101-090000", in: dir)

        XCTAssertEqual(RosterRename.carry(from: "Ivan", to: "Ivan K.", in: dir), 1)
        XCTAssertEqual(overlay("20260101-090000").labels, ["THEM-A": "Ivan K."])
    }

    func test_carry_moves_per_segment_assignments_too() throws {
        // A "New person" exists only as a per-segment override, so a labels-only
        // rewrite would strand every line assigned to them.
        try SpeakerLabelStore.setSegments([2, 5], to: "Ivan", stem: "20260101-090000", in: dir)

        XCTAssertEqual(RosterRename.carry(from: "Ivan", to: "Ivan K.", in: dir), 1)
        XCTAssertEqual(overlay("20260101-090000").segments, [2: "Ivan K.", 5: "Ivan K."])
    }

    func test_carry_never_rewrites_the_transcript() throws {
        // FEAT3-UNDO's invariant: the diarization labels in <stem>.json survive
        // every naming, so a rename has to stay in the overlay.
        let transcript = dir.appendingPathComponent("20260101-090000.json")
        let original = Data(#"{"segments":[{"speaker":"Ivan","text":"hi"}]}"#.utf8)
        try original.write(to: transcript)
        try writeSummary("20260101-090000", attendees: ["Ivan"])

        _ = RosterRename.carry(from: "Ivan", to: "Ivan K.", in: dir)

        XCTAssertEqual(try Data(contentsOf: transcript), original)
    }

    func test_carry_is_a_no_op_for_an_unmatched_or_unchanged_name() throws {
        try writeSummary("20260101-090000", attendees: ["Rana"])
        XCTAssertEqual(RosterRename.carry(from: "Ivan", to: "Ivan K.", in: dir), 0)
        XCTAssertEqual(RosterRename.carry(from: "Rana", to: "  rana ", in: dir), 0)
        XCTAssertEqual(RosterRename.carry(from: "Rana", to: "   ", in: dir), 0)
        XCTAssertTrue(overlay("20260101-090000").isEmpty)
    }

    func test_carry_on_an_empty_library_is_zero() {
        let missing = dir.appendingPathComponent("nope")
        XCTAssertEqual(RosterRename.carry(from: "Ivan", to: "Ivan K.", in: missing), 0)
    }

    func test_carry_round_trips_so_a_rename_is_reversible() throws {
        try writeSummary("20260101-090000", attendees: ["THEM-A"])
        try SpeakerLabelStore.setLabel("THEM-A", to: "Ivan", stem: "20260101-090000", in: dir)

        _ = RosterRename.carry(from: "Ivan", to: "Ivan K.", in: dir)
        _ = RosterRename.carry(from: "Ivan K.", to: "Ivan", in: dir)

        XCTAssertEqual(overlay("20260101-090000").labels, ["THEM-A": "Ivan"])
    }
}
