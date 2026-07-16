import XCTest
@testable import MeetingPipe

/// FEAT3-SEGMENT: the meeting's cast is resolved by who a person IS, not by the raw
/// diarization label, which is a mix of baked names, unnamed clusters, and the
/// `speaker_unknown` junk drawer.
final class MeetingCastTests: XCTestCase {

    private func seg(_ index: Int, speaker: String?) -> TranscriptSegment {
        TranscriptSegment(
            index: index, start: Double(index), end: Double(index) + 1,
            text: "t\(index)", speakerID: speaker
        )
    }

    private func overlay(labels: [String: String] = [:], segments: [Int: String] = [:])
        -> SpeakerLabelStore.Overlay {
        SpeakerLabelStore.Overlay(labels: labels, segments: segments)
    }

    // MARK: - Bug A: a "New person" name must be reusable

    func test_a_person_introduced_only_by_a_segment_override_is_in_the_cast() {
        // The bug: "Anisha" was assigned to one line via New person, then was absent
        // from every other line's Assign-to list, forcing a retype each time. She
        // exists only as a per-segment override value, never as a raw label.
        let segments = [seg(0, speaker: "THEM-A"), seg(1, speaker: "THEM-A")]
        let cast = MeetingCast.members(
            segments: segments, overlay: overlay(segments: [1: "Anisha"])
        )
        XCTAssertEqual(cast.map(\.displayName), ["Unknown A", "Anisha"])
        // Assigning another line to her writes her name straight through.
        XCTAssertEqual(cast.first { $0.displayName == "Anisha" }?.assignKey, "Anisha")
    }

    func test_assign_targets_offer_a_segment_only_person_to_other_lines() {
        let segments = [seg(0, speaker: "THEM-A"), seg(1, speaker: "THEM-A")]
        let ov = overlay(segments: [1: "Anisha"])
        let cast = MeetingCast.members(segments: segments, overlay: ov)
        let targets = MeetingCast.assignTargets(for: segments[0], cast: cast, overlay: ov)
        XCTAssertEqual(targets.map(\.displayName), ["Anisha"],
                       "line 0 can now be assigned to the person introduced on line 1")
    }

    // MARK: - Bug C2: exclude by identity, not by raw label

    func test_a_renamed_cluster_still_offers_the_person_its_raw_label_names() {
        // The real tangle: the raw label IS "Heorhii" (the pipeline bakes the user's
        // own voice in from `user_label`), but an overlay rename displays it as
        // "Aditya". The old raw-label filter hid Heorhii from this line's own list,
        // which is why "I cannot really assign it to me".
        let segments = [seg(0, speaker: "Heorhii"), seg(1, speaker: "THEM-A")]
        let ov = overlay(labels: ["Heorhii": "Aditya"])
        let cast = MeetingCast.members(segments: segments, overlay: ov)
        XCTAssertEqual(cast.map(\.displayName), ["Aditya", "Unknown A"])

        // Line 1 (Unknown A) can be assigned to the person on line 0.
        let targets = MeetingCast.assignTargets(for: segments[1], cast: cast, overlay: ov)
        XCTAssertEqual(targets.map(\.displayName), ["Aditya"])
    }

    func test_a_line_is_never_offered_the_person_it_already_shows() {
        let segments = [seg(0, speaker: "THEM-A"), seg(1, speaker: "THEM-B")]
        let ov = overlay(labels: ["THEM-A": "Rana", "THEM-B": "Sudip"])
        let cast = MeetingCast.members(segments: segments, overlay: ov)
        let targets = MeetingCast.assignTargets(for: segments[0], cast: cast, overlay: ov)
        XCTAssertEqual(targets.map(\.displayName), ["Sudip"], "Rana is this line already")
    }

    // MARK: - Grouping by identity

