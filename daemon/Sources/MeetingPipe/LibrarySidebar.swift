import SwiftUI

/// Smart-folder rail: Library date/status scopes on top, then the user's saved smart folders, Workflows below, and an Insights group (Facts / Ask projections) last (DSN22 #7). Selecting a workflow filters the list and opens its inspector. State pill and record button live in the toolbar.
struct LibrarySidebar: View {
    @Binding var selection: LibraryScope
    /// Non-nil once the Coordinator has wired the store. Rail degrades to library-only scopes when nil (headless tests, first launch).
    @ObservedObject var workflowStore: WorkflowStore

    /// Saved smart folders and their row actions (UX24), grouped so this parameter list
    /// stays readable. Plain values rather than the store, so the sidebar stays a pure
    /// render of state the root already observes.
    let saved: SavedSearchRail

    /// Per-row counts, recomputed by `LibraryRootView` on store changes.
    let counts: ScopeCounts

    /// Called on "+ New workflow". The root hosts the editor sheet so the sidebar needs no modal state.
    let onCreateWorkflow: () -> Void

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach(LibrarySidebar.librarySections, id: \.self) { scope in
                    LibraryScopeRow(
                        scope: scope,
                        count: counts.count(for: scope),
                        isSelected: scope == selection
                    )
                    .tag(scope)
                    // Teal selection wash, replacing the macOS system-blue source-list
                    // highlight that the app `.tint` can't recolor (No-System-Blue).
                    .listRowBackground(scope == selection ? Color.mpSelectionWash : Color.clear)
                }
            } header: {
                Text("Library")
                    .font(.mpTextXS.weight(.semibold))
                    .tracking(0.08 * 10)
                    .textCase(.uppercase)
                    .foregroundStyle(Color(MPColors.fgMuted))
            }

            // UX24: only present once the user has saved one. Creation lives on the
            // filter bar, where the filter being saved is, so an empty rail section
            // would be a header with nothing to do.
            if !saved.searches.isEmpty {
                Section {
                    ForEach(saved.searches) { search in
                        SavedSearchScopeRow(
                            search: search,
                            summary: saved.summaries[search.id] ?? "",
                            count: counts.savedCount(for: search.id),
                            isSelected: LibraryScope.saved(search.id) == selection
                        )
                        .tag(LibraryScope.saved(search.id))
                        .listRowBackground(LibraryScope.saved(search.id) == selection ? Color.mpSelectionWash : Color.clear)
                        .contextMenu {
                            Button("Rename…") { saved.onRename(search) }
                            Button("Update to current view") { saved.onUpdate(search) }
                            Divider()
                            Button("Delete", role: .destructive) { saved.onDelete(search) }
                        }
                    }
                } header: {
                    Text("Smart folders")
                        .font(.mpTextXS.weight(.semibold))
                        .tracking(0.08 * 10)
                        .textCase(.uppercase)
                        .foregroundStyle(Color(MPColors.fgMuted))
                }
            }

            Section {
                ForEach(workflowStore.workflows.sorted(by: workflowOrder)) { wf in
                    WorkflowScopeRow(
                        workflow: wf,
                        count: counts.workflowCount(for: wf.id)
                    )
                    .tag(LibraryScope.workflow(wf.id))
                    .listRowBackground(LibraryScope.workflow(wf.id) == selection ? Color.mpSelectionWash : Color.clear)
                }
                Button(action: onCreateWorkflow) {
                    Label {
                        Text("New workflow")
                            .foregroundStyle(Color(MPColors.fgMuted))
                    } icon: {
                        Image(systemName: "plus")
                            .foregroundStyle(Color(MPColors.fgMuted))
                    }
                }
                .buttonStyle(.plain)
            } header: {
                Text("Workflows")
                    .font(.mpTextXS.weight(.semibold))
                    .tracking(0.08 * 10)
                    .textCase(.uppercase)
                    .foregroundStyle(Color(MPColors.fgMuted))
            }

            Section {
                ForEach(LibrarySidebar.insightsSections, id: \.self) { scope in
                    LibraryScopeRow(
                        scope: scope,
                        count: 0,
                        isSelected: scope == selection
                    )
                    .tag(scope)
                    .listRowBackground(scope == selection ? Color.mpSelectionWash : Color.clear)
                }
            } header: {
                Text("Insights")
                    .font(.mpTextXS.weight(.semibold))
                    .tracking(0.08 * 10)
                    .textCase(.uppercase)
                    .foregroundStyle(Color(MPColors.fgMuted))
            }
        }
        .listStyle(.sidebar)
        // No-System-Blue (DSN10): drop the native source-list highlight so only the
        // teal wash reads; without this the prominent blue selection stacks under it.
        .noNativeListSelection()
        .navigationSplitViewColumnWidth(
            min: LibraryLayout.sidebarMinWidth,
            ideal: LibraryLayout.sidebarIdealWidth,
            max: LibraryLayout.sidebarMaxWidth
        )
    }

    /// Date/status filter scopes shown in the Library section, in display order.
    static let librarySections: [LibraryScope] = [
        .allMeetings, .today, .last7Days, .last30Days, .needsYou, .ndaOnly, .untagged,
    ]

    /// Cross-meeting projections (DV1 / AI3 / AI4 / DV3): views that replace the
    /// list rather than filter it, so they get their own INSIGHTS group below
    /// Workflows (DSN22 #7), set apart from the date/status filters above.
    static let insightsSections: [LibraryScope] = [.facts, .people, .ask, .digests]
}

