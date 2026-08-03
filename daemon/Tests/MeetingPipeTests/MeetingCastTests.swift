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

    // MARK: - UX57: the row menu acts on the person the line shows

    func test_an_unreassigned_named_cluster_offers_rename_and_undo_against_its_own_label() {
        // (a) The unchanged case: nothing was reassigned, so the identity is the raw
        // cluster and both items target it.
        let segments = [seg(0, speaker: "THEM-A")]
        let row = MeetingCast.rowSpeaker(
            for: segments[0],
            overlay: overlay(labels: ["THEM-A": "Sudip"]),
            voiceprintLabels: ["THEM-A"]
        )
        XCTAssertEqual(row.displayName, "Sudip")
        XCTAssertEqual(row.label, "THEM-A")
        XCTAssertEqual(row.actions, [
            .rename(label: "THEM-A", currentName: "Sudip"),
            .unname(label: "THEM-A", currentName: "Sudip"),
        ])
    }

    func test_a_line_reassigned_to_an_unnamed_cluster_offers_naming_for_that_cluster() {
        // (b) The reported bug, as the owner hit it: line 1 was named Sudip with the
        // rest of THEM-A, then reassigned to Unknown E because it is not Sudip. The
        // menu used to read the raw label, still see "Sudip", and offer to rename her,
        // which would have re-enrolled her voiceprint under the new name and renamed
        // her on every other line of the meeting.
        let segments = [seg(0, speaker: "THEM-A"), seg(1, speaker: "THEM-A")]
        let ov = overlay(labels: ["THEM-A": "Sudip"], segments: [1: "THEM-E"])
        let row = MeetingCast.rowSpeaker(
            for: segments[1], overlay: ov, voiceprintLabels: ["THEM-A", "THEM-E"]
        )
        XCTAssertEqual(row.displayName, "Unknown E")
        XCTAssertEqual(row.label, "THEM-E", "the menu targets the cluster the line was moved TO")
        XCTAssertEqual(row.actions, [.name(label: "THEM-E")])
        XCTAssertFalse(
            row.actions.contains { if case .rename = $0 { return true } else { return false } },
            "nothing here may rename Sudip"
        )
        // Her own lines are untouched by the fix.
        let origin = MeetingCast.rowSpeaker(
            for: segments[0], overlay: ov, voiceprintLabels: ["THEM-A", "THEM-E"]
        )
        XCTAssertEqual(origin.actions, [
            .rename(label: "THEM-A", currentName: "Sudip"),
            .unname(label: "THEM-A", currentName: "Sudip"),
        ])
    }

    func test_a_line_reassigned_to_a_named_cluster_targets_that_cluster() {
        // (c) The other direction: an unnamed line moved onto a named person. The row
        // shows Sudip, so its rename targets Sudip's cluster, not the anonymous one the
        // line came from.
        let segments = [seg(0, speaker: "THEM-A"), seg(1, speaker: "THEM-B")]
        let ov = overlay(labels: ["THEM-A": "Sudip"], segments: [1: "THEM-A"])
        let row = MeetingCast.rowSpeaker(
            for: segments[1], overlay: ov, voiceprintLabels: ["THEM-A", "THEM-B"]
        )
        XCTAssertEqual(row.displayName, "Sudip")
        XCTAssertEqual(row.actions, [
            .rename(label: "THEM-A", currentName: "Sudip"),
            .unname(label: "THEM-A", currentName: "Sudip"),
        ])
        XCTAssertFalse(
            row.actions.contains { if case .name = $0 { return true } else { return false } },
            "THEM-B is not on offer for enrollment from a line that no longer shows it"
        )
    }

    func test_a_new_person_line_offers_no_roster_enrollment() {
        // (d) A FEAT3-SEGMENT "New person" lives only as a per-segment value: no
        // `labels` entry holds it, so an un-name would drop nothing, and it has no
        // embedding, so enrolling it would hit `renameSpeaker`'s own missing-voiceprint
        // guard. The way back is "Reset to original label" on the line.
        let segments = [seg(0, speaker: "THEM-A"), seg(1, speaker: "THEM-A")]
        let ov = overlay(labels: ["THEM-A": "Sudip"], segments: [1: "Anisha"])
        let row = MeetingCast.rowSpeaker(
            for: segments[1], overlay: ov, voiceprintLabels: ["THEM-A"]
        )
        XCTAssertEqual(row.displayName, "Anisha")
        XCTAssertEqual(row.label, "Anisha")
        XCTAssertTrue(row.actions.isEmpty)
    }

    func test_an_already_named_person_is_never_offered_for_enrollment() {
        // A roster match is baked into `<stem>.json`, so its label carries a voiceprint
        // and is not a cluster. Naming it would be naming somebody who has a name.
        let segments = [seg(0, speaker: "THEM-B")]
        let row = MeetingCast.rowSpeaker(
            for: segments[0],
            overlay: overlay(segments: [0: "Rana"]),
            voiceprintLabels: ["Rana", "THEM-B"]
        )
        XCTAssertEqual(row.displayName, "Rana")
        XCTAssertTrue(row.actions.isEmpty)
    }

    func test_a_line_with_no_speaker_at_all_offers_nothing() {
        let row = MeetingCast.rowSpeaker(
            for: seg(0, speaker: nil), overlay: overlay(), voiceprintLabels: []
        )
        XCTAssertNil(row.label)
        XCTAssertEqual(row.displayName, "Unknown")
        XCTAssertTrue(row.actions.isEmpty)
    }

    func test_the_row_shows_the_cast_member_its_line_resolves_to() {
        // The acceptance's third clause, as an assertion over every line: the row's
        // identity and the cast strip's grouping are the same resolution, so the two
        // surfaces cannot disagree about who a line belongs to.
        let segments = [
            seg(0, speaker: "THEM-A"),          // -> Sudip
            seg(1, speaker: "THEM-A"),          // -> reassigned to Unknown E
            seg(2, speaker: "Heorhii"),         // baked name
            seg(3, speaker: "speaker_unknown"), // junk drawer
            seg(4, speaker: "THEM-B"),          // -> reassigned to a New person
        ]
        let ov = overlay(
            labels: ["THEM-A": "Sudip"],
            segments: [1: "THEM-E", 4: "Anisha"]
        )
        let cast = MeetingCast.members(segments: segments, overlay: ov)
        for segment in segments {
            let row = MeetingCast.rowSpeaker(for: segment, overlay: ov, voiceprintLabels: [])
            XCTAssertTrue(
                cast.contains { $0.displayName == row.displayName },
                "line \(segment.index) shows \(row.displayName), which is nobody in the cast"
            )
        }
        XCTAssertEqual(
            segments.map { MeetingCast.rowSpeaker(for: $0, overlay: ov, voiceprintLabels: []).displayName },
            ["Sudip", "Unknown E", "Heorhii", "Unknown speaker", "Anisha"]
        )
    }

    func test_the_row_and_the_cast_chip_offer_the_same_thing_for_one_person() {
        // Same rule, two surfaces (UX40's `actions(for:)` and this one). A "New person"
        // is the case they used to be able to disagree about: the chip has always said
        // "nothing to change here", and the row now agrees instead of offering a rename
        // for whoever the line was assigned away from.
        let segments = [seg(0, speaker: "THEM-A"), seg(1, speaker: "THEM-A")]
        let ov = overlay(labels: ["THEM-A": "Sudip"], segments: [1: "Anisha"])
        let cast = MeetingCast.members(segments: segments, overlay: ov)
        let outcome = VoiceResolution.derive(
            cast: cast, voiceprintLabels: ["THEM-A"], rosterNames: ["Sudip"], userLabel: "Heorhii"
        )
        let anisha = outcome.voices.first { $0.displayName == "Anisha" }
        XCTAssertNotNil(anisha)
        XCTAssertTrue(VoiceResolutionBar.actions(for: anisha!).isEmpty)
        XCTAssertTrue(
            MeetingCast.rowSpeaker(for: segments[1], overlay: ov, voiceprintLabels: ["THEM-A"])
                .actions.isEmpty
        )
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
