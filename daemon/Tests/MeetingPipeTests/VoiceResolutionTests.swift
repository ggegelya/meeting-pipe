import XCTest
@testable import MeetingPipe

/// FEAT11: the per-meeting voice-resolution surface. The bug it answers is a meeting
/// that surfaced `THEM-B` / `THEM-C` while the roster was populated, with no way to
/// tell "these people are not enrolled" from "they are enrolled and matching missed".
/// Those have opposite fixes, so the classification has to be exact and the counts
/// have to be honest about which is which.
final class VoiceResolutionTests: XCTestCase {

    private func member(_ display: String, key: String, unattributed: Bool = false) -> CastMember {
        CastMember(displayName: display, assignKey: key, isUnattributed: unattributed)
    }

    private func derive(
        _ cast: [CastMember],
        voiceprints: Set<String> = [],
        roster: [String] = ["Rana"],
        user: String = "Heorhii"
    ) -> VoiceResolution.Outcome {
        VoiceResolution.derive(
            cast: cast, voiceprintLabels: voiceprints, rosterNames: roster, userLabel: user
        )
    }

    // MARK: - Classification

    func test_the_owner_is_not_counted_as_a_match() {
        let out = derive([member("Heorhii", key: "Heorhii")], voiceprints: ["Heorhii"])
        XCTAssertEqual(out.voices.map(\.origin), [.you])
        // The owner is identified by the self-voiceprint, never by the roster, so
        // counting them would inflate the match rate on every single meeting.
        XCTAssertEqual(out.others, 0)
        XCTAssertEqual(out.headline, "No other voices in this meeting.")
    }

    func test_a_baked_name_with_a_voiceprint_is_a_roster_match() {
        let out = derive(
            [member("Heorhii", key: "Heorhii"), member("Rana", key: "Rana")],
            voiceprints: ["Heorhii", "Rana"]
        )
        XCTAssertEqual(out.voices.map(\.origin), [.you, .roster])
        XCTAssertEqual(out.rosterMatched, 1)
        XCTAssertEqual(out.headline, "1 of 1 voice named.")
        XCTAssertNil(out.detail)
    }

    func test_an_unnamed_cluster_is_unresolved() {
        let out = derive(
            [member("Unknown B", key: "THEM-B"), member("Unknown C", key: "THEM-C")],
            voiceprints: ["THEM-B", "THEM-C"]
        )
        XCTAssertEqual(out.voices.map(\.origin), [.unresolved, .unresolved])
        XCTAssertEqual(out.unresolved, 2)
        XCTAssertEqual(out.headline, "0 of 2 voices named.")
        XCTAssertEqual(out.detail, "2 voices are still unnamed.")
    }

    func test_a_cluster_renamed_in_the_app_reads_as_named_here_not_as_a_roster_match() {
        // The overlay carries the name; `<stem>.embeddings.json` still keys it THEM-B.
        // Calling this a roster match would claim matching worked when the user is the
        // one who fixed it, which is exactly the signal this surface exists to give.
        let out = derive([member("Anisha", key: "THEM-B")], voiceprints: ["THEM-B"])
        XCTAssertEqual(out.voices.map(\.origin), [.namedHere])
        XCTAssertEqual(out.rosterMatched, 0)
        XCTAssertEqual(out.namedHere, 1)
        XCTAssertEqual(out.headline, "1 of 1 voice named.")
    }

    func test_a_new_person_who_only_exists_in_the_overlay_is_named_here() {
        // FEAT3-SEGMENT's "New person": the assign key is the literal typed name and
        // there is no voiceprint anywhere, so nothing can enroll it as a cluster.
        let out = derive([member("Dana", key: "Dana")], voiceprints: [])
        XCTAssertEqual(out.voices.map(\.origin), [.namedHere])
        XCTAssertFalse(out.voices[0].canEnroll)
    }

    func test_the_unattributed_bucket_is_never_counted_and_never_offered() {
        let out = derive(
            [member("Unknown speaker", key: "speaker_unknown", unattributed: true),
             member("Unknown B", key: "THEM-B")],
            voiceprints: ["THEM-B"]
        )
        XCTAssertEqual(out.voices.map(\.origin), [.unattributed, .unresolved])
        // speaker_unknown is a junk drawer, not a person; counting it as an unnamed
        // voice would make every meeting look worse than it is.
        XCTAssertEqual(out.others, 1)
        XCTAssertFalse(out.voices[0].offersNaming)
    }