    func test_two_routes_to_the_same_person_are_one_cast_member() {
        // Segment 0 reaches Heorhii by its baked raw label; segment 1 by a per-segment
        // override. One person, not two. (The real overlay had exactly this: raw
        // 'Heorhii' alongside segments overridden to "Heorhii".)
        let segments = [seg(0, speaker: "Heorhii"), seg(1, speaker: "THEM-A")]
        let cast = MeetingCast.members(
            segments: segments, overlay: overlay(segments: [1: "Heorhii"])
        )
        XCTAssertEqual(cast.map(\.displayName), ["Heorhii"])
    }

    func test_assign_key_prefers_the_raw_cluster_so_a_later_rename_follows() {
        // Person reached first by an override (line 0), then by their own raw cluster
        // (line 1): the durable key is the cluster, so renaming it carries the
        // assignment along instead of stranding it on a frozen name string.
        let segments = [seg(0, speaker: "THEM-B"), seg(1, speaker: "THEM-A")]
        let ov = overlay(labels: ["THEM-A": "Rana"], segments: [0: "THEM-A"])
        let cast = MeetingCast.members(segments: segments, overlay: ov)
        // THEM-B is displayed nowhere (its only line was reassigned away), so it is
        // correctly not in the cast: the cast is who the meeting actually shows.
        XCTAssertEqual(cast.map(\.displayName), ["Rana"])
        XCTAssertEqual(cast.first { $0.displayName == "Rana" }?.assignKey, "THEM-A")
    }

    // MARK: - The junk drawer

    func test_speaker_unknown_is_unattributed_and_never_an_assign_target() {
        let segments = [seg(0, speaker: "speaker_unknown"), seg(1, speaker: "THEM-A")]
        let ov = overlay()
        let cast = MeetingCast.members(segments: segments, overlay: ov)
        XCTAssertTrue(cast.first { $0.isUnattributed } != nil)
        // Assigning a line TO the junk drawer is meaningless; Reset is the way back.
        let targets = MeetingCast.assignTargets(for: segments[1], cast: cast, overlay: ov)
        XCTAssertFalse(targets.contains { $0.isUnattributed })
    }

    // MARK: - The enrollment gate

    func test_only_an_anonymous_label_is_enrollable() {
        XCTAssertTrue(MeetingCast.isUnnamedCluster("THEM-A"))
        XCTAssertTrue(MeetingCast.isUnnamedCluster("speaker_unknown"))
        XCTAssertTrue(MeetingCast.isUnnamedCluster("speaker_3"))
        // Already a person: enrolling these as if anonymous is what let the user
        // "name" their own baked-in voice and tangle the overlay.
        XCTAssertFalse(MeetingCast.isUnnamedCluster("Heorhii"))
        XCTAssertFalse(MeetingCast.isUnnamedCluster("Rana"))
    }

    // MARK: - The real meeting, as a regression fixture

    func test_the_real_20260715_tangle_resolves_to_one_member_per_person() {
        // Shape taken from the user's actual 20260715-163053: a baked "Heorhii" raw
        // label, named clusters, the junk drawer, and a per-segment New person.
        let segments = [
            seg(0, speaker: "THEM-A"),          // -> Rana
            seg(1, speaker: "Heorhii"),         // baked name
            seg(2, speaker: "speaker_unknown"), // junk drawer
            seg(3, speaker: "THEM-C"),          // -> Sudip
            seg(4, speaker: "speaker_unknown"), // -> Anisha via override
        ]
        let ov = overlay(
            labels: ["THEM-A": "Rana", "THEM-C": "Sudip"],
            segments: [4: "Anisha"]
        )
        let cast = MeetingCast.members(segments: segments, overlay: ov)
        XCTAssertEqual(cast.map(\.displayName), ["Rana", "Heorhii", "Unknown speaker", "Sudip", "Anisha"])

        // A junk-drawer line can be assigned to any real person, including the user.
        let targets = MeetingCast.assignTargets(for: segments[2], cast: cast, overlay: ov)
        XCTAssertEqual(targets.map(\.displayName), ["Rana", "Heorhii", "Sudip", "Anisha"])
    }
}
