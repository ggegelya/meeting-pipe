import Foundation

/// AI8: the Meeting time projection's data layer, lifted out of `StatsView` the
/// way `Facts.swift` is, so the arithmetic is testable without a library on disk.
/// Everything here is pure except `StatsLoader` at the bottom, which owns the one
/// disk read.
///
/// Two questions, both answered from sidecars the pipeline already wrote (ADR
/// 0003, a derived index over files rather than a database of record):
///
///   - **where the hours went**: `<stem>.meta.json`'s workflow name against the
///     meeting's length, which `MeetingStore` already resolved onto every row;
///   - **how much of the talking was yours**: the diarized `<stem>.json`, whose
///     owner speaker the pipeline stamped with `summarization.user_label` off the
///     ADR 0009 stereo split (mic left, system right, so the mic channel is
///     ground truth for "me").
///
/// Deliberately not a dashboard. The 2026-06-26 UX research put talk-ratio
/// coaching, scorecards and trend charts out of register for a single-user local
/// tool and kept exactly one analytic: a self-directed talk-time view. So there
/// are no streaks, no targets, no week-over-week deltas and no per-person
/// breakdown; the numbers describe the range you picked and stop there.
enum MeetingStats {

    // MARK: - Range

    /// The window the numbers cover. Bounded on purpose: an unbounded "since the
    /// beginning" default would make a growing library's number drift a little
    /// every week and mean nothing, so the range is always named on screen.
    enum Range: String, CaseIterable, Identifiable, Hashable {
        case last7
        case last30
        case last90
        case all

        var id: String { rawValue }

        /// Rail / picker label. Sentence case, no "Last" prefix: the picker's own
        /// position says these are windows back from today.
        var title: String {
            switch self {
            case .last7:  return "7 days"
            case .last30: return "30 days"
            case .last90: return "90 days"
            case .all:    return "All time"
            }
        }

        /// The caption under the table, where the window has to read as a sentence
        /// rather than a chip.
        var caption: String {
            switch self {
            case .last7:  return "the last 7 days"
            case .last30: return "the last 30 days"
            case .last90: return "the last 90 days"
            case .all:    return "your whole library"
            }
        }

        var days: Int? {
            switch self {
            case .last7:  return 7
            case .last30: return 30
            case .last90: return 90
            case .all:    return nil
            }
        }

        /// Oldest meeting date the range admits, or nil for `.all`. Day-granular
        /// off the calendar rather than `now - n * 86400`, so a range does not
        /// slide by an hour across a DST boundary.
        func cutoff(now: Date) -> Date? {
            guard let days else { return nil }
            let cal = Calendar.current
            return cal.date(byAdding: .day, value: -days, to: cal.startOfDay(for: now))
        }

        func includes(_ date: Date, now: Date) -> Bool {
            guard let cutoff = cutoff(now: now) else { return true }
            return date >= cutoff
        }
    }

    // MARK: - Talk time

    /// One meeting's (or one bucket's) speech time, split three ways.
    ///
    /// `unattributedSec` is `speaker_unknown`, the diarizer's junk drawer, which
    /// `MeetingCast` is careful to call not-a-person. It is kept out of the ratio
    /// rather than folded into `theirsSec`: speech credited to nobody is not
    /// evidence that somebody else was talking, and quietly counting it as "them"
    /// would understate your share by however badly the diarizer did that day.
    struct Talk: Equatable {
        var mineSec: Double = 0
        var theirsSec: Double = 0
        var unattributedSec: Double = 0

        /// Speech the ratio is computed over: yours plus theirs, excluding the
        /// junk drawer.
        var attributedSec: Double { mineSec + theirsSec }

        /// Your share of attributed speech, 0...1. Nil when nobody attributable
        /// spoke, so a caller renders "not measured" instead of a fabricated 0%.
        var mineShare: Double? {
            attributedSec > 0 ? mineSec / attributedSec : nil
        }

        static let zero = Talk()

        static func + (lhs: Talk, rhs: Talk) -> Talk {
            Talk(
                mineSec: lhs.mineSec + rhs.mineSec,
                theirsSec: lhs.theirsSec + rhs.theirsSec,
                unattributedSec: lhs.unattributedSec + rhs.unattributedSec
            )
        }
    }

