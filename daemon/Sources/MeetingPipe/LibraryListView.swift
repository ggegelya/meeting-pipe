import SwiftUI

/// Chronological list of every meeting in the recordings dir, narrowed
/// by the rail's smart-folder scope and the in-list filter chips.
/// Grouped by relative date (Today / Yesterday / This week / Last week
/// / Month). The store auto-refreshes via a directory watcher.
struct LibraryListView: View {
    @ObservedObject var store: MeetingStore
    @ObservedObject var libraryModel: LibraryWindowModel
    /// Smart-folder scope driven by the rail. Applied *before* the
    /// in-list filter chips, so the two compose: e.g. scope = "Client
    /// work", chips = "App: Zoom" → only Client-work meetings recorded
    /// from Zoom.
    let scope: LibraryScope
    /// Current workflow snapshot. Needed by the scope predicate so the
    /// NDA / workflow scopes can resolve a meeting's workflow → flags.
    let workflows: [Workflow]
    @Binding var selection: Set<Meeting.ID>
    @State private var filter: MeetingFilter = MeetingFilter()

    var body: some View {
        Group {
            if !store.hasLoadedOnce {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.meetings.isEmpty {
                LibraryEmptyState()
            } else {
                VStack(spacing: 0) {
                    scopeHeader
                    Divider()
                    FilterBarView(
                        filter: $filter,
                        facets: MeetingFacets.build(from: scopedMeetings),
                        matchCount: filteredMeetings.count,
                        totalCount: scopedMeetings.count
                    )
                    Divider()
                    if filteredMeetings.isEmpty {
                        noMatchesState
                    } else {
                        listBody
                    }
                }
            }
        }
        .frame(minWidth: 320)
        .navigationSplitViewColumnWidth(min: 280, ideal: 380)
    }

    /// Scope header — title + count, mirroring the prototype's
    /// "All meetings / 42 meetings" treatment. Resolves the title for
    /// workflow scopes by looking the workflow up in the snapshot.
    @ViewBuilder
    private var scopeHeader: some View {
        let count = filteredMeetings.count
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(scopeTitle)
                    .font(.system(size: 17, weight: .semibold))
                Text("\(count) meeting\(count == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var scopeTitle: String {
        if case .workflow(let id) = scope,
           let wf = workflows.first(where: { $0.id == id }) {
            return wf.name
        }
        return scope.title
    }

    /// Meetings narrowed by the rail scope. The chip filter runs on top.
    private var scopedMeetings: [Meeting] {
        if case .allMeetings = scope { return store.meetings }
        return store.meetings.filter { scope.includes($0, workflows: workflows) }
    }

    private var filteredMeetings: [Meeting] {
        MeetingFilterEngine.apply(filter, to: scopedMeetings)
    }

    private var noMatchesState: some View {
        VStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("No meetings match this filter")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Clear filter") { filter = MeetingFilter() }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private var listBody: some View {
        List(selection: $selection) {
            ForEach(groupedMeetings, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.meetings) { meeting in
                        MeetingRow(
                            meeting: meeting,
                            isLiveRecording: libraryModel.liveRecordingStem == meeting.stem,
                            onRepublish: { [weak libraryModel] in
                                _ = await libraryModel?.republishMeeting(stem: meeting.stem)
                            },
                            onRegenerate: { [weak libraryModel] in
                                _ = await libraryModel?.regenerateMeeting(stem: meeting.stem)
                            },
                            onRetry: { [weak libraryModel] in
                                libraryModel?.retryMeeting(stem: meeting.stem)
                                    ?? .failure(NSError(domain: "LibraryListView", code: 1))
                            },
                            onSoftDelete: { [weak libraryModel] in
                                _ = libraryModel?.softDeleteMeeting(stem: meeting.stem)
                            },
                            onExport: { [weak libraryModel] dest in
                                libraryModel?.exportMeeting(stem: meeting.stem, to: dest)
                                    ?? .failure(NSError(domain: "LibraryListView", code: 1))
                            }
                        )
                        .equatable()
                        .tag(meeting.id)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private var groupedMeetings: [MeetingGroup] {
        MeetingGroup.group(filteredMeetings, now: Date())
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
