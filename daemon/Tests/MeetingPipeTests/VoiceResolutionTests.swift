import SwiftUI
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
        XCTAssertEqual(out.headline, "The other voice is named.")
        XCTAssertNil(out.detail)
    }

    func test_an_unnamed_cluster_is_unresolved() {
        let out = derive(
            [member("Unknown B", key: "THEM-B"), member("Unknown C", key: "THEM-C")],
            voiceprints: ["THEM-B", "THEM-C"]
        )
        XCTAssertEqual(out.voices.map(\.origin), [.unresolved, .unresolved])
        XCTAssertEqual(out.unresolved, 2)
        XCTAssertEqual(out.headline, "0 of 2 other voices named.")
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
        XCTAssertEqual(out.headline, "The other voice is named.")
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
        XCTAssertEqual(out.headline, "0 of 1 other voice named.")
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
                displayName: "x", assignKey: "x", origin: origin, canEnroll: true, colorIndex: 0
            )
            XCTAssertFalse(VoiceResolutionBar.state(for: voice).isEmpty, "\(origin)")
        }
    }

    // MARK: - Identity and status are two marks, not one (UX59)

    func test_a_chip_carries_the_speakers_cast_slot() {
        let out = derive(
            [member("Heorhii", key: "Heorhii"),
             member("Unknown B", key: "THEM-B"),
             member("Rana", key: "Rana")],
            voiceprints: ["Heorhii", "THEM-B", "Rana"]
        )
        XCTAssertEqual(out.voices.map(\.colorIndex), [0, 1, 2])
    }

    func test_the_dot_is_position_and_the_glyph_is_status_so_neither_stands_in_for_the_other() {
        // The task's own out-of-scope line: FEAT11 exists so "did roster matching work
        // here" is answerable at a glance, and a change that expressed identity by
        // recolouring the status glyph would have deleted that answer while satisfying
        // the consistency complaint. So the two channels are checked to be independent
        // in both directions.
        let out = derive(
            [member("Unknown B", key: "THEM-B"), member("Rana", key: "Rana")],
            voiceprints: ["THEM-B", "Rana"]
        )
        XCTAssertEqual(out.voices.map(\.origin), [.unresolved, .roster])

        // Different status, and it is legible without looking at the dot at all: the
        // glyphs are different symbols, not one symbol in two colours.
        XCTAssertNotEqual(
            VoiceResolutionBar.glyph(for: .unresolved), VoiceResolutionBar.glyph(for: .roster)
        )
        XCTAssertTrue(out.voices[0].offersNaming)
        XCTAssertFalse(out.voices[1].offersNaming)

        // And the dot says nothing about status: swap who speaks first and the slots
        // swap while each voice keeps its own glyph.
        let swapped = derive(
            [member("Rana", key: "Rana"), member("Unknown B", key: "THEM-B")],
            voiceprints: ["THEM-B", "Rana"]
        )
        XCTAssertEqual(swapped.voices.map(\.origin), [.roster, .unresolved])
        XCTAssertEqual(swapped.voices.map(\.colorIndex), [0, 1])
    }

    func test_two_unnamed_voices_get_two_dots_and_the_same_status() {
        // The other direction: the dot separates people the status treatment cannot,
        // which is the whole reason the strip needed one.
        let out = derive(
            [member("Unknown A", key: "THEM-A"), member("Unknown B", key: "THEM-B")],
            voiceprints: ["THEM-A", "THEM-B"]
        )
        XCTAssertEqual(out.voices.map(\.origin), [.unresolved, .unresolved])
        XCTAssertNotEqual(out.voices[0].colorIndex, out.voices[1].colorIndex)
    }

    // MARK: - A count of what it shows (UX40)

    func test_the_nine_chip_repro_no_longer_reads_as_a_miscount() {
        // The owner's screenshot: nine chips, "7 of 7 voices named". Both excluded chips
        // render (their own voice, and the speaker_unknown junk drawer), so the sentence
        // read as a count of what was on screen and looked two short. The exclusions are
        // right; only the word "other" was missing.
        var cast = [member("Heorhii", key: "Heorhii"),
                    member("Unknown speaker", key: "speaker_unknown", unattributed: true)]
        var prints: Set<String> = ["Heorhii"]
        for i in 1...7 {
            cast.append(member("Person \(i)", key: "Person \(i)"))
            prints.insert("Person \(i)")
        }

        let out = derive(cast, voiceprints: prints)

        XCTAssertEqual(out.voices.count, 9, "every classified voice still gets a chip")
        XCTAssertEqual(out.others, 7, "and the count itself is unchanged: this is a copy fix")
        XCTAssertEqual(out.headline, "All 7 other voices named.")
    }

    func test_a_partly_named_meeting_keeps_the_of_form() {
        var cast = [member("Heorhii", key: "Heorhii")]
        var prints: Set<String> = ["Heorhii"]
        for i in 1...5 {
            cast.append(member("Person \(i)", key: "Person \(i)"))
            prints.insert("Person \(i)")
        }
        cast.append(member("Unknown B", key: "THEM-B"))
        cast.append(member("Unknown C", key: "THEM-C"))
        prints.formUnion(["THEM-B", "THEM-C"])

        let out = derive(cast, voiceprints: prints)

        XCTAssertEqual(out.headline, "5 of 7 other voices named.")
        XCTAssertEqual(out.detail, "2 voices are still unnamed.")
    }

    // MARK: - What a chip offers (UX40)

    func test_a_voice_named_in_this_meeting_offers_rename_and_un_name() {
        let out = derive([member("Anisha", key: "THEM-B")], voiceprints: ["THEM-B"])

        XCTAssertEqual(out.voices.map(\.origin), [.namedHere])
        XCTAssertEqual(VoiceResolutionBar.actions(for: out.voices[0]), [.rename, .unname])
    }

    func test_a_roster_match_offers_the_everywhere_rename_and_says_how_far_it_reaches() {
        let out = derive([member("Rana", key: "Rana")], voiceprints: ["Rana"])

        XCTAssertEqual(out.voices.map(\.origin), [.roster])
        // The name is baked into `<stem>.json` by finalize, so no per-meeting overlay
        // write reaches it and the roster's rename is the only one that does. Before this
        // it had no rename anywhere in the meeting UI, only Preferences.
        XCTAssertEqual(VoiceResolutionBar.actions(for: out.voices[0]), [.renameEverywhere])
        XCTAssertTrue(VoiceResolutionBar.title(for: .renameEverywhere).contains("everywhere"))
        let caption = try? XCTUnwrap(VoiceResolutionBar.caption(for: .renameEverywhere))
        XCTAssertNotNil(caption)
        XCTAssertTrue(
            VoiceResolutionBar.accessibilityLabel(for: .renameEverywhere).contains(caption ?? "?"),
            "a caption row never reaches VoiceOver, so the reach rides in the label too"
        )
    }

    func test_an_unresolved_voice_keeps_its_name_affordance_as_a_menu_item_too() {
        let out = derive([member("Unknown B", key: "THEM-B")], voiceprints: ["THEM-B"])

        XCTAssertTrue(out.voices[0].offersNaming, "the click-to-name chip is unchanged")
        XCTAssertEqual(VoiceResolutionBar.actions(for: out.voices[0]), [.name])
    }

    func test_you_and_the_unattributed_bucket_offer_nothing() {
        let out = derive(
            [member("Heorhii", key: "Heorhii"),
             member("Unknown speaker", key: "speaker_unknown", unattributed: true)],
            voiceprints: ["Heorhii"]
        )

        XCTAssertEqual(out.voices.map(\.origin), [.you, .unattributed])
        // Your own name comes from Preferences, and the junk drawer is not a person.
        XCTAssertTrue(VoiceResolutionBar.actions(for: out.voices[0]).isEmpty)
        XCTAssertTrue(VoiceResolutionBar.actions(for: out.voices[1]).isEmpty)
    }

    func test_an_unresolved_voice_with_no_voiceprint_still_offers_nothing() {
        // Enrolling a label with no embedding hard-failed with "pipeline exited 2", which
        // is why the naming gate is the sidecar and not the origin. Per-line assignment
        // from the row menu is the way in for one of these.
        let out = derive([member("Unknown C", key: "THEM-C")], voiceprints: [])

        XCTAssertEqual(out.voices.map(\.origin), [.unresolved])
        XCTAssertTrue(VoiceResolutionBar.actions(for: out.voices[0]).isEmpty)
    }

    func test_a_new_person_chip_offers_nothing_because_neither_action_would_reach_it() {
        // FEAT3-SEGMENT's "New person" is named in the overlay's per-segment map, never in
        // its `labels` map, so "Un-name" would drop an entry that is not there and the
        // chip would not move. That is the transcript row's "Reset to original label", and
        // an affordance that does nothing is worse than one that is absent. This is the
        // same gate the row menu applies (`overlay.labels[speakerID]`), read off the key.
        let out = derive([member("Dana", key: "Dana")], voiceprints: [])

        XCTAssertEqual(out.voices.map(\.origin), [.namedHere])
        XCTAssertTrue(VoiceResolutionBar.actions(for: out.voices[0]).isEmpty)
    }

    func test_every_action_that_can_be_offered_has_words() {
        // The glyph map's rule, applied to the menu: an action that reaches a row with no
        // title renders as a blank line you can still click.
        for action in [VoiceResolutionBar.ChipAction.name, .rename, .unname, .renameEverywhere] {
            XCTAssertFalse(VoiceResolutionBar.title(for: action).isEmpty, "\(action)")
            XCTAssertFalse(VoiceResolutionBar.accessibilityLabel(for: action).isEmpty, "\(action)")
        }
        // Only the action that writes outside this meeting explains its reach; captioning
        // the local ones too would make the one that matters read as boilerplate.
        XCTAssertNil(VoiceResolutionBar.caption(for: .name))
        XCTAssertNil(VoiceResolutionBar.caption(for: .rename))
        XCTAssertNil(VoiceResolutionBar.caption(for: .unname))
    }

    // MARK: - The sheet a chip opens (UX40)

    func test_a_chip_rename_resolves_the_sheet_to_rename_not_a_second_enroll() {
        // The one-line gap this closes: the strip's callback built only the nameless
        // target, so a named chip could not reach the `.rename` mode the sheet has
        // supported since FEAT3-UNDO, however it was opened.
        XCTAssertEqual(NamingTarget(label: "THEM-B", currentName: "Anisha").mode, .rename)
        XCTAssertEqual(NamingTarget(label: "THEM-B").mode, .enroll)
    }

    // MARK: - One implementation

    /// Whether two call sites share a function is decided in the source and nowhere else
    /// at runtime, so the shared-seam claims are pinned the way UX30 and UX32 pinned
    /// theirs: by reading the daemon target.
    private var daemonRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MeetingPipeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // daemon
    }

    private func daemonSource(_ relativePath: String) throws -> String {
        try String(contentsOf: daemonRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// Every file under the daemon target containing `needle`, by file name.
    private func daemonSourceFiles(containing needle: String) throws -> Set<String> {
        let sources = daemonRoot.appendingPathComponent("Sources/MeetingPipe")
        guard let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else {
            XCTFail("could not walk \(sources.path)")
            return []
        }
        var hits: Set<String> = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains(needle) { hits.insert(url.lastPathComponent) }
        }
        return hits
    }

    func test_the_chips_un_name_and_the_rows_undo_are_one_call() throws {
        let tab = try daemonSource("Sources/MeetingPipe/TranscriptTab.swift")

        XCTAssertTrue(tab.contains("onUnname: { label, current in undoNaming("),
                      "the chip routes into the tab's undo handler")
        XCTAssertTrue(tab.contains("onUndoName: { label, current in undoNaming("),
                      "and so does the row, as it already did")
        // One service call behind both. A second one is how a chip's undo comes to drop
        // the overlay without un-enrolling the voiceprint: it looks fixed in this meeting
        // and names the person again in the next one.
        XCTAssertEqual(tab.components(separatedBy: "libraryModel.undoSpeakerNaming(").count - 1, 1)
        XCTAssertEqual(
            try daemonSourceFiles(containing: "undoSpeakerNaming("),
            ["TranscriptTab.swift", "LibraryWindow.swift", "MeetingLibraryService.swift"],
            "the tab calls it, the window model wraps it, the service implements it"
        )
    }

    func test_the_chips_roster_rename_is_the_flow_preferences_and_the_people_rail_run() throws {
        // A fourth file here means a surface grew its own roster rename, which is how the
        // `mp roster rename` half ships without the overlay carry and a rename silently
        // empties that person's history everywhere it is read back.
        XCTAssertEqual(
            try daemonSourceFiles(containing: "RosterRename.run("),
            ["TranscriptTab.swift", "PeopleView.swift", "PreferencesView+Pipeline.swift"]
        )
        let tab = try daemonSource("Sources/MeetingPipe/TranscriptTab.swift")
        XCTAssertTrue(tab.contains("RosterRename.prompt(currentName:"),
                      "and it asks with the shared prompt, which states the reach")
    }

    // MARK: - Construction

    @MainActor
    func test_the_strip_builds_with_the_new_chip_callbacks() {
        let bar = VoiceResolutionBar(
            outcome: derive([member("Anisha", key: "THEM-B")], voiceprints: ["THEM-B"]),
            onName: { _ in },
            onRename: { _, _ in },
            onUnname: { _, _ in },
            onRenameEverywhere: { _ in }
        )
        XCTAssertNotNil(bar.body)
    }

    // MARK: - Overflow (UX51)

    /// The same source with whole-line comments dropped, for the absence fence below:
    /// the code comment explaining this fix names the shape it replaced, and a fence
    /// that reads comments cannot tell a rejected form from a description of one
    /// (`PreferencesSurfaceTests`' idiom).
    private func code(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// The reported defect, as arithmetic. The owner's meeting carried eight chips on a
    /// strip capped at `SummaryLayout.readingMeasure`; laid in one row they cannot fit,
    /// so the only two outcomes are "wrap" and "the tail is cut off", which is what
    /// shipped (a final chip sliced mid-word into a bare `U`). Chip widths are synthetic
    /// on the same reasoning as `FlowLayoutTests`: pinning rendered text metrics pins the
    /// host macOS, and what is being pinned here is that a cast too wide for the measure
    /// produces more than one row and loses nobody.
    func test_a_cast_wider_than_the_reading_measure_wraps_instead_of_being_cut_off() {
        let cast = (0 ..< 8).map { _ in CGSize(width: 110, height: 22) }
        XCTAssertGreaterThan(cast.reduce(0) { $0 + $1.width }, SummaryLayout.readingMeasure,
                             "the premise: this cast cannot fit one row at the reading measure")

        let rows = FlowLayout.rows(for: cast, width: SummaryLayout.readingMeasure, spacing: 6)
        XCTAssertGreaterThan(rows.count, 1)
        XCTAssertEqual(rows.flatMap(\.indices).sorted(), Array(0 ..< cast.count),
                       "every voice the header counts is still on screen somewhere")
    }

    /// The narrowest the strip is ever asked to render at: the detail pane's own floor,
    /// less the reading stack's gutter on both sides. The measure caps the column, so
    /// below 720 the strip simply gets narrower, and narrower is where a single-row
    /// layout fails hardest. Nothing may fall off there either.
    func test_no_chip_falls_off_at_the_narrowest_width_the_pane_allows() {
        let narrowest = LibraryLayout.detailMinWidth - 2 * SummaryLayout.contentPadding
        XCTAssertLessThan(narrowest, SummaryLayout.readingMeasure, "the floor is below the cap, or this is not the floor")

        let cast = (0 ..< 8).map { _ in CGSize(width: 110, height: 22) }
        let rows = FlowLayout.rows(for: cast, width: narrowest, spacing: 6)
        XCTAssertGreaterThan(rows.count, 1)
        XCTAssertEqual(rows.flatMap(\.indices).sorted(), Array(0 ..< cast.count))
        for row in rows {
            XCTAssertLessThanOrEqual(row.width, narrowest, "a row past the pane's own floor is the clip, back again")
        }
    }

    /// A cast that fits is left alone: wrapping must not cost a second row on the common
    /// meeting, which is the reason a chip strip can afford to wrap at all.
    func test_a_cast_that_fits_the_measure_stays_on_one_row() {
        let cast = (0 ..< 4).map { _ in CGSize(width: 110, height: 22) }
        XCTAssertEqual(FlowLayout.rows(for: cast, width: SummaryLayout.readingMeasure, spacing: 6).count, 1)
    }

    /// Where that is decided: the strip lays its chips out with the shared wrapping
    /// layout and no longer hangs them off a horizontal scroll. The scroll it replaced
    /// carried `showsIndicators: false` inside a centred, capped reading column, so there
    /// was nothing on screen to say the row continued. Re-introducing it, even with an
    /// indicator, is the fallback UX51 explicitly ranked second (and only with a visible
    /// edge fade, the UX47 shape), so it is worth having to argue past this fence.
    func test_the_strip_wraps_its_chips_rather_than_scrolling_them() throws {
        let bar = code(try daemonSource("Sources/MeetingPipe/VoiceResolutionBar.swift"))
        XCTAssertTrue(bar.contains("FlowLayout(spacing:"),
                      "the chips ride the shared wrapping layout")
        XCTAssertFalse(bar.contains("ScrollView("),
                       "a scroll inside the capped reading measure is the shipped-and-rejected form")
    }
}
