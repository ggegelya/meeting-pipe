import SwiftUI

/// Chronological meeting list, narrowed by the rail scope and filter chips, grouped by relative date. Auto-refreshes via the directory watcher.
struct LibraryListView: View {
    @ObservedObject var store: MeetingStore
    @ObservedObject var libraryModel: LibraryWindowModel
    /// Rail scope applied before the filter chips so the two compose (scope narrows first, chips narrow within).
    let scope: LibraryScope
    /// Workflow snapshot needed by the NDA and workflow scope predicates.
    let workflows: [Workflow]
    @Binding var selection: Set<Meeting.ID>
    @State private var filter: MeetingFilter = MeetingFilter()

    /// Cached derived state, recomputed only when the (revision, scope, workflowsCount, filter) fingerprint changes. Without this, each body re-execution ran six O(n) walks over the meeting array.
    @State private var derived: DerivedList = .empty
    @State private var lastDerivedKey: DerivedKey = .empty

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
                        facets: derived.facets,
                        matchCount: derived.filtered.count,
                        totalCount: derived.scoped.count
                    )
                    Divider()
                    if derived.filtered.isEmpty {
                        emptyListState
                    } else {
                        listBody
                    }
                }
            }
        }
        // Floor for the no-`workflowStore` fallback, where this view is shown
        // outside the split. In the split, the column width is set at the call
        // site in `LibraryWindow` (the single source of truth, TECH-UX11).
        .frame(minWidth: LibraryLayout.listMinWidth)
        .onAppear { recomputeDerived() }
        .onChange(of: store.revision) { _, _ in recomputeDerived() }
        .onChange(of: scope) { _, _ in recomputeDerived() }
        .onChange(of: workflows.count) { _, _ in recomputeDerived() }
        .onChange(of: filter) { _, _ in recomputeDerived() }
    }

    /// Scope header: title + count. Workflow scopes resolve the title via the snapshot.
    @ViewBuilder
    private var scopeHeader: some View {
        let count = derived.filtered.count
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(scopeTitle)
                    .font(.system(size: 17, weight: .semibold))
                Text("\(count) meeting\(count == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(MPColors.fgMuted))
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

    /// Recompute the derived list state, guarded by the fingerprint so unrelated re-renders don't run the filter/group chain.
    private func recomputeDerived() {
        let key = DerivedKey(
            storeRevision: store.revision,
            scope: scope,
            workflowsCount: workflows.count,
            filter: filter
        )
        if key == lastDerivedKey { return }
        lastDerivedKey = key

        let scoped: [Meeting]
        if case .allMeetings = scope {
            scoped = store.meetings
        } else {
            scoped = store.meetings.filter { scope.includes($0, workflows: workflows) }
        }
        let filtered = MeetingFilterEngine.apply(filter, to: scoped)
        let facets = MeetingFacets.build(from: scoped)
        let groups = MeetingGroup.group(filtered, now: Date())
        derived = DerivedList(
            scoped: scoped,
            filtered: filtered,
            facets: facets,
            groups: groups
        )
    }

    private struct DerivedList {
        var scoped: [Meeting]
        var filtered: [Meeting]
        var facets: MeetingFacets
        var groups: [MeetingGroup]
        static let empty = DerivedList(
            scoped: [], filtered: [],
            facets: MeetingFacets(workflows: [], sources: []),
            groups: []
        )
    }

    private struct DerivedKey: Equatable {
        let storeRevision: Int
        let scope: LibraryScope
        let workflowsCount: Int
        let filter: MeetingFilter
        static let empty = DerivedKey(
            storeRevision: -1,
            scope: .allMeetings,
            workflowsCount: 0,
            filter: MeetingFilter()
        )
    }

    /// Empty list column: a positive "Nothing needs you" for the new attention
    /// scope when it is clear, otherwise the no-search-results state (TECH-DSN17).
    @ViewBuilder
    private var emptyListState: some View {
        if case .needsYou = scope, filter.isEmpty {
            LibraryListEmptyState(
                systemImage: "checkmark.circle",
                title: "Nothing needs you",
                message: "Failed, unpublished, and paste-pending meetings show up here."
            )
        } else {
            LibraryListEmptyState(
                systemImage: "line.3.horizontal.decrease.circle",
                title: "No meetings match",
                message: "Try a different search, or clear the filters.",
                actionTitle: "Clear filter",
                action: { filter = MeetingFilter() }
            )
        }
    }

    /// Live-recording + actively-processing meetings, pinned above the
    /// chronological groups in the All-meetings scope only (TECH-DSN17). Driven
    /// off the model's live flags, not re-derived from on-disk status.
    private var inProgressMeetings: [Meeting] {
        guard case .allMeetings = scope else { return [] }
        return derived.filtered.filter {
            $0.stem == libraryModel.liveRecordingStem
                || $0.stem == libraryModel.activeProcessing?.stem
        }
    }

    private var listBody: some View {
        // Pin live/processing rows once; drop their stems from the date groups so
        // a meeting never renders in two places.
        let pinned = inProgressMeetings
        let pinnedStems = Set(pinned.map(\.stem))
        return List(selection: $selection) {
            if !pinned.isEmpty {
                Section("In progress") {
                    ForEach(pinned) { meeting in
                        row(for: meeting)
                    }
                }
            }
            ForEach(derived.groups, id: \.title) { group in
                let rows = group.meetings.filter { !pinnedStems.contains($0.stem) }
                if !rows.isEmpty {
                    Section(group.title) {
                        ForEach(rows) { meeting in
                            row(for: meeting)
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
        // TECH-DSN5: settle the selection rather than snapping it. One of the
        // three sanctioned animation moments (with the HUD degraded grow/shrink
        // and the prompt fade-in); restraint elsewhere is deliberate.
        .animation(.easeOut(duration: MPMotion.durFast), value: selection)
    }

    /// One list row. Factored so the pinned "In progress" section and the date
    /// groups build identical rows from one site.
    private func row(for meeting: Meeting) -> some View {
        MeetingRow(
            meeting: meeting,
            isLiveRecording: libraryModel.liveRecordingStem == meeting.stem,
            activeProcessing: libraryModel.activeProcessing?.stem == meeting.stem
                ? libraryModel.activeProcessing : nil,
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
            },
            onCancelProcessing: { [weak libraryModel] in
                libraryModel?.cancelProcessing()
            },
            isSelected: selection.contains(meeting.id)
        )
        .equatable()
        .tag(meeting.id)
        // Neutralize the native (system-blue) selection paint; MeetingRow's own
        // rowBackground draws the teal selection wash instead (DESIGN No-System-Blue).
        .listRowBackground(Color.clear)
    }

}

// MARK: - Empty state

struct LibraryEmptyState: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 48))
                .foregroundStyle(Color(MPColors.fgSubtle))
            Text("No recordings yet")
                .font(.title3)
                .foregroundStyle(Color(MPColors.fgMuted))
            Text("Start a meeting in Zoom / Teams / Meet / Webex / Slack, or press ⌃⌥M.")
                .font(.callout)
                .foregroundStyle(Color(MPColors.fgSubtle))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

/// Reusable centred empty state for the list column (TECH-DSN17): an icon, a
/// title, a one-line message, and an optional action button. Replaces the ad-hoc
/// no-matches VStack and serves the new "Nothing needs you" state.
struct LibraryListEmptyState: View {
    let systemImage: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 26))
                .foregroundStyle(Color(MPColors.fgSubtle))
                .padding(.bottom, 2)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Color(MPColors.fgMuted))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
                    .padding(.top, 6)
            }
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
    /// Stable ordinal so bucket order is deterministic without re-deriving from titles.
    let order: Int

    /// Partition a newest-first meeting list into chronological buckets, dropping empty ones.
    static func group(_ meetings: [Meeting], now: Date) -> [MeetingGroup] {
        let cal = Calendar.current
        // Compute anchors once; per-meeting comparisons are cheap integer comparisons.
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
                // Group by month label for browsable history. ord = 5 + monthsAgo places older months after the fixed 0..4 buckets, newest month first.
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
