import XCTest
@testable import MeetingPipe

/// AI8's quiet analytics. Two halves, both of which can lie quietly if they are
/// wrong: the bucketing (hours credited to the wrong workflow, or a range that
/// silently slides), and the talk split (a share that reads as a fact about the
/// owner when it is really a fact about how well diarization went that day).
final class MeetingStatsTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func daysAgo(_ n: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -n, to: now)!
    }

    private func facts(
        stem: String = "m",
        daysAgo n: Int = 0,
        workflow: String? = "Client work",
        color: String? = "#0C7F74",
        duration: Double? = 3600,
        talk: MeetingStats.Talk? = nil
    ) -> MeetingStats.MeetingFacts {
        MeetingStats.MeetingFacts(
            stem: stem, date: daysAgo(n), workflowName: workflow,
            workflowColor: color, durationSec: duration, talk: talk
        )
    }

    private func segment(
        _ index: Int, _ start: Double, _ end: Double, _ speaker: String?
    ) -> TranscriptSegment {
        TranscriptSegment(index: index, start: start, end: end, text: "x", speakerID: speaker)
    }

    // MARK: - Bucketing

    func test_derive_buckets_by_workflow_and_sums_hours() {
        let snapshot = MeetingStats.derive(
            meetings: [
                facts(stem: "a", workflow: "Client work", duration: 3600),
                facts(stem: "b", workflow: "Client work", duration: 1800),
                facts(stem: "c", workflow: "Internal", duration: 900),
            ],
            range: .all, now: now
        )
        XCTAssertEqual(snapshot.rows.map(\.name), ["Client work", "Internal"])
        XCTAssertEqual(snapshot.rows[0].totalSec, 5400)
        XCTAssertEqual(snapshot.rows[0].meetings, 2)
        XCTAssertEqual(snapshot.rows[1].totalSec, 900)
        XCTAssertEqual(snapshot.total?.meetings, 3)
        XCTAssertEqual(snapshot.total?.totalSec, 6300)
    }

    func test_derive_buckets_missing_and_blank_workflow_as_untagged() {
        let snapshot = MeetingStats.derive(
            meetings: [
                facts(stem: "a", workflow: nil, duration: 60),
                facts(stem: "b", workflow: "   ", duration: 60),
            ],
            range: .all, now: now
        )
        XCTAssertEqual(snapshot.rows.map(\.name), [MeetingStats.untaggedName])
        XCTAssertEqual(snapshot.rows[0].meetings, 2)
    }

    func test_derive_orders_by_hours_then_meetings_then_name() {
        let snapshot = MeetingStats.derive(
            meetings: [
                facts(stem: "a", workflow: "Small", duration: 60),
                facts(stem: "b", workflow: "Big", duration: 600),
                // Same hours as Small, more meetings, so it sorts above it.
                facts(stem: "c", workflow: "Busy", duration: 30),
                facts(stem: "d", workflow: "Busy", duration: 30),
            ],
            range: .all, now: now
        )
        XCTAssertEqual(snapshot.rows.map(\.name), ["Big", "Busy", "Small"])
    }

    func test_derive_orders_equal_buckets_by_name_case_insensitively() {
        let snapshot = MeetingStats.derive(
            meetings: [
                facts(stem: "a", workflow: "zeta", duration: 60),
                facts(stem: "b", workflow: "Alpha", duration: 60),
            ],
            range: .all, now: now
        )
        XCTAssertEqual(snapshot.rows.map(\.name), ["Alpha", "zeta"])
    }

    func test_derive_keeps_the_first_non_empty_workflow_colour() {
        // A recording made before the workflow had a tint must not blank the row.
        let snapshot = MeetingStats.derive(
            meetings: [
                facts(stem: "a", color: nil),
                facts(stem: "b", color: "#0C7F74"),
            ],
            range: .all, now: now
        )
        XCTAssertEqual(snapshot.rows[0].colorHex, "#0C7F74")
    }

    func test_derive_on_an_empty_range_has_no_total_row() {
        let snapshot = MeetingStats.derive(
            meetings: [facts(daysAgo: 60)], range: .last7, now: now
        )
        XCTAssertTrue(snapshot.rows.isEmpty)
        XCTAssertNil(snapshot.total)
        XCTAssertTrue(snapshot.loaded)
    }

    // MARK: - Range

    func test_range_is_day_granular_not_a_rolling_24h_multiple() {
        // 7 days back from the start of today, so a meeting early on day 7 is in.
        let edge = Calendar.current.date(
            byAdding: .hour, value: 3, to: MeetingStats.Range.last7.cutoff(now: now)!
        )!
        XCTAssertTrue(MeetingStats.Range.last7.includes(edge, now: now))
        XCTAssertFalse(MeetingStats.Range.last7.includes(daysAgo(8), now: now))
    }

    func test_all_range_admits_everything() {
        XCTAssertNil(MeetingStats.Range.all.cutoff(now: now))
        XCTAssertTrue(MeetingStats.Range.all.includes(daysAgo(4000), now: now))
    }

    func test_derive_filters_to_the_range() {
        let meetings = [
            facts(stem: "a", daysAgo: 1, duration: 60),
            facts(stem: "b", daysAgo: 20, duration: 60),
            facts(stem: "c", daysAgo: 200, duration: 60),
        ]
        XCTAssertEqual(MeetingStats.derive(meetings: meetings, range: .last7, now: now).total?.meetings, 1)
        XCTAssertEqual(MeetingStats.derive(meetings: meetings, range: .last30, now: now).total?.meetings, 2)
        XCTAssertEqual(MeetingStats.derive(meetings: meetings, range: .all, now: now).total?.meetings, 3)
    }

    // MARK: - Durations

    func test_a_meeting_without_a_length_still_counts_as_a_meeting() {
        // A row whose audio a retention policy reclaimed and whose transcript
        // carried no `audio_seconds`. It happened; it just cannot be timed.
        let snapshot = MeetingStats.derive(
            meetings: [facts(stem: "a", duration: 3600), facts(stem: "b", duration: nil)],
            range: .all, now: now
        )
        let row = snapshot.rows[0]
        XCTAssertEqual(row.meetings, 2)
        XCTAssertEqual(row.timedMeetings, 1)
        XCTAssertEqual(row.totalSec, 3600)
        // The average is over what was actually timed, not diluted by the untimed one.
        XCTAssertEqual(row.meanSec, 3600)
    }

    func test_mean_is_nil_when_nothing_was_timed() {
        let snapshot = MeetingStats.derive(
            meetings: [facts(duration: nil)], range: .all, now: now
        )
        XCTAssertNil(snapshot.rows[0].meanSec)
    }

    func test_a_negative_duration_is_clamped_rather_than_subtracting_hours() {
        // `MeetingStore` derives length from an mtime, so a clock change could in
        // principle produce one. It must never make the total go down.
        let snapshot = MeetingStats.derive(
            meetings: [facts(stem: "a", duration: 600), facts(stem: "b", duration: -60)],
            range: .all, now: now
        )
        XCTAssertEqual(snapshot.rows[0].totalSec, 600)
    }

    // MARK: - Talk share

    func test_talk_share_is_seconds_weighted_not_a_mean_of_ratios() {
        // A two-hour call the owner barely spoke in, and a two-minute one they
        // filled. Averaging the ratios would say 50%; the honest answer is 3%.
        let snapshot = MeetingStats.derive(
            meetings: [
                facts(stem: "a", talk: .init(mineSec: 120, theirsSec: 7080)),
                facts(stem: "b", talk: .init(mineSec: 120, theirsSec: 0)),
            ],
            range: .all, now: now
        )
        let share = snapshot.rows[0].talkShare!
        XCTAssertEqual(share, 240.0 / 7320.0, accuracy: 0.0001)
        XCTAssertEqual(MeetingStats.formatShare(share), "3%")
    }

    func test_unmeasured_meetings_are_counted_but_leave_the_share_alone() {
        let snapshot = MeetingStats.derive(
            meetings: [
                facts(stem: "a", talk: .init(mineSec: 100, theirsSec: 100)),
                facts(stem: "b", talk: nil),
            ],
            range: .all, now: now
        )
        let row = snapshot.rows[0]
        XCTAssertEqual(row.meetings, 2)
        XCTAssertEqual(row.measuredMeetings, 1)
        XCTAssertEqual(row.talkShare, 0.5)
        XCTAssertTrue(row.hasUnmeasured)
    }

    func test_share_is_nil_when_nothing_was_measured() {
        // Never zero: a bucket with no identified owner voice has no share, and
        // rendering 0% would assert the owner sat silent through all of it.
        let snapshot = MeetingStats.derive(
            meetings: [facts(talk: nil)], range: .all, now: now
        )
        XCTAssertNil(snapshot.rows[0].talkShare)
        XCTAssertTrue(snapshot.rows[0].hasUnmeasured)
    }

    func test_unattributed_speech_stays_out_of_the_share() {
        // `speaker_unknown` is the diarizer's junk drawer, not a person. Folding
        // it into "them" would understate the owner by however badly the
        // diarizer did.
        let snapshot = MeetingStats.derive(
            meetings: [facts(talk: .init(mineSec: 60, theirsSec: 60, unattributedSec: 600))],
            range: .all, now: now
        )
        XCTAssertEqual(snapshot.rows[0].talkShare, 0.5)
        XCTAssertEqual(snapshot.rows[0].talk.unattributedSec, 600)
    }

    // MARK: - Talk measurement

    func test_talk_identifies_the_owner_by_configured_name() {
        let talk = MeetingStats.talk(
            segments: [
                segment(0, 0, 10, "Heorhii"),
                segment(1, 10, 40, "THEM-A"),
            ],
            overlay: .empty, ownerLabel: "Heorhii"
        )
        XCTAssertEqual(talk?.mineSec, 10)
        XCTAssertEqual(talk?.theirsSec, 30)
        XCTAssertEqual(talk?.mineShare, 0.25)
    }

    func test_talk_matches_the_owner_name_case_and_whitespace_insensitively() {
        let talk = MeetingStats.talk(
            segments: [segment(0, 0, 10, "heorhii"), segment(1, 10, 20, "THEM-A")],
            overlay: .empty, ownerLabel: "  Heorhii "
        )
        XCTAssertEqual(talk?.mineSec, 10)
    }

    func test_talk_falls_back_to_the_channel_assigned_mic_speaker() {
        // `label_me_speaker` leaves `speaker_user` in place when no display name
        // is configured, and that label is still ground truth for "me" (ADR 0009:
        // the mic channel is the owner).
        let talk = MeetingStats.talk(
            segments: [
                segment(0, 0, 30, MeetingStats.channelOwnerLabel),
                segment(1, 30, 40, "THEM-A"),
            ],
            overlay: .empty, ownerLabel: ""
        )
        XCTAssertEqual(talk?.mineSec, 30)
        XCTAssertEqual(talk?.theirsSec, 10)
    }

    func test_talk_is_nil_when_the_owner_never_appears() {
        // Either the owner sat silent or identification failed; the transcript
        // cannot tell those apart, so neither becomes a fabricated 0%.
        XCTAssertNil(MeetingStats.talk(
            segments: [segment(0, 0, 60, "THEM-A"), segment(1, 60, 90, "THEM-B")],
            overlay: .empty, ownerLabel: "Heorhii"
        ))
    }

    func test_talk_is_nil_when_no_owner_name_is_configured_and_no_channel_label_exists() {
        XCTAssertNil(MeetingStats.talk(
            segments: [segment(0, 0, 60, "speaker_0")],
            overlay: .empty, ownerLabel: ""
        ))
    }

    func test_talk_counts_speech_named_as_the_owner_in_app() {
        // FEAT3-UNDO's overlay: the owner named a cluster with their own name
        // rather than re-transcribing. It resolves through the same path the
        // Transcript tab renders with, so it counts here too.
        var overlay = SpeakerLabelStore.Overlay.empty
        overlay.labels["THEM-A"] = "Heorhii"
        let talk = MeetingStats.talk(
            segments: [segment(0, 0, 20, "THEM-A"), segment(1, 20, 40, "THEM-B")],
            overlay: overlay, ownerLabel: "Heorhii"
        )
        XCTAssertEqual(talk?.mineSec, 20)
        XCTAssertEqual(talk?.theirsSec, 20)
    }

    func test_talk_honours_a_per_segment_reassignment() {
        var overlay = SpeakerLabelStore.Overlay.empty
        overlay.segments[1] = "Heorhii"
        let talk = MeetingStats.talk(
            segments: [segment(0, 0, 10, "THEM-A"), segment(1, 10, 20, "THEM-A")],
            overlay: overlay, ownerLabel: "Heorhii"
        )
        XCTAssertEqual(talk?.mineSec, 10)
        XCTAssertEqual(talk?.theirsSec, 10)
    }

    func test_talk_puts_the_junk_drawer_in_its_own_bucket() {
        let talk = MeetingStats.talk(
            segments: [
                segment(0, 0, 10, "Heorhii"),
                segment(1, 10, 20, "speaker_unknown"),
                segment(2, 20, 30, "THEM-A"),
            ],
            overlay: .empty, ownerLabel: "Heorhii"
        )
        XCTAssertEqual(talk?.mineSec, 10)
        XCTAssertEqual(talk?.theirsSec, 10)
        XCTAssertEqual(talk?.unattributedSec, 10)
        XCTAssertEqual(talk?.mineShare, 0.5)
    }

    func test_talk_treats_an_unlabelled_line_as_unattributed() {
        // Diarization off or failed: `speakerID` is nil, so the line is nobody's.
        let talk = MeetingStats.talk(
            segments: [segment(0, 0, 10, "Heorhii"), segment(1, 10, 30, nil)],
            overlay: .empty, ownerLabel: "Heorhii"
        )
        XCTAssertEqual(talk?.mineSec, 10)
        XCTAssertEqual(talk?.theirsSec, 0)
        XCTAssertEqual(talk?.unattributedSec, 20)
    }

    func test_talk_skips_zero_and_negative_length_segments() {
        let talk = MeetingStats.talk(
            segments: [
                segment(0, 5, 5, "Heorhii"),
                segment(1, 10, 4, "THEM-A"),
                segment(2, 20, 30, "Heorhii"),
            ],
            overlay: .empty, ownerLabel: "Heorhii"
        )
        XCTAssertEqual(talk?.mineSec, 10)
        XCTAssertEqual(talk?.theirsSec, 0)
    }

    // MARK: - Formatting

    func test_formatHours_reads_as_a_budget_not_a_timecode() {
        XCTAssertEqual(MeetingStats.formatHours(0), "under a minute")
        XCTAssertEqual(MeetingStats.formatHours(45), "under a minute")
        XCTAssertEqual(MeetingStats.formatHours(2 * 60), "2m")
        XCTAssertEqual(MeetingStats.formatHours(4 * 3600 + 5 * 60), "4h 05m")
    }

    func test_formatShare_rounds_to_whole_percent() {
        XCTAssertEqual(MeetingStats.formatShare(0), "0%")
        XCTAssertEqual(MeetingStats.formatShare(0.335), "34%")
        XCTAssertEqual(MeetingStats.formatShare(1), "100%")
    }

    func test_formatMeetings_singularises() {
        XCTAssertEqual(MeetingStats.formatMeetings(1), "1 meeting")
        XCTAssertEqual(MeetingStats.formatMeetings(0), "0 meetings")
        XCTAssertEqual(MeetingStats.formatMeetings(9), "9 meetings")
    }

    // MARK: - Coverage note

    private func total(of meetings: [MeetingStats.MeetingFacts]) -> MeetingStats.Row {
        MeetingStats.derive(meetings: meetings, range: .all, now: now).total!
    }

    func test_full_coverage_says_nothing() {
        let row = total(of: [facts(talk: .init(mineSec: 10, theirsSec: 10))])
        XCTAssertNil(MeetingStats.coverageNote(row, ownerNamed: true))
    }

    func test_coverage_note_agrees_with_its_own_number() {
        let row = total(of: [
            facts(stem: "a", talk: .init(mineSec: 10, theirsSec: 10)),
            facts(stem: "b", talk: nil),
            facts(stem: "c", talk: nil),
        ])
        let note = MeetingStats.coverageNote(row, ownerNamed: true)
        XCTAssertEqual(note?.hasPrefix("2 of 3 meetings have no talk share"), true)
        XCTAssertEqual(note?.contains("in them"), true)
    }

    func test_coverage_note_singularises_the_uncovered_count() {
        let row = total(of: [
            facts(stem: "a", talk: .init(mineSec: 10, theirsSec: 10)),
            facts(stem: "b", talk: nil),
        ])
        let note = MeetingStats.coverageNote(row, ownerNamed: true)
        XCTAssertEqual(note?.hasPrefix("1 of 2 meetings has no talk share"), true)
        XCTAssertEqual(note?.contains("in it,"), true)
    }

    func test_coverage_note_avoids_one_of_one() {
        let row = total(of: [facts(talk: nil)])
        XCTAssertEqual(
            MeetingStats.coverageNote(row, ownerNamed: true)?.hasPrefix("This meeting has"), true
        )
    }

    func test_coverage_note_names_the_missing_owner_name_only_when_it_is_missing() {
        let row = total(of: [facts(talk: nil)])
        XCTAssertEqual(
            MeetingStats.coverageNote(row, ownerNamed: false)?.contains("Preferences"), true
        )
        XCTAssertEqual(
            MeetingStats.coverageNote(row, ownerNamed: true)?.contains("Preferences"), false
        )
    }

    func test_coverage_note_stays_silent_when_a_nameless_owner_was_measured_anyway() {
        // A channel-fallback transcript carries `speaker_user`, which measures
        // fine with no name set, so a library of those must not be told its
        // configuration is wrong.
        let row = total(of: [facts(talk: .init(mineSec: 10, theirsSec: 10))])
        XCTAssertNil(MeetingStats.coverageNote(row, ownerNamed: false))
    }

    // MARK: - Rail wiring

    func test_stats_scope_is_a_projection_not_a_list_filter() {
        let meeting = Meeting(
            stem: "a", startedAt: now,
            audioURL: URL(fileURLWithPath: "/tmp/a.wav"),
            recordingsDir: URL(fileURLWithPath: "/tmp"),
            summaryTitle: nil, meetingTitle: nil,
            sourceBundleID: nil, sourceDisplayName: nil, sourceKind: nil,
            workflowName: nil, workflowColor: nil,
            durationSec: nil, backend: nil, modelId: nil,
            status: .done, failureReason: nil, failureStage: nil,
            searchableText: ""
        )
        XCTAssertFalse(LibraryScope.stats.includes(meeting, workflows: [], now: now))
        XCTAssertEqual(LibraryScope.stats.title, "Meeting time")
        XCTAssertEqual(ScopeCounts.zero.count(for: .stats), 0)
        XCTAssertTrue(LibrarySidebar.insightsSections.contains(.stats))
    }

    func test_stats_scope_cannot_be_saved_as_a_smart_folder() {
        // Like the other projections: there is no meeting list to persist.
        XCTAssertNil(SavedSearch.capture(
            name: "Time", scope: .stats, liveFilter: MeetingFilter(),
            workflows: [], savedSearches: [], order: 0
        ))
    }
}
