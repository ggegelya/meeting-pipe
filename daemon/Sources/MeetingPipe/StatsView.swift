import SwiftUI

/// AI8: the Meeting time projection. Where the hours went, per workflow, over a
/// range you pick, plus how much of the talking was yours. Rendered in the
/// Library's center column when the `.stats` rail scope is active, the same shape
/// Facts and People use.
///
/// Read-only and fully local: every number comes off sidecars already on disk
/// (`MeetingStore`'s rows for the lengths and workflow tags, `<stem>.json` for
/// the speech split). No engine call, no network, nothing written.
///
/// The derivation is `MeetingStats.derive`; this view does the I/O and the
/// chrome. Deliberately a table and not a dashboard: no bars, no trend lines, no
/// targets, no streaks. The 2026-06-26 UX research kept a self-directed talk-time
/// view in register and put the coaching-shaped rest of that family out of it.
struct StatsView: View {
    @ObservedObject var store: MeetingStore
    /// `summarization.user_label`, the display name the pipeline stamps on your
    /// own diarized speaker. Empty when it was never configured, which is what
    /// makes every talk share unmeasurable, so the footer says so.
    let ownerLabel: String

    @State private var range: MeetingStats.Range = .last30
    @State private var snapshot: MeetingStats.Snapshot = .empty
    /// The per-meeting facts behind the current snapshot, kept so changing the
    /// range re-derives in memory instead of re-reading 80 MB of transcripts.
    @State private var facts: [MeetingStats.MeetingFacts] = []
    /// stem to its talk measurement, where a present entry holding nil means "read
    /// and unmeasurable". Reading every transcript is the expensive half of this
    /// view (the whole library is roughly 80 MB of `<stem>.json` against under 1 MB
    /// of summaries), and a `MeetingStore` revision bumps on any sidecar write in
    /// the recordings directory, so a pipeline run finishing while this view is open
    /// would otherwise re-parse all of it several times over. A transcript is
    /// written once at finalize; the cache lives only as long as the view, so a
    /// re-transcribe is picked up on the next visit.
    @State private var talkCache: [String: MeetingStats.Talk?] = [:]
    /// The owner name the cache was measured under. Changing it in Preferences
    /// changes who counts as you, so the cache is dropped rather than kept.
    @State private var cachedOwnerLabel = ""
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            rangeBar
            Divider()
            content
        }
        .onAppear(perform: reload)
        .onChange(of: store.revision) { _, _ in reload() }
        .onChange(of: range) { _, _ in rederive() }
    }

    // MARK: - Chrome

    private var rangeBar: some View {
        HStack(spacing: 8) {
            Text("Range")
                .font(.mpTextXS)
                .foregroundStyle(Color(MPColors.fgMuted))
            SettingsSegmented(
                selection: $range,
                options: MeetingStats.Range.allCases.map { ($0, $0.title) }
            )
            .accessibilityLabel("Date range")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if snapshot.rows.isEmpty {
            emptyState
        } else {
            List {
                Section {
                    ForEach(snapshot.rows) { row in
                        StatsRow(row: row, isTotal: false)
                    }
                    if let total = snapshot.total {
                        StatsRow(row: total, isTotal: true)
                    }
                } header: {
                    sectionHeader
                } footer: {
                    footer
                }
            }
            .listStyle(.inset)
        }
    }

    private var sectionHeader: some View {
        HStack {
            Text("Where the time went")
            Spacer()
            Text(MeetingStats.formatMeetings(snapshot.total?.meetings ?? 0))
                .monospacedDigit()
        }
        .font(.mpTextXS.weight(.semibold))
        .tracking(0.08 * 10)
        .textCase(.uppercase)
        .foregroundStyle(Color(MPColors.fgMuted))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock")
                .font(.mpText2XL)
                .foregroundStyle(Color(MPColors.fgSubtle))
            Text("No meetings in \(range.caption).")
                .foregroundStyle(Color(MPColors.fgMuted))
            Text("Recorded meetings are counted here by the workflow they ran under, with your own speaking time read from the transcript.")
                .font(.mpTextXS)
                .foregroundStyle(Color(MPColors.fgSubtle))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// What the numbers do and do not cover. Named rather than assumed, because a
    /// talk share over partial coverage reads as a fact about you when it is
    /// really a fact about the diarizer.
    @ViewBuilder
    private var footer: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Covering \(range.caption). Talk share is speech time from the transcript, counted over speech the diarizer attributed to a voice.")
            if let line = coverageLine {
                Text(line)
            }
        }
        .font(.mpTextXS)
        .foregroundStyle(Color(MPColors.fgSubtle))
        .padding(.top, 6)
    }

    /// How much of the range the talk share actually covers. The wording lives in
    /// `MeetingStats.coverageNote` so a test pins it.
    private var coverageLine: String? {
        guard let total = snapshot.total else { return nil }
        let named = !ownerLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return MeetingStats.coverageNote(total, ownerNamed: named)
    }

    // MARK: - Loading

    /// Rebuild the per-meeting facts off-main, then re-derive. Triggered on appear
    /// and on each `MeetingStore.revision` bump, so a finished pipeline run lands
    /// here. The cache is dropped when the owner name changed, because that
    /// changes who every past measurement counted as you.
    private func reload() {
        let meetings = store.meetings          // value snapshot
        let owner = ownerLabel
        let cache = owner == cachedOwnerLabel ? talkCache : [:]
        Task.detached(priority: .userInitiated) {
            let loaded = StatsLoader.load(meetings: meetings, ownerLabel: owner, cache: cache)
            await MainActor.run {
                self.facts = loaded.facts
                self.talkCache = loaded.cache
                self.cachedOwnerLabel = owner
                self.loading = false
                rederive()
            }
        }
    }

    /// Re-run the pure derivation. No disk read: changing the range changes which
    /// meetings are counted, never what any of them measured.
    private func rederive() {
        snapshot = MeetingStats.derive(meetings: facts, range: range)
    }
}

