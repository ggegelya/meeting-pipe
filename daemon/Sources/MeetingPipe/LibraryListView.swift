import SwiftUI

/// Chronological list of every meeting in the recordings dir. Grouped
/// by relative date (Today / Yesterday / This week / Last week / Month).
/// The store auto-refreshes via a directory watcher.
struct LibraryListView: View {
    @ObservedObject var store: MeetingStore
    @Binding var selection: Meeting.ID?

    var body: some View {
        Group {
            if !store.hasLoadedOnce {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.meetings.isEmpty {
                LibraryEmptyState()
            } else {
                listBody
            }
        }
        .frame(minWidth: 320)
        .navigationSplitViewColumnWidth(min: 280, ideal: 360)
    }

    private var listBody: some View {
        List(selection: $selection) {
            ForEach(groupedMeetings, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.meetings) { meeting in
                        MeetingRow(meeting: meeting)
                            .tag(Optional(meeting.id))
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private var groupedMeetings: [MeetingGroup] {
        MeetingGroup.group(store.meetings, now: Date())
    }
}

// MARK: - Empty state

struct LibraryEmptyState: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No recordings yet")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Start a meeting in Zoom / Teams / Meet / Webex / Slack, or press ⌃⌥M.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

// MARK: - Grouping

/// A bucket of meetings under a relative-date heading.
struct MeetingGroup {
    let title: String
    let meetings: [Meeting]
    /// Stable ordinal so the bucket order is deterministic without
    /// re-deriving from titles at the call site.
    let order: Int

    /// Partition a list of meetings (already sorted newest-first) into
    /// chronological buckets. Buckets that end up empty are dropped so
    /// the section list stays compact for sparse libraries.
    static func group(_ meetings: [Meeting], now: Date) -> [MeetingGroup] {
        let cal = Calendar.current
        // Anchors computed once so the per-meeting comparison stays cheap.
        let todayStart = cal.startOfDay(for: now)
        let yesterdayStart = cal.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart
        let thisWeekStart = cal.date(
            from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        ) ?? todayStart
        let lastWeekStart = cal.date(byAdding: .weekOfYear, value: -1, to: thisWeekStart) ?? thisWeekStart
        let thisMonthStart = cal.date(
            from: cal.dateComponents([.year, .month], from: now)
        ) ?? todayStart

        var buckets: [Int: (title: String, meetings: [Meeting])] = [:]
        for meeting in meetings {
            let ts = meeting.startedAt
            let key: (Int, String)
            if ts >= todayStart {
                key = (0, "Today")
            } else if ts >= yesterdayStart {
                key = (1, "Yesterday")
            } else if ts >= thisWeekStart {
                key = (2, "This week")
            } else if ts >= lastWeekStart {
                key = (3, "Last week")
            } else if ts >= thisMonthStart {
                key = (4, "Earlier this month")
            } else {
                // Group older meetings by their month label so a year
                // of history stays browsable without a flat older list.
                // ord = 5 + monthsAgo so older buckets sort AFTER the
                // fixed 0..4 buckets, and newer months sort before
                // older ones within the older-months tail.
                let monthAnchor = cal.date(
                    from: cal.dateComponents([.year, .month], from: ts)
                ) ?? ts
                let monthsAgo = max(
                    1,
                    cal.dateComponents([.month], from: monthAnchor, to: thisMonthStart).month ?? 1
                )
                let ord = 5 + monthsAgo
                key = (ord, MeetingFormatters.monthYear.string(from: ts))
            }
            buckets[key.0, default: (title: key.1, meetings: [])].meetings.append(meeting)
        }
        return buckets
            .sorted { $0.key < $1.key }
            .map { MeetingGroup(title: $0.value.title, meetings: $0.value.meetings, order: $0.key) }
    }
}