    /// The raw label the pipeline leaves on the owner's speaker when no display
    /// name is configured: `mp.diarize.USER_SPEAKER`, the channel-assigned mic
    /// speaker. Mirrored here rather than shared, like every other cross-language
    /// literal the two trees agree on by test rather than by import.
    static let channelOwnerLabel = "speaker_user"

    /// Split one meeting's speech into yours, theirs, and unattributed, or nil
    /// when your voice is not identifiable in it at all.
    ///
    /// Nil is the honest answer for two cases the transcript cannot tell apart:
    /// a meeting you sat silent through, and a meeting where `label_me_speaker`
    /// found no "me" signal (no `user_label` configured, mono audio, a merged
    /// cluster). Returning a zero share instead would read as "you said nothing"
    /// on a meeting you may have run, so the meeting is excluded from the ratio
    /// and counted as unmeasured instead.
    ///
    /// Labels resolve through the same overlay path the Transcript tab renders
    /// with (`SpeakerLabelStore.displayLabel`), so naming a cluster with your own
    /// name in-app counts here too rather than needing a re-transcribe.
    static func talk(
        segments: [TranscriptSegment],
        overlay: SpeakerLabelStore.Overlay,
        ownerLabel: String
    ) -> Talk? {
        let owner = normalized(ownerLabel)
        var talk = Talk.zero
        var sawOwner = false
        for segment in segments {
            let seconds = segment.end - segment.start
            guard seconds > 0 else { continue }
            guard let resolved = SpeakerLabelStore.displayLabel(for: segment, using: overlay) else {
                // No diarization on this line at all: not attributable either way.
                talk.unattributedSec += seconds
                continue
            }
            let key = normalized(resolved)
            if key == channelOwnerLabel || (!owner.isEmpty && key == owner) {
                talk.mineSec += seconds
                sawOwner = true
            } else if MeetingCast.isUnattributedLabel(resolved) {
                talk.unattributedSec += seconds
            } else {
                talk.theirsSec += seconds
            }
        }
        return sawOwner ? talk : nil
    }

    /// Case- and whitespace-insensitive name identity, the same rule `PeopleRail`
    /// uses: `user_label` is a free-text field the owner typed and the pipeline
    /// stamped, so "Heorhii " and "heorhii" are one person.
    static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: - Inputs

    /// One meeting reduced to what the projection needs. Built by the view off the
    /// meeting rows plus one transcript read, and kept separate from `Meeting` so
    /// `derive` is pure.
    struct MeetingFacts: Equatable {
        let stem: String
        let date: Date
        /// The workflow it was recorded under. Nil or empty buckets under
        /// `untaggedName`, matching the rail's own Untagged scope.
        let workflowName: String?
        let workflowColor: String?
        /// Wall-clock length. Nil when neither the audio file nor the transcript's
        /// `audio_seconds` could give one, which is rare but not impossible on a
        /// row whose audio a retention policy reclaimed.
        let durationSec: Double?
        /// Nil when your voice was not identifiable in this meeting (see `talk`).
        let talk: Talk?
    }

    // MARK: - Outputs

    /// One workflow's slice of the range, or the Total line (same shape, so the
    /// view renders both through one row type and the two can never disagree
    /// about what a column means).
    struct Row: Identifiable, Equatable {
        let name: String
        let colorHex: String?
        /// Meetings in the range under this workflow.
        let meetings: Int
        /// How many of those carried a length. `totalSec` is the sum over these.
        let timedMeetings: Int
        let totalSec: Double
        /// How many carried an identifiable owner voice. `talk` is the sum over
        /// these, so the share is honest about its own coverage.
        let measuredMeetings: Int
        let talk: Talk

        var id: String { name }

        /// Mean length over the meetings that had one. Nil when none did.
        var meanSec: Double? {
            timedMeetings > 0 ? totalSec / Double(timedMeetings) : nil
        }

        /// Your share of the speech, seconds-weighted across the bucket rather
        /// than a mean of per-meeting ratios: an hour-long call and a five-minute
        /// standup should not count the same toward "how much do I talk".
        var talkShare: Double? {
            measuredMeetings > 0 ? talk.mineShare : nil
        }

