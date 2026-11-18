import AppKit
import SwiftUI

/// Chronological meeting list, narrowed by the rail scope and filter chips, grouped by relative date. Auto-refreshes via the directory watcher.
struct LibraryListView: View {
    @ObservedObject var store: MeetingStore
    @ObservedObject var libraryModel: LibraryWindowModel
    /// Rail scope applied before the filter chips so the two compose (scope narrows first, chips narrow within).
    let scope: LibraryScope
    /// Workflow snapshot needed by the NDA and workflow scope predicates.
    let workflows: [Workflow]
    /// The folder behind a `.saved` scope (UX24), resolved by the root. Nil for every
    /// other scope, and for a folder that was deleted out from under the selection.
    var savedSearch: SavedSearch? = nil
    /// UX24: open the naming sheet for the current view. Nil when the scope has no list
    /// to save. The root owns the sheet and reads `filter` directly.
    var onSaveSmartFolder: (() -> Void)? = nil
    @Binding var selection: Set<Meeting.ID>
    /// Owned by `LibraryRootView` (UX24), which needs the live chips to save or update a
    /// smart folder. It already owns `scope`, and the two are peer state.
    @Binding var filter: MeetingFilter

    /// Cached derived state, recomputed only when the (revision, scope, workflowsCount, filter) fingerprint changes. Without this, each body re-execution ran six O(n) walks over the meeting array.
    @State private var derived: DerivedList = .empty
    @State private var lastDerivedKey: DerivedKey = .empty
    /// PERF20: the free-text query the list currently reflects and the FTS answers computed for it
    /// (and for a selected folder's query). Written only by `resolveSearch`'s delivery.
    @State private var settled = SettledSearch()
    /// PERF9: the list's own click/arrow selection rules (the `List` that supplied them is gone).
    @State private var nav = MeetingListSelection()
    @FocusState private var listFocused: Bool

    private struct SettledSearch {
        var query: String = ""
        var matches: FTSLookup.Results = [:]
        var generation: Int = 0
    }

    private var placeholder: LibraryListPlaceholder {
        LibraryListPlaceholder.decide(
            hasLoadedOnce: store.hasLoadedOnce, isEmpty: store.meetings.isEmpty,
            rootState: store.rootState, root: store.recordingsDir
        )
    }

