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

    /// UX32: the row's own "Edit workflow…", from the context menu or the swipe. Same host
    /// hook the toolbar and inspector buttons use, so the sidebar stays free of modal state
    /// here too. Reaching the editor used to mean selecting the row *and* having no meeting
    /// selected, so that the inspector's Edit button was on screen at all.
    let onEditWorkflow: (Workflow) -> Void
    /// UX32: the row's own "Delete workflow…". The root confirms and runs
    /// `WorkflowDeletion.run` (UX30), the one flow the editor sheet's Delete also goes
    /// through, rather than the rail growing a second delete path.
    let onDeleteWorkflow: (Workflow) -> Void

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
                        count: counts.workflowCount(for: wf.id),
                        // WF9: how many other workflows answer to this name. Non-zero
                        // means this row's count is not this workflow's meetings.
                        sameNamed: WorkflowNameCollision.others(
                            named: wf.name, excluding: wf.id, in: workflowStore.workflows
                        )
                    )
                    .tag(LibraryScope.workflow(wf.id))
                    .listRowBackground(LibraryScope.workflow(wf.id) == selection ? Color.mpSelectionWash : Color.clear)
                    // UX32: the two row entry points, both over the same pre-flighted
                    // pair. Deleting a workflow used to be a five-step walk through the
                    // editor sheet, which is paid once per row when cleaning duplicates.
                    .contextMenu { workflowRowMenu(for: wf) }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        workflowRowSwipeActions(for: wf)
                    }
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
                        // Facts carries AI7's overdue count; People, Meeting time,
                        // Ask and Digests resolve to 0.
                        scope: scope,
                        count: counts.count(for: scope),
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
        // FEAT15: the rail as a whole, not one of its rows. A probe inside a
        // `List` row rides an NSTableView cell that is recycled and may not be
        // realised at all when the tour arrives; the column always is.
        .tutorialAnchor(.scopeRail)
    }

    /// UX32: right-click on a workflow row. Mirrors the saved-folder menu one section up,
    /// with the disabled-Delete caption UX29 uses for its clamped cloud engine: a disabled
    /// row explains nothing on its own, so the reason sits under it in the quiet register
    /// rather than in a dialog the user has to provoke.
    @ViewBuilder
    private func workflowRowMenu(for workflow: Workflow) -> some View {
        let actions = WorkflowRowActions.resolve(workflowID: workflow.id, in: workflowStore.workflows)
        Button(WorkflowRowActions.editTitle) { onEditWorkflow(workflow) }
        Divider()
        Button(WorkflowRowActions.deleteTitle, role: .destructive) { onDeleteWorkflow(workflow) }
            .disabled(!actions.canDelete)
            .accessibilityLabel(actions.deleteAccessibilityLabel)
        if let reason = actions.deleteDisabledReason {
            Text(reason)
                .font(.mpTextXS)
                .foregroundStyle(Color(MPColors.fgSubtle))
        }
    }

    /// UX32: trailing swipe on a workflow row, the same pair as the context menu.
    ///
    /// `allowsFullSwipe: false` on purpose: a full swipe fires its first action on momentum
    /// alone, and the first action here destroys a workflow. Delete sits closest to the
    /// trailing edge, as in every other trailing-swipe list, and still opens the same
    /// confirmation.
    ///
    /// A swipe action has no caption slot, so on the default workflow the disabled Delete
    /// carries its reason in the accessibility label only; the context menu above is where
    /// that sentence is legible.
    @ViewBuilder
    private func workflowRowSwipeActions(for workflow: Workflow) -> some View {
        let actions = WorkflowRowActions.resolve(workflowID: workflow.id, in: workflowStore.workflows)
        Button(role: .destructive) { onDeleteWorkflow(workflow) } label: {
            Label(WorkflowRowActions.deleteTitle, systemImage: "trash")
        }
        .disabled(!actions.canDelete)
        .accessibilityLabel(actions.deleteAccessibilityLabel)
        // The app's danger token, not the system red: No-System-Blue (DSN10) is the same
        // rule for every native control colour the app can name.
        .tint(.mpDanger)

        Button { onEditWorkflow(workflow) } label: {
            Label(WorkflowRowActions.editTitle, systemImage: "pencil")
        }
    }

    /// Date/status filter scopes shown in the Library section, in display order.
    static let librarySections: [LibraryScope] = [
        .allMeetings, .today, .last7Days, .last30Days, .needsYou, .ndaOnly, .untagged,
    ]

    /// Cross-meeting projections (DV1 / AI3 / AI4 / DV3 / AI8): views that replace
    /// the list rather than filter it, so they get their own INSIGHTS group below
    /// Workflows (DSN22 #7), set apart from the date/status filters above.
    static let insightsSections: [LibraryScope] = [.facts, .people, .stats, .ask, .digests]
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

    /// AI7: commitments wanting attention today, badged amber on the Facts row so an
    /// overdue action resurfaces without opening Facts or reading a digest. Unlike
    /// every other count here this one is derived from the summary sidecars rather
    /// than the meeting list, so it arrives from the Facts load (`FactsSnapshot`)
    /// through `with(factsOverdue:)` instead of from `build`. Defaulted, so it stays
    /// out of the initializer below.
    var factsOverdue: Int = 0

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

    /// This bag with the Facts attention count overlaid. Kept separate from `build`
    /// so a changed overdue count never re-runs the O(meetings × scopes) bucketing.
    func with(factsOverdue: Int) -> ScopeCounts {
        var copy = self
        copy.factsOverdue = factsOverdue
        return copy
    }

    func count(for scope: LibraryScope) -> Int {
        switch scope {
        case .allMeetings: return total
        case .today:       return today
        case .last7Days:   return last7
        case .last30Days:  return last30
        case .needsYou:    return needsYou
        case .ndaOnly:     return nda
        case .untagged:    return untagged
        case .facts:       return factsOverdue   // AI7: the overdue attention count
        case .ask, .digests, .people, .stats: return 0   // views, not counted subsets
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

/// VoiceOver text for the rail's amber attention pill (TECH-DSN17 / AI7). Its own
/// type so a test can pin the wording without reaching into a private view.
enum ScopeAttentionLabel {
    static func text(scope: LibraryScope, count: Int) -> String {
        switch scope {
        case .facts:
            return count == 1 ? "1 action overdue" : "\(count) actions overdue"
        default:
            return count == 1 ? "1 meeting needs you" : "\(count) meetings need you"
        }
    }
}

private struct LibraryScopeRow: View {
    let scope: LibraryScope
    let count: Int
    let isSelected: Bool

    /// "Needs you" badges a non-zero count as a filled amber attention pill so
    /// unresolved meetings are visible from the rail (TECH-DSN17). "Facts" reuses
    /// the same pill for its overdue-commitment count (AI7), which is the same kind
    /// of claim on the owner's attention. Every other scope keeps the quiet mono count.
    private var isAttention: Bool {
        switch scope {
        case .needsYou, .facts: return count > 0
        default: return false
        }
    }

    /// `.people` / `.stats` / `.ask` / `.digests` are views, not counted subsets, so they
    /// show no trailing count (DV3 / AI8 / AI3 / AI4). `.facts` is a view too, so it stays
    /// bare until something is actually overdue: the badge is an attention cue, not an
    /// inventory (AI7).
    private var showsCount: Bool {
        switch scope {
        case .ask, .digests, .people, .stats: return false
        case .facts: return count > 0
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
                        // The bare number is meaningless read aloud; say what it counts.
                        .accessibilityLabel(ScopeAttentionLabel.text(scope: scope, count: count))
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
                // UX76 checked this row for the workflow row's caption competition and it has
                // none: one text against a fixed-width count. It was missing the line limit
                // though, and the name is user-typed, so a long saved search grew the row to two
                // or three lines instead of truncating like every neighbour.
                Text(search.name)
                    .lineLimit(1)
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

/// UX76: what one workflow rail row shows, decided before SwiftUI lays anything out.
///
/// The row used to put five things in one `HStack` under a single `.lineLimit(1)`: the emoji, the
/// name, `· default`, WF9's duplicate-name caption and FEAT11's no-context marker. Five siblings
/// competing for a fixed-width rail truncate together, and the name had no priority over the
/// footnotes describing it, so the row degraded exactly backwards. The owner's main workflow, 105
/// of the library's meetings, rendered as `Pers… · defa… · no c…` and identified nothing
/// (2026-08-04). Each caption arrived with its own task and each was individually defensible; what
/// nobody owned was the total width budget.
///
/// Two changes fix the mechanism rather than postponing it to a narrower rail. The footnotes are
/// booleans, so each becomes one glyph instead of a phrase, which is most of the width back; and
/// the name takes layout priority, so whatever is still tight truncates footnotes first and the
/// name last. Composing it here rather than inline is what makes the row assertable: a fourth
/// caption appended to the `HStack` the way the first three were now has to come through `decide`,
/// and `WorkflowRailRowTests` fails when the name stops surviving.
struct WorkflowRailRow: Equatable {

    /// One footnote about the workflow, reduced to a glyph that keeps the meaning its own task
    /// established. Nothing here is an alarm: WF9's comment is explicit that a duplicate name is a
    /// quiet fact, and FEAT11's that a missing context is an observation about the workflow rather
    /// than a warning about the app, so both stay `fgSubtle` outline glyphs rather than warning
    /// chrome.
    struct Marker: Equatable {
        let symbol: String
        /// What VoiceOver reads in place of the words this glyph replaced.
        let accessibilityLabel: String
        /// The element-level tooltip, or nil when the row already carries the sentence. Only WF9's
        /// collision marker is nil: its explanation is attached to the whole row, deliberately, so
        /// it does not fight FEAT11's element-level tooltip. That layering predates this task and
        /// the spec says not to collapse it.
        let help: String?
    }

    /// Never abbreviated here. Truncation, if the rail is narrow enough to force any, is SwiftUI's
    /// and happens last because of the layout priority the view attaches.
    let name: String
    let markers: [Marker]

    static func decide(workflow: Workflow, sameNamed: Int) -> WorkflowRailRow {
        var markers: [Marker] = []
        if workflow.isDefault {
            markers.append(Marker(
                symbol: "checkmark.circle",
                accessibilityLabel: "default",
                help: "Default workflow."
            ))
        }
        if WorkflowNameCollision.railCaption(others: sameNamed) != nil {
            markers.append(Marker(
                symbol: "square.on.square",
                accessibilityLabel: "duplicate name",
                help: nil
            ))
        }
        if WorkflowContextHint.needsContext(workflow) {
            markers.append(Marker(
                symbol: "questionmark.circle",
                accessibilityLabel: WorkflowContextHint.listMarker,
                help: WorkflowContextHint.listMarkerHelp
            ))
        }
        return WorkflowRailRow(name: workflow.name, markers: markers)
    }
}

/// One demoted caption. Split out so the conditional tooltip does not need a branch inside the
/// row's own `HStack`.
private struct WorkflowRailMarkerView: View {
    let marker: WorkflowRailRow.Marker

    var body: some View {
        let glyph = Image(systemName: marker.symbol)
            .font(.mpTextXS)
            .foregroundStyle(Color(MPColors.fgSubtle))
            .accessibilityLabel(marker.accessibilityLabel)
        if let help = marker.help {
            glyph.help(help)
        } else {
            glyph
        }
    }
}

private struct WorkflowScopeRow: View {
    let workflow: Workflow
    let count: Int
    /// WF9: other workflows carrying this exact name. Zero in the normal case.
    var sameNamed: Int = 0

    private var row: WorkflowRailRow {
        WorkflowRailRow.decide(workflow: workflow, sameNamed: sameNamed)
    }

    var body: some View {
        Label {
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    if let emoji = workflow.emoji, !emoji.isEmpty {
                        // Tokenised on the way past: `MPType.textXS` is the same 11pt, and the
                        // DSN3 guard rejects raw font literals on changed lines.
                        Text(emoji).font(.mpTextXS)
                    }
                    // UX76: the name outranks every footnote about it. Priority is what makes the
                    // row degrade the right way round; the glyphs below are what stop it needing
                    // to. WF9's and FEAT11's facts are unchanged, only their presentation is.
                    Text(row.name)
                        .lineLimit(1)
                        .layoutPriority(1)
                    ForEach(Array(row.markers.enumerated()), id: \.offset) { _, marker in
                        WorkflowRailMarkerView(marker: marker)
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
        // WF9: the caption is two words, so the sentence explaining what a collision
        // costs lives in the tooltip and, for VoiceOver, in the hint. Both resolve to
        // an empty string when the name is unique, which reads as no tooltip / no hint.
        .help(collisionExplanation ?? "")
        .accessibilityHint(collisionExplanation ?? "")
    }

    private var collisionExplanation: String? {
        WorkflowNameCollision.explanation(name: workflow.name, others: sameNamed)
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