        /// True when at least one meeting in the bucket could not be measured, so
        /// the view can say so rather than implying full coverage.
        var hasUnmeasured: Bool { measuredMeetings < meetings }
    }

    /// What the view renders. `total` is nil only when the range holds nothing.
    struct Snapshot: Equatable {
        var rows: [Row] = []
        var total: Row?
        var range: Range = .last30
        /// False until the first load completes, so the view shows a spinner
        /// rather than an empty state it has not earned (the `FactsSnapshot`
        /// convention).
        var loaded: Bool = false

        static let empty = Snapshot()
    }

    /// The bucket a workflow-less recording lands in, worded to match the rail's
    /// own Untagged scope so the two read as the same set.
    static let untaggedName = "Untagged"

    /// The Total line's name. A constant because it doubles as the row id, and a
    /// workflow genuinely named "Total" would otherwise collide.
    static let totalName = "Total"

    // MARK: - Derivation

    /// Bucket the range's meetings by workflow and total them.
    ///
    /// Rows are ordered by hours, most first: the question the view answers is
    /// "where did the time go", and alphabetical order buries the answer. Ties
    /// fall back to meeting count then name, so the order is stable across
    /// reloads rather than dependent on dictionary iteration.
    static func derive(
        meetings: [MeetingFacts],
        range: Range,
        now: Date = Date()
    ) -> Snapshot {
        var buckets: [String: Row] = [:]
        var total = Row(
            name: totalName, colorHex: nil, meetings: 0, timedMeetings: 0,
            totalSec: 0, measuredMeetings: 0, talk: .zero
        )
        for meeting in meetings where range.includes(meeting.date, now: now) {
            let trimmed = (meeting.workflowName ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let name = trimmed.isEmpty ? untaggedName : trimmed
            let existing = buckets[name] ?? Row(
                name: name, colorHex: nil, meetings: 0, timedMeetings: 0,
                totalSec: 0, measuredMeetings: 0, talk: .zero
            )
            buckets[name] = accumulate(existing, meeting)
            total = accumulate(total, meeting)
        }
        let rows = buckets.values.sorted { lhs, rhs in
            if lhs.totalSec != rhs.totalSec { return lhs.totalSec > rhs.totalSec }
            if lhs.meetings != rhs.meetings { return lhs.meetings > rhs.meetings }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        return Snapshot(
            rows: rows,
            total: rows.isEmpty ? nil : total,
            range: range,
            loaded: true
        )
    }

    /// Fold one meeting into a row. The colour is first-non-empty-wins: every
    /// meeting under a workflow carries the same tint, and a recording made
    /// before the workflow had one should not blank the row.
    private static func accumulate(_ row: Row, _ meeting: MeetingFacts) -> Row {
        let colour: String?
        if let existing = row.colorHex, !existing.isEmpty {
            colour = existing
        } else {
            colour = (meeting.workflowColor?.isEmpty == false) ? meeting.workflowColor : nil
        }
        let duration = meeting.durationSec.map { max(0, $0) }
        return Row(
            name: row.name,
            colorHex: colour,
            meetings: row.meetings + 1,
            timedMeetings: row.timedMeetings + (duration != nil ? 1 : 0),
            totalSec: row.totalSec + (duration ?? 0),
            measuredMeetings: row.measuredMeetings + (meeting.talk != nil ? 1 : 0),
            talk: row.talk + (meeting.talk ?? .zero)
        )
    }

    // MARK: - Formatting

    /// "4h 05m" / "42m" / "under a minute". Hours-and-minutes rather than the
    /// row's `h:mm:ss` timecode, because these are budgets to read at a glance,
    /// not offsets to seek to.
    static func formatHours(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return String(format: "%dh %02dm", hours, minutes) }
        if minutes > 0 { return "\(minutes)m" }
        return "under a minute"
    }

    /// "38%" from a 0...1 share. Whole percent: a tenth of a percent of talk time
    /// is noise, and rendering it would invite reading precision that is not there.
    static func formatShare(_ share: Double) -> String {
        "\(Int((share * 100).rounded()))%"
    }

    /// "9 meetings" / "1 meeting".
    static func formatMeetings(_ count: Int) -> String {
        "\(count) meeting\(count == 1 ? "" : "s")"
    }

    /// How much of the range the talk share actually covers, or nil when it covers
    /// all of it. The view's one dynamic caption, extracted here so its wording is
    /// pinned by a test rather than living inside a private view (the T3 rule: "it
    /// is only presentation" is a reason to lift it, not to skip it).
    ///
    /// Gated on there being something uncovered rather than on the name being
    /// blank, because the two are not the same condition: a transcript from the
    /// channel-aware fallback carries `speaker_user` and measures fine with no name
    /// configured, so leading with "your name is not set" would be false on a
    /// library of those. The name is named as the likely cause, second, and only
    /// when it is actually unset.
    static func coverageNote(_ total: Row, ownerNamed: Bool) -> String? {
        guard total.hasUnmeasured else { return nil }
        let unmeasured = total.meetings - total.measuredMeetings
        let subject: String
        if total.meetings == 1 {
            subject = "This meeting has"
        } else {
            subject = "\(unmeasured) of \(total.meetings) meetings \(unmeasured == 1 ? "has" : "have")"
        }
        var line = subject
            + " no talk share: your voice was not identified in "
            + (unmeasured == 1 ? "it" : "them")
            + ", either because you did not speak or because diarization could not separate you."
        if !ownerNamed {
            line += " Setting your name in Preferences → Pipeline → Your name is what lets the transcript mark your own voice."
        }
        return line
    }
}

// MARK: - Loading

/// The disk half: one `MeetingStats.MeetingFacts` per library row. The workflow
/// tag and the length come straight off the row `MeetingStore` already scanned;
/// only the speech split needs a file read.
///
/// Blocking I/O over the whole library, so call it off-main. It is also the
/// expensive read in this app: the transcripts total roughly 80 MB against under
/// 1 MB of summaries, which is why `PeopleRail` was built to avoid them and why
/// this one carries a cache instead.
enum StatsLoader {