/// The saved-folder half of the rail (UX24): the folders, their rendered criteria lines,
/// and the row actions. Grouped into one value so `LibrarySidebar` takes one parameter
/// instead of five, and so a headless caller can pass `.empty`.
struct SavedSearchRail {
    let searches: [SavedSearch]
    /// Criteria line per folder, for the row's tooltip and VoiceOver hint. Rendered by
    /// the root, which can resolve a source bundle id to its display name.
    let summaries: [SavedSearch.ID: String]
    let onRename: (SavedSearch) -> Void
    let onUpdate: (SavedSearch) -> Void
    let onDelete: (SavedSearch) -> Void

    static let empty = SavedSearchRail(
        searches: [], summaries: [:],
        onRename: { _ in }, onUpdate: { _ in }, onDelete: { _ in }
    )
}

/// Pre-computed count bag handed in from the parent, so the sidebar never touches the meeting store directly.
struct ScopeCounts: Equatable {
    let total: Int
    let today: Int
    let last7: Int
    let last30: Int
    let needsYou: Int
    let nda: Int
    let untagged: Int
    /// Per-workflow counts keyed by id. Missing entries render as zero so new workflows show immediately.
    let perWorkflow: [Workflow.ID: Int]
    /// Per-saved-folder counts keyed by id (UX24). Missing entries render as zero so a
    /// just-created folder shows immediately.
    let perSaved: [SavedSearch.ID: Int]

    init(
        total: Int,
        today: Int,
        last7: Int,
        last30: Int,
        needsYou: Int,
        nda: Int,
        untagged: Int,
        perWorkflow: [Workflow.ID: Int],
        perSaved: [SavedSearch.ID: Int] = [:]
    ) {
        self.total = total
        self.today = today
        self.last7 = last7
        self.last30 = last30
        self.needsYou = needsYou
        self.nda = nda
        self.untagged = untagged
        self.perWorkflow = perWorkflow
        self.perSaved = perSaved
    }

    static let zero = ScopeCounts(
        total: 0, today: 0, last7: 0, last30: 0, needsYou: 0, nda: 0, untagged: 0, perWorkflow: [:]
    )

    func count(for scope: LibraryScope) -> Int {
        switch scope {
        case .allMeetings: return total
        case .today:       return today
        case .last7Days:   return last7
        case .last30Days:  return last30
        case .needsYou:    return needsYou
        case .ndaOnly:     return nda
        case .untagged:    return untagged
        case .facts, .ask, .digests, .people: return 0   // views, not counted subsets
        case .workflow(let id): return perWorkflow[id] ?? 0
        case .saved(let id): return perSaved[id] ?? 0
        }
    }

    func workflowCount(for id: Workflow.ID) -> Int {
        perWorkflow[id] ?? 0
    }

    func savedCount(for id: SavedSearch.ID) -> Int {
        perSaved[id] ?? 0
    }

    /// Walk the meeting list once and bucket each row into the scopes it satisfies. O(n × scopes); n is at most a few hundred in normal use.
    ///
    /// `savedSearches` are counted separately (UX24): each one runs its own base scope
    /// plus filter over the full list, so its count is a real subset count rather than a
    /// bucket of this walk. `ftsMatches` resolves a folder's free-text query against the
    /// UX16 index; the default returns nil, which falls back to the in-memory corpus so
    /// a headless caller (and every existing test) drives this unchanged.
    static func build(
        meetings: [Meeting],
        workflows: [Workflow],
        savedSearches: [SavedSearch] = [],
        now: Date = Date(),
        ftsMatches: (String) -> Set<String>? = { _ in nil }
    ) -> ScopeCounts {
        var today = 0, last7 = 0, last30 = 0, needsYou = 0, nda = 0, untagged = 0
        var perWf: [Workflow.ID: Int] = [:]
        let scopes: [LibraryScope] = [.today, .last7Days, .last30Days, .needsYou, .ndaOnly, .untagged]
        for m in meetings {
            for s in scopes {
                guard s.includes(m, workflows: workflows, now: now) else { continue }
                switch s {
                case .today:      today += 1
                case .last7Days:  last7 += 1
                case .last30Days: last30 += 1
                case .needsYou:   needsYou += 1
                case .ndaOnly:    nda += 1
                case .untagged:   untagged += 1
                default: break
                }
            }
            // Workflow bucketing is independent of date/NDA scopes; an NDA meeting still counts toward its workflow.
            if let name = m.workflowName, !name.isEmpty,
               let wf = workflows.first(where: { $0.name == name }) {
                perWf[wf.id, default: 0] += 1
            }
        }
        var perSaved: [SavedSearch.ID: Int] = [:]
        for s in savedSearches {
            perSaved[s.id] = s.apply(
                to: meetings,
                workflows: workflows,
                ftsMatches: ftsMatches(s.filter.query),
                now: now
            ).count
        }
        return ScopeCounts(
            total: meetings.count,
            today: today, last7: last7, last30: last30,
            needsYou: needsYou, nda: nda, untagged: untagged,
            perWorkflow: perWf,
            perSaved: perSaved
        )
    }
}