// MARK: - Rows

/// One workflow's line, or the Total. Same type for both so a column can never
/// mean one thing in the body and another in the total.
private struct StatsRow: View {
    let row: MeetingStats.Row
    let isTotal: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // The rail's own workflow dot, so a row here and a rail scope read as
            // the same workflow. The total has no colour to carry, and keeping the
            // dot invisible rather than absent holds the two name columns aligned.
            // Baseline guide copied from the transcript speaker dot, the shipped
            // 8pt-circle-on-a-text-line case, rather than invented here.
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
                .opacity(isTotal ? 0 : 1)
                .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] }
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(.mpTextBase.weight(isTotal ? .semibold : .regular))
                    .foregroundStyle(Color(MPColors.fg))
                    .lineLimit(1)
                Text(metaLine)
                    .font(.mpTextXS)
                    .foregroundStyle(Color(MPColors.fgSubtle))
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(MeetingStats.formatHours(row.totalSec))
                    .font(.mpTextBase.monospacedDigit().weight(isTotal ? .semibold : .regular))
                    .foregroundStyle(Color(MPColors.fg))
                Text(shareLine)
                    .font(.mpTextXS.monospacedDigit())
                    .foregroundStyle(Color(MPColors.fgSubtle))
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenLabel)
    }

    private var dotColor: Color {
        guard let hex = row.colorHex, let ns = HexColor.parse(hex) else {
            return Color(MPColors.fgFaint)
        }
        return Color(ns)
    }

    /// "9 meetings · 48m average". The average is dropped when nothing in the
    /// bucket carried a length, rather than rendered as a zero.
    private var metaLine: String {
        var parts = [MeetingStats.formatMeetings(row.meetings)]
        if let mean = row.meanSec {
            parts.append("\(MeetingStats.formatHours(mean)) average")
        }
        return parts.joined(separator: " · ")
    }

    /// "you 34%" or "not measured". Never "you 0%": a bucket with no identified
    /// owner voice has no share, and printing zero would assert you sat silent.
    private var shareLine: String {
        guard let share = row.talkShare else { return "not measured" }
        return "you \(MeetingStats.formatShare(share))"
    }

    private var spokenLabel: String {
        "\(row.name), \(MeetingStats.formatHours(row.totalSec)) over \(metaLine), \(shareLine)"
    }
}