    /// Build the facts, measuring only stems the cache has not seen.
    ///
    /// `cache` maps a stem to its measurement, where a present entry holding nil
    /// means "read, and your voice was not identifiable". Returned alongside the
    /// facts so the caller can hand it back on the next pass: a `MeetingStore`
    /// revision bumps on any sidecar write in the recordings directory, so a
    /// pipeline run finishing while the view is open would otherwise re-parse the
    /// whole library several times over. A transcript is written once at finalize,
    /// so a stale entry needs a re-transcribe to happen, which the view's own
    /// lifetime bounds.
    static func load(
        meetings: [Meeting],
        ownerLabel: String,
        cache: [String: MeetingStats.Talk?] = [:]
    ) -> (facts: [MeetingStats.MeetingFacts], cache: [String: MeetingStats.Talk?]) {
        var measured = cache
        var facts: [MeetingStats.MeetingFacts] = []
        facts.reserveCapacity(meetings.count)
        for meeting in meetings {
            let talk: MeetingStats.Talk?
            if let cached = measured[meeting.stem] {
                talk = cached
            } else {
                talk = measure(meeting: meeting, ownerLabel: ownerLabel)
                measured[meeting.stem] = talk
            }
            facts.append(MeetingStats.MeetingFacts(
                stem: meeting.stem,
                date: meeting.startedAt,
                workflowName: meeting.workflowName,
                workflowColor: meeting.workflowColor,
                durationSec: meeting.durationSec,
                talk: talk
            ))
        }
        return (facts, measured)
    }

    /// One meeting's speech split, or nil when it has no transcript to read. Goes
    /// through the canonical `TranscriptLoader` rather than a second parser, so
    /// this counts exactly the lines the Transcript tab shows, in-app speaker
    /// naming included.
    static func measure(meeting: Meeting, ownerLabel: String) -> MeetingStats.Talk? {
        guard let loaded = TranscriptLoader.load(stem: meeting.stem, in: meeting.recordingsDir)
        else { return nil }
        return MeetingStats.talk(
            segments: loaded.segments,
            overlay: loaded.speakerOverlay,
            ownerLabel: ownerLabel
        )
    }
}