    var body: some View {
        Group {
            switch placeholder {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .firstRun:
                LibraryEmptyState()
            case .missingRoot(let path):
                // UX89: a configured root that is not there is not a first run.
                LibraryListEmptyState(
                    systemImage: "folder.badge.questionmark",
                    title: "Your recordings folder is not at \(path)",
                    message: "It may have been moved, renamed, or be on a drive that is not connected. Choose the folder that holds your recordings.",
                    actionTitle: "Choose folder…",
                    action: { libraryModel.chooseLibraryFolder() }
                )
            case .unreadableRoot(let path, let reason, let permission):
                // STOR11: a folder that is there and cannot be read is not an empty library.
                LibraryListEmptyState(
                    systemImage: "lock.trianglebadge.exclamationmark",
                    title: "Can't read your recordings folder at \(path): \(reason)",
                    message: permission
                        ? "MeetingPipe needs access to this folder. Allow it under Files and Folders in Privacy & Security; the Library updates once it can read the folder."
                        : "Nothing has been deleted. Check the folder in Finder; the Library updates once it can read it.",
                    actionTitle: permission ? "Open Privacy & Security" : "Reveal in Finder",
                    action: {
                        if permission {
                            LibraryRootRemedy.openPrivacySettings()
                        } else {
                            NSWorkspace.shared.activateFileViewerSelecting([store.recordingsDir])
                        }
                    }
                )
            case .none:
                VStack(spacing: 0) {
                    scopeHeader
                    Divider()
                    FilterBarView(
                        filter: $filter,
                        facets: derived.facets,
                        matchCount: derived.filtered.count,
                        totalCount: derived.scoped.count,
                        onSaveSmartFolder: onSaveSmartFolder
                    )
                    searchHintStrip
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
        .onAppear {
            // The view is rebuilt on a trip through Ask or Digests; pick the selection up again so
            // Shift-click and the arrows have their anchor.
            nav.adopt(selection)
            recomputeDerived()
            resolveSearch(debounced: false)
        }
        .onChange(of: store.revision) { _, _ in recomputeDerived() }
        // PERF9: the pinned "In progress" block is part of the derived sections, so what pins a
        // meeting (the live recording, the active job, the queue) re-derives them.
        .onChange(of: pinnedInputs) { _, _ in recomputeDerived() }
        // A selection changed from outside (Quick Find, a recent-meeting click, the rail).
        .onChange(of: selection) { _, new in nav.adopt(new) }
        .onChange(of: scope) { _, _ in recomputeDerived() }
        .onChange(of: workflows.count) { _, _ in recomputeDerived() }
        // PERF30: chips and typed text re-derive at once against the in-memory corpus; the FTS
        // answer for the typed text joins when `settled.generation` bumps.
        .onChange(of: filter) { _, _ in recomputeDerived() }
        .onChange(of: filter.query) { _, _ in resolveSearch(debounced: true) }
        .onChange(of: libraryModel.searchIndexRevision) { _, _ in resolveSearch(debounced: false) }
        .onChange(of: settled.generation) { _, _ in recomputeDerived() }
        // UX24: "Update to current view" rewrites the folder under a live selection.
        .onChange(of: savedSearch) { _, _ in
            recomputeDerived()
            resolveSearch(debounced: false)
        }
    }

    /// PERF20: look up the typed query (and the selected folder's own query) in the FTS index off
    /// main, debounced while typing, and re-derive when the answer lands. Until then the list shows
    /// the typed text's in-memory matches (PERF30) and the transcript-depth rows join on delivery,
    /// so the lookup is issued once per pause rather than per keystroke. An empty or
    /// one-character query needs no lookup and settles at once.
    private func resolveSearch(debounced: Bool) {
        let typed = filter.query
        var queries = [typed]
        if let folderQuery = savedSearch?.filter.query { queries.append(folderQuery) }
        // The delivery writes `settled` only. This closure holds the view value from when the
        // lookup was issued, so recomputing here would derive from that copy's `scope` and
        // `workflows` and memoize a stale list after a rail click; the `settled.generation`
        // onChange recomputes on the live view instead.
        libraryModel.listLookup.resolve(queries, debounced: debounced) { matches in
            settled = SettledSearch(query: typed, matches: matches, generation: settled.generation &+ 1)
        }
    }

    /// Scope header: title + count. Workflow scopes resolve the title via the snapshot.
    @ViewBuilder
    private var scopeHeader: some View {
        let count = derived.filtered.count
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(scopeTitle)
                    .font(.mpTextLG.weight(.semibold))
                Text("\(count) meeting\(count == 1 ? "" : "s")")
                    .font(.mpTextXS)
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
        // UX24: a saved folder resolves its name the same way, via the store snapshot.
        if case .saved = scope, let savedSearch {
            return savedSearch.name
        }
        return scope.title
    }

    /// UX23: a one-line hint under the filter bar when full-text search is still building or has
    /// degraded, shown only while the user is actually searching (an empty query needs no hint).
    /// Without this, a degraded index silently narrowed to title/summary matches with no signal.
    @ViewBuilder
    private var searchHintStrip: some View {
        if !filter.query.isEmpty, let hint = libraryModel.searchHint {
            let degraded = libraryModel.searchHealth == .degraded
            HStack(spacing: 6) {
                Image(systemName: degraded ? "exclamationmark.triangle" : "clock")
                    .font(.system(size: 10))
                    .foregroundStyle(degraded ? Color.mpWarning : Color(MPColors.fgSubtle))
                Text(hint)
                    .font(.mpTextXS)
                    .foregroundStyle(Color(MPColors.fgMuted))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 6)
        }
    }

    /// Recompute the derived list state, guarded by the fingerprint so unrelated re-renders don't run the filter/group chain.
    private func recomputeDerived() {
        // PERF30: the chips and the free text as typed. Only the FTS answer lags (below): it is
        // merged once the lookup for exactly this text lands.
        let effective = filter
        let key = DerivedKey(
            storeRevision: store.revision,
            scope: scope,
            workflowsCount: workflows.count,
            filter: effective,
            searchGeneration: settled.generation,
            savedSearch: savedSearch,
            day: Calendar.current.startOfDay(for: Date()),
            pinned: pinnedInputs
        )
        if key == lastDerivedKey { return }
        lastDerivedKey = key

        let scoped: [Meeting]
        if case .allMeetings = scope {
            scoped = store.meetings
        } else if case .saved = scope {
            // UX24: a saved folder is a base scope plus its own filter, so it resolves
            // through `SavedSearch.apply` (which needs the FTS index) rather than the
            // pure `scope.includes` predicate. The live filter bar then narrows within
            // it, exactly as it narrows within a built-in scope. A folder deleted out
            // from under the selection resolves to nil and shows nothing, and the root
            // snaps the rail back to All meetings.
            scoped = savedSearch.map {
                $0.apply(
                    to: store.meetings,
                    workflows: workflows,
                    // A folder selected a moment ago has no settled answer yet: nil, so the
                    // in-memory corpus answers until its lookup lands.
                    ftsMatches: settled.matches[$0.filter.query]
                )
            } ?? []
        } else {
            let context = LibraryScope.Context(workflows: workflows)
            scoped = store.meetings.filter { scope.includes($0, in: context) }
        }
        // UX16: the free-text field runs through the FTS index (transcript + summary depth); the
        // chips stay in-memory equality filters inside `apply`. nil = no index / empty or
        // one-character query, so it falls back to the in-memory corpus and search never regresses.
        let filtered = MeetingFilterEngine.apply(
            effective,
            to: scoped,
            ftsMatches: LibrarySearchState.ftsMatches(
                typed: effective.query, settledQuery: settled.query, settledMatches: settled.matches
            )
        )
        let facets = MeetingFacets.build(from: scoped)
        let groups = MeetingGroup.group(filtered, now: Date())
        // PERF9: the rendered sections are built here, once per derive, not in `listBody` on every
        // render: the pinned "In progress" rows lead, and a pinned meeting is dropped from its date
        // group so it never renders in two places. Empty groups are omitted.
        let sections = MeetingListSelection.sections(
            pinned: inProgressMeetings(in: filtered), groups: groups
        ).map { ListSection(title: $0.title, meetings: $0.meetings) }
        derived = DerivedList(
            scoped: scoped,
            filtered: filtered,
            facets: facets,
            groups: groups,
            sections: sections,
            order: sections.flatMap { $0.meetings.map(\.id) }
        )
    }

    private struct DerivedList {
        var scoped: [Meeting]
        var filtered: [Meeting]
        var facets: MeetingFacets
        var groups: [MeetingGroup]
        /// What the list renders, in order (PERF9); `order` is its flat id sequence, which the
        /// selection rules (Shift ranges, arrows) walk.
        var sections: [ListSection]
        var order: [Meeting.ID]
        static let empty = DerivedList(
            scoped: [], filtered: [],
            facets: MeetingFacets(workflows: [], sources: []),
            groups: [], sections: [], order: []
        )
    }

    private struct ListSection: Identifiable {
        let title: String
        let meetings: [Meeting]
        var id: String { title }
    }

    /// What pins a meeting under "In progress": the live recording, the running job and the queue.
    /// Part of the derive key, since the sections are no longer rebuilt on every render.
    private struct PinnedInputs: Equatable {
        var live: String?
        var active: String?
        var queued: Set<String>
    }

    private var pinnedInputs: PinnedInputs {
        // Pinning only exists in All meetings, so other scopes do not re-derive on a queue change.
        guard case .allMeetings = scope else { return PinnedInputs(live: nil, active: nil, queued: []) }
        return PinnedInputs(
            live: libraryModel.liveRecordingStem,
            active: libraryModel.activeProcessing?.stem,
            queued: Set(libraryModel.pendingProcessing.map(\.stem))
        )
    }

    private struct DerivedKey: Equatable {
        let storeRevision: Int
        let scope: LibraryScope
        let workflowsCount: Int
        let filter: MeetingFilter
        /// UX16 / PERF20: bumps each time an FTS lookup settles, including the re-lookup a finished
        /// index build triggers, so a held query re-derives against the now-complete transcript
        /// matches.
        let searchGeneration: Int
        /// UX24: the resolved folder, so "Update to current view" (which keeps the same
        /// scope id) still re-derives.
        let savedSearch: SavedSearch?
        /// PERF22: the Today / Yesterday / This week headings and the date scopes are relative to
        /// the clock, and a rescan that found nothing new no longer bumps the store revision, so a
        /// re-open on a new day regroups on the day rather than waiting for a file to change.
        let day: Date
        /// PERF9: what is pinned under "In progress" when the sections were built.
        let pinned: PinnedInputs
        static let empty = DerivedKey(
            storeRevision: -1,
            scope: .allMeetings,
            workflowsCount: 0,
            filter: MeetingFilter(),
            searchGeneration: -1,
            savedSearch: nil,
            day: .distantPast,
            pinned: PinnedInputs(live: nil, active: nil, queued: [])
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
                message: "Failed, unpublished, partial, no-speech and paste-pending meetings show up here."
            )
        } else if case .saved = scope, filter.isEmpty, let savedSearch {
            // UX24: an empty saved folder is not a failed search, so "Clear filter"
            // would be a dead button. Restate the criteria instead.
            LibraryListEmptyState(
                systemImage: "folder.badge.gearshape",
                title: "Nothing in this folder yet",
                message: "Matches \(SavedSearchSummary.text(for: savedSearch))."
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
    private func inProgressMeetings(in filtered: [Meeting]) -> [Meeting] {
        guard case .allMeetings = scope else { return [] }
        let inputs = pinnedInputs
        return filtered.filter {
            $0.stem == inputs.live
                || $0.stem == inputs.active
                // UX28: a queued meeting is in progress from the user's point of
                // view; leaving it in its date group is what made a second
                // Reprocess click look like nothing happened.
                || inputs.queued.contains($0.stem)
        }
    }

    /// PERF9: a `LazyVStack`, so only the rows on screen are laid out. The `List` it replaced was
    /// an `NSTableView` that measured every row it scrolled to through a full SwiftUI layout and
    /// re-diffed the whole table on each selection or derive (the 2026-10-23 `sample` trace). The
    /// app owns selection and keyboard now: `MeetingListSelection` holds the rules, this view turns
    /// events into calls.
    private var listBody: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(derived.sections) { section in
                        Section {
                            ForEach(section.meetings) { meeting in
                                selectableRow(for: meeting)
                            }
                        } header: {
                            sectionHeader(section.title)
                        }
                    }
                }
            }
            .background(Color(MPColors.bg))
            // The system focus ring is accent blue (No-System-Blue), so it is off; the focused row
            // draws its own signal ring in `selectableRow`.
            .focusable(interactions: .edit)
            .focusEffectDisabled()
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Meetings")
            .focused($listFocused)
            .onKeyPress(.upArrow, phases: [.down, .repeat]) { press in
                moveSelection(.up, extend: press.modifiers.contains(.shift), proxy: proxy)
            }
            .onKeyPress(.downArrow, phases: [.down, .repeat]) { press in
                moveSelection(.down, extend: press.modifiers.contains(.shift), proxy: proxy)
            }
            // Edit > Select All reaches the focused list through the responder chain (the menu's
            // key equivalent runs before `onKeyPress`). A focused search field answers it first.
            .onCommand(#selector(NSText.selectAll(_:))) {
                nav.selectAll(order: derived.order)
                selection = nav.selected
            }
        }
    }

    /// Group heading: the design kit's `SLGroupHeader` (xs, semibold, fg-subtle, 10/16/4). Opaque,
    /// since the header is pinned over the rows scrolling beneath it.
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.mpTextXS.weight(.semibold))
            .foregroundStyle(Color(MPColors.fgSubtle))
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(MPColors.bg))
            .accessibilityAddTraits(.isHeader)
    }

    private func moveSelection(_ step: MeetingListSelection.Step, extend: Bool, proxy: ScrollViewProxy) -> KeyPress.Result {
        guard let target = nav.move(step, extend: extend, order: derived.order) else { return .ignored }
        selection = nav.selected
        proxy.scrollTo(target)
        return .handled
    }

    /// One row plus its selection handling. A click from the keyboard-focused list takes focus so
    /// the arrows act on it; the modifier keys held at the click pick the kind, as in the
    /// transcript (`TranscriptRow.classifyClick`).
    private func selectableRow(for meeting: Meeting) -> some View {
        row(for: meeting)
            .id(meeting.id)
            .onTapGesture {
                listFocused = true
                let mods = NSEvent.modifierFlags
                let kind: MeetingListSelection.Click = mods.contains(.command) ? .command : (mods.contains(.shift) ? .shift : .plain)
                nav.click(meeting.id, kind: kind, order: derived.order)
                selection = nav.selected
            }
            // The keyboard cursor, in the app's own colour, only while the list has the focus.
            .overlay {
                if listFocused && nav.cursor == meeting.id {
                    Rectangle().strokeBorder(Color.mpSignal.opacity(0.6), lineWidth: 1.5).allowsHitTesting(false)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(meeting.displayTitle)
            .accessibilityAddTraits(selection.contains(meeting.id) ? .isSelected : [])
            .accessibilityAction(named: "Select") {
                nav.click(meeting.id, kind: .plain, order: derived.order)
                selection = nav.selected
            }
    }

    /// One list row. Factored so the pinned "In progress" section and the date
    /// groups build identical rows from one site.
    private func row(for meeting: Meeting) -> some View {
        MeetingRow(
            meeting: meeting,
            isLiveRecording: libraryModel.liveRecordingStem == meeting.stem,
            processing: libraryModel.processing(for: meeting.stem),
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
            onDequeueProcessing: { [weak libraryModel] id in
                libraryModel?.dequeueProcessing(id: id)
            },
            isSelected: selection.contains(meeting.id)
        )
        .equatable()
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
                .font(.mpTextMD.weight(.semibold))
            Text(message)
                .font(.mpTextSM)
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
    static func group(_ meetings: [Meeting], now: Date, calendar cal: Calendar = .current) -> [MeetingGroup] {
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
        // PERF22: an older month's ordinal and title, once per (year, month) rather than two
        // `dateComponents`, a `date(from:)` and a formatter call per meeting.
        var months: [Int: (ord: Int, title: String)] = [:]
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
                let comps = cal.dateComponents([.year, .month], from: ts)
                let monthKey = (comps.year ?? 0) * 100 + (comps.month ?? 0)
                if let cached = months[monthKey] {
                    key = (cached.ord, cached.title)
                } else {
                    let monthAnchor = cal.date(from: comps) ?? ts
                    let monthsAgo = max(
                        1,
                        cal.dateComponents([.month], from: monthAnchor, to: thisMonthStart).month ?? 1
                    )
                    let ord = 5 + monthsAgo
                    let title = MeetingFormatters.monthYear.string(from: ts)
                    months[monthKey] = (ord, title)
                    key = (ord, title)
                }
            }
            buckets[key.0, default: (title: key.1, meetings: [])].meetings.append(meeting)
        }
        return buckets
            .sorted { $0.key < $1.key }
            .map { MeetingGroup(title: $0.value.title, meetings: $0.value.meetings, order: $0.key) }
    }
}