// MARK: - Row views

private struct LibraryScopeRow: View {
    let scope: LibraryScope
    let count: Int
    let isSelected: Bool

    /// "Needs you" badges a non-zero count as a filled amber attention pill so
    /// unresolved meetings are visible from the rail (TECH-DSN17). Every other
    /// scope keeps the quiet mono count.
    private var isAttention: Bool {
        if case .needsYou = scope { return count > 0 }
        return false
    }

    /// `.facts` / `.people` / `.ask` / `.digests` are views, not counted subsets, so they show no trailing count (DV1 / DV3 / AI3 / AI4).
    private var showsCount: Bool {
        switch scope {
        case .facts, .ask, .digests, .people: return false
        default: return true
        }
    }

    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(scope.title)
                Spacer(minLength: 0)
                if !showsCount {
                    EmptyView()
                } else if isAttention {
                    Text(count.formatted(.number))
                        .font(.mpTextXS.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color(MPColors.warning600))
                        )
                } else {
                    Text(count.formatted(.number))
                        .font(.mpTextXS.monospacedDigit())
                        // TECH-UI-8: mute empty scopes (secondary at half opacity);
                        // non-empty stay full secondary, keeping the selected emphasis.
                        .foregroundStyle(count == 0 ? AnyShapeStyle(Color.secondary.opacity(0.5))
                                                     : AnyShapeStyle(isSelected ? .primary : .secondary))
                }
            }
        } icon: {
            if let img = scope.systemImage {
                Image(systemName: img)
            }
        }
    }
}

/// Saved smart folder row (UX24). Reads like a built-in scope row: symbol, name, quiet
/// mono count, dimmed when empty. The accessible label spells the criteria out, since
/// the name alone does not say what the folder holds.
private struct SavedSearchScopeRow: View {
    let search: SavedSearch
    let summary: String
    let count: Int
    let isSelected: Bool

    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(search.name)
                Spacer(minLength: 0)
                Text(count.formatted(.number))
                    .font(.mpTextXS.monospacedDigit())
                    // TECH-UI-8: empty folders render dimmed, like every other scope.
                    .foregroundStyle(count == 0 ? AnyShapeStyle(Color.secondary.opacity(0.5))
                                                : AnyShapeStyle(isSelected ? .primary : .secondary))
            }
        } icon: {
            Image(systemName: "folder.badge.gearshape")
        }
        .help(summary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(search.name), smart folder, \(count) meetings")
        .accessibilityHint(summary)
    }
}

private struct WorkflowScopeRow: View {
    let workflow: Workflow
    let count: Int

    var body: some View {
        Label {
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    if let emoji = workflow.emoji, !emoji.isEmpty {
                        Text(emoji).font(.system(size: 11))
                    }
                    Text(workflow.name)
                    if workflow.isDefault {
                        Text("· default")
                            .font(.mpTextXS)
                            .foregroundStyle(Color(MPColors.fgSubtle))
                    }
                }
                Spacer(minLength: 0)
                Text(count.formatted(.number))
                    .font(.mpTextXS.monospacedDigit())
                    // TECH-UI-8: empty workflows render dimmed.
                    .foregroundStyle(count == 0 ? AnyShapeStyle(Color.secondary.opacity(0.5))
                                                : AnyShapeStyle(HierarchicalShapeStyle.secondary))
            }
        } icon: {
            // 8pt filled dot in the workflow color.
            Circle()
                .fill(swiftUIColor(forHex: workflow.color))
                .frame(width: 8, height: 8)
        }
    }
}

/// Hex → SwiftUI Color, falling back to `.secondary` for malformed input (legacy TOML rows).
private func swiftUIColor(forHex hex: String) -> Color {
    if let ns = HexColor.parse(hex) { return Color(ns) }
    return Color.secondary
}

/// Sort by `order` then case-insensitive name. Free function rather than a `WorkflowStore` static to keep the store free of view-layer churn.
private func workflowOrder(_ a: Workflow, _ b: Workflow) -> Bool {
    if a.order != b.order { return a.order < b.order }
    return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
}
