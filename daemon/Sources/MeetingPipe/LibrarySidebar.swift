import SwiftUI

/// Smart-folder rail: scopes on top, workflows below. Drives
/// `LibraryScope` selection in the root view.
///
/// Workflows are scopes here (not destinations) — selecting one filters
/// the list and reveals an Edit affordance + inspector pane. The state
/// pill and record button live in the toolbar, not here, so the rail's
/// width is spent on navigation rather than chrome.
struct LibrarySidebar: View {
    @Binding var selection: LibraryScope
    @ObservedObject var model: LibraryWindowModel
    /// Optional — non-nil only when `LibraryWindowModel.workflowStore`
    /// has been wired. The rail degrades to library-only scopes when
    /// nil (e.g. headless tests or the very first launch before the
    /// store is bound).
    @ObservedObject var workflowStore: WorkflowStore

    /// Per-row counts. Recomputed by `LibraryRootView` whenever the
    /// meeting store or the workflow store publishes a change.
    let counts: ScopeCounts

    /// Called when the user clicks "+ New workflow" or any of the
    /// workflow rows' edit affordances. The root hosts the editor
    /// sheet so the sidebar doesn't need its own modal state.
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
                }
            } header: {
                Text("Library")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.08 * 10)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(workflowStore.workflows.sorted(by: workflowOrder)) { wf in
                    WorkflowScopeRow(
                        workflow: wf,
                        count: counts.workflowCount(for: wf.id)
                    )
                    .tag(LibraryScope.workflow(wf.id))
                }
                Button(action: onCreateWorkflow) {
                    Label {
                        Text("New workflow")
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "plus")
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            } header: {
                Text("Workflows")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.08 * 10)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
    }

    /// Static set of non-workflow scopes that always render in the
    /// rail's Library section, in display order.
    static let librarySections: [LibraryScope] = [
        .allMeetings, .today, .last7Days, .last30Days, .ndaOnly, .untagged,
    ]
}

/// Plain-data bag handed in from the parent so the sidebar doesn't have
/// to know how to filter the meeting store itself. The parent owns the
/// MeetingStore subscription and recomputes whenever its `meetings`
/// array changes — keeps the rail's render cheap.
struct ScopeCounts: Equatable {
    let total: Int
    let today: Int
    let last7: Int
    let last30: Int
    let nda: Int
    let untagged: Int
    /// Per-workflow row counts, keyed by workflow id. Workflows missing
    /// from the dict render as zero rather than hiding the row, so the
    /// rail stays self-teaching for newly-created workflows.
    let perWorkflow: [Workflow.ID: Int]

    static let zero = ScopeCounts(
        total: 0, today: 0, last7: 0, last30: 0, nda: 0, untagged: 0, perWorkflow: [:]
    )

    func count(for scope: LibraryScope) -> Int {
        switch scope {
        case .allMeetings: return total
        case .today:       return today
        case .last7Days:   return last7
        case .last30Days:  return last30
        case .ndaOnly:     return nda
        case .untagged:    return untagged
        case .workflow(let id): return perWorkflow[id] ?? 0
        }
    }

    func workflowCount(for id: Workflow.ID) -> Int {
        perWorkflow[id] ?? 0
    }

    /// Walk the meeting list once and bucket every row into every scope
    /// it satisfies. O(n × scopes) but n is at most a few hundred in
    /// regular use; building once per store mutation is cheap enough
    /// that we don't bother memoizing partial sums.
    static func build(meetings: [Meeting], workflows: [Workflow], now: Date = Date()) -> ScopeCounts {
        var today = 0, last7 = 0, last30 = 0, nda = 0, untagged = 0
        var perWf: [Workflow.ID: Int] = [:]
        let scopes: [LibraryScope] = [.today, .last7Days, .last30Days, .ndaOnly, .untagged]
        for m in meetings {
            for s in scopes {
                guard s.includes(m, workflows: workflows, now: now) else { continue }
                switch s {
                case .today:      today += 1
                case .last7Days:  last7 += 1
                case .last30Days: last30 += 1
                case .ndaOnly:    nda += 1
                case .untagged:   untagged += 1
                default: break
                }
            }
            // Per-workflow bucketing is independent of the date / NDA
            // scopes above; an NDA meeting also counts toward its
            // workflow's own row.
            if let name = m.workflowName, !name.isEmpty,
               let wf = workflows.first(where: { $0.name == name }) {
                perWf[wf.id, default: 0] += 1
            }
        }
        return ScopeCounts(
            total: meetings.count,
            today: today, last7: last7, last30: last30,
            nda: nda, untagged: untagged,
            perWorkflow: perWf
        )
    }
}

// MARK: - Row views

private struct LibraryScopeRow: View {
    let scope: LibraryScope
    let count: Int
    let isSelected: Bool

    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(scope.title)
                Spacer(minLength: 0)
                Text(count.formatted(.number))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(isSelected ? .primary : .tertiary)
            }
        } icon: {
            if let img = scope.systemImage {
                Image(systemName: img)
            }
        }
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
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
                Text(count.formatted(.number))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        } icon: {
            // Filled dot, workflow color. 8pt to read at the rail's
            // density without dominating the label.
            Circle()
                .fill(swiftUIColor(forHex: workflow.color))
                .frame(width: 8, height: 8)
        }
    }
}

/// Convert a workflow's hex string to a SwiftUI color. Falls back to
/// secondary if the hex doesn't parse — the editor validates on save,
/// but legacy TOML rows imported from older builds may carry odd values.
private func swiftUIColor(forHex hex: String) -> Color {
    if let ns = HexColor.parse(hex) { return Color(ns) }
    return Color.secondary
}

/// Match `WorkflowStore`'s internal ordering: order field first, then
/// case-insensitive name as the tie-breaker. Kept here as a free
/// function rather than a static on `WorkflowStore` so the store stays
/// free of view-layer churn.
private func workflowOrder(_ a: Workflow, _ b: Workflow) -> Bool {
    if a.order != b.order { return a.order < b.order }
    return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
}