    func test_the_owner_label_match_is_case_insensitive_and_ignores_padding() {
        let out = derive([member("heorhii", key: "heorhii")], user: "  Heorhii  ")
        XCTAssertEqual(out.voices.map(\.origin), [.you])
    }

    func test_with_no_owner_label_configured_nothing_is_claimed_as_you() {
        // The silent-owner case: `resolve_speaker_labels` names nobody, so a name here
        // could only have come from the roster or the app.
        let out = derive([member("Rana", key: "Rana")], voiceprints: ["Rana"], user: "")
        XCTAssertEqual(out.voices.map(\.origin), [.roster])
    }

    // MARK: - Naming affordance

    func test_naming_is_offered_only_for_an_unresolved_cluster_with_a_voiceprint() {
        let out = derive(
            [member("Unknown B", key: "THEM-B"),      // has a voiceprint
             member("Unknown C", key: "THEM-C"),      // none: diarizer never embedded it
             member("Rana", key: "Rana")],
            voiceprints: ["THEM-B", "Rana"]
        )
        XCTAssertEqual(out.voices.map(\.offersNaming), [true, false, false])
        // Enrolling a label with no embedding hard-failed with "pipeline exited 2",
        // which is why the gate is the sidecar and not just the origin.
        XCTAssertEqual(out.voices[1].origin, .unresolved)
    }

    func test_the_deep_link_target_is_the_raw_label_not_the_display_name() {
        let out = derive([member("Unknown B", key: "THEM-B")], voiceprints: ["THEM-B"])
        // The naming sheet enrolls by raw label; handing it "Unknown B" would enroll a
        // voiceprint under a label that exists nowhere on disk.
        XCTAssertEqual(out.voices[0].assignKey, "THEM-B")
        XCTAssertEqual(out.voices[0].id, "THEM-B")
    }

    // MARK: - Honesty about an empty roster

    func test_an_empty_roster_says_so_instead_of_reporting_zero_matches() {
        let out = derive(
            [member("Unknown B", key: "THEM-B")], voiceprints: ["THEM-B"], roster: []
        )
        XCTAssertTrue(out.rosterIsEmpty)
        XCTAssertEqual(
            out.headline,
            "No named voices yet, so nothing could be matched. Name a voice below to start."
        )
    }

    func test_a_populated_roster_that_matched_nothing_reports_the_miss() {
        // The distinction the whole surface exists for: same rows, different cause.
        let out = derive(
            [member("Unknown B", key: "THEM-B")], voiceprints: ["THEM-B"], roster: ["Rana"]
        )
        XCTAssertFalse(out.rosterIsEmpty)
        XCTAssertEqual(out.headline, "0 of 1 voice named.")
    }

    func test_removing_someone_from_the_roster_does_not_rewrite_an_old_meeting() {
        // Match state is read off `<stem>.embeddings.json`, not off today's roster, so
        // a past meeting keeps saying what the pipeline actually did at the time.
        let out = derive([member("Rana", key: "Rana")], voiceprints: ["Rana"], roster: ["Someone else"])
        XCTAssertEqual(out.voices.map(\.origin), [.roster])
    }

    func test_an_empty_cast_is_an_empty_outcome() {
        let out = derive([])
        XCTAssertTrue(out.voices.isEmpty)
        XCTAssertEqual(out.others, 0)
    }

    // MARK: - Presentation

    func test_every_origin_has_a_glyph_and_words() {
        // A new origin that gets an icon and no words would render as a mute badge.
        let origins: [VoiceResolution.Origin] = [.you, .roster, .namedHere, .unresolved, .unattributed]
        for origin in origins {
            XCTAssertFalse(VoiceResolutionBar.glyph(for: origin).isEmpty, "\(origin)")
            let voice = VoiceResolution.Voice(
                displayName: "x", assignKey: "x", origin: origin, canEnroll: true
            )
            XCTAssertFalse(VoiceResolutionBar.state(for: voice).isEmpty, "\(origin)")
        }
    }
}
