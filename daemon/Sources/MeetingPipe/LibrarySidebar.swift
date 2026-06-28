import SwiftUI

/// Smart-folder rail: library scopes on top, workflows below. Selecting a workflow filters the list and opens its inspector. State pill and record button live in the toolbar.
struct LibrarySidebar: View {
    @Binding var selection: LibraryScope
    /// Non-nil once the Coordinator has wired the store. Rail degrades to library-only scopes when nil (headless tests, first launch).
    @ObservedObject var workflowStore: WorkflowStore

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
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.08 * 10)
                    .textCase(.uppercase)
                    .foregroundStyle(Color(MPColors.fgMuted))
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
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.08 * 10)
                    .textCase(.uppercase)
                    .foregroundStyle(Color(MPColors.fgMuted))
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(
            min: LibraryLayout.sidebarMinWidth,
            ideal: LibraryLayout.sidebarIdealWidth,
            max: LibraryLayout.sidebarMaxWidth
        )
    }

    /// Non-workflow scopes shown in the Library section, in display order.
    /// `.facts` sits last: a cross-meeting projection set apart from the
    /// date/status filters above it (DV1).
    static let librarySections: [LibraryScope] = [
        .allMeetings, .today, .last7Days, .last30Days, .needsYou, .ndaOnly, .untagged, .facts,
    ]
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
        case .facts:       return 0   // a view, not a counted subset
        case .workflow(let id): return perWorkflow[id] ?? 0
        }
    }

    func workflowCount(for id: Workflow.ID) -> Int {
        perWorkflow[id] ?? 0
    }

    /// Walk the meeting list once and bucket each row into the scopes it satisfies. O(n × scopes); n is at most a few hundred in normal use.
    static func build(meetings: [Meeting], workflows: [Workflow], now: Date = Date()) -> ScopeCounts {
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
        return ScopeCounts(
            total: meetings.count,
            today: today, last7: last7, last30: last30,
            needsYou: needsYou, nda: nda, untagged: untagged,
            perWorkflow: perWf
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

    /// `.facts` is a view, not a counted subset, so it shows no trailing count (DV1).
    private var showsCount: Bool {
        if case .facts = scope { return false }
        return true
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
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color(MPColors.warning600))
                        )
                } else {
                    Text(count.formatted(.number))
                        .font(.system(size: 11).monospacedDigit())
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
                            .foregroundStyle(Color(MPColors.fgSubtle))
                    }
                }
                Spacer(minLength: 0)
                Text(count.formatted(.number))
                    .font(.system(size: 11).monospacedDigit())
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
