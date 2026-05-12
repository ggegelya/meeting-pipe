import SwiftUI

/// Filter bar above the meeting list — collapsed into a single 36pt
/// strip after the chrome-polish audit. Anatomy left → right:
///   • Search input with an inline match-count badge ("14 / 63")
///     fused to its trailing edge behind a 0.5px hairline. The badge
///     stays present so the user always sees what their typing is
///     filtering against.
///   • Workflow chip — full color-tinted `WorkflowChip`. Primary scope
///     in the design's chip hierarchy.
///   • Source / Status / Date — flat `MPRefChip`s carrying inline
///     values when set. Secondary refinements: visually subordinate
///     so they don't compete with the workflow chip.
///   • A text-only "Clear" button at the trailing edge, disabled-styled
///     when nothing is set.
///
/// Behavior is unchanged from the previous three-row layout; the
/// `MeetingFilter` binding and `MeetingFacets` source-of-truth are the
/// same. The TECH-A3 FTS5 upgrade can drop in behind
/// `MeetingFilterEngine.apply` without touching this view.
struct FilterBarView: View {
    @Binding var filter: MeetingFilter
    let facets: MeetingFacets
    let matchCount: Int
    let totalCount: Int

    var body: some View {
        HStack(spacing: 8) {
            searchField
            workflowChip
            sourceChip
            statusChip
            dateChip
            clearButton
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
    }

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Color(MPColors.fgSubtle))
            TextField("Search titles, summaries, decisions…", text: $filter.query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if showsMatchCount {
                Divider()
                    .frame(height: 14)
                    .overlay(Color(MPColors.border))
                Text("\(matchCount) / \(totalCount)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Color(MPColors.fgFaint))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color(MPColors.border), lineWidth: 0.5)
        )
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }

    /// Show the match-count once *any* filter is active — including
    /// the search query — so the user has a running confirmation that
    /// the field is doing something.
    private var showsMatchCount: Bool { !filter.isEmpty }

    // MARK: Chips

    @ViewBuilder
    private var workflowChip: some View {
        Menu {
            Button("Any workflow") { filter.workflow = nil }
            if !facets.workflows.isEmpty {
                Divider()
                ForEach(facets.workflows, id: \.self) { wf in
                    Button(wf) { filter.workflow = wf }
                }
            }
        } label: {
            // When a workflow filter is set we render the actual chip
            // family; when unset we fall back to a ref-chip-styled
            // "Workflow" affordance so the bar doesn't lose the slot.
            if let wf = filter.workflow {
                WorkflowChip(name: wf, colorHex: nil)
                    .padding(.horizontal, 2)
            } else {
                HStack(spacing: 4) {
                    Text("Workflow")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(MPColors.fgMuted))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 8)
                .frame(height: 22)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color(MPColors.border), lineWidth: 0.5)
                )
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var sourceChip: some View {
        MPRefChip(
            label: "App",
            currentValue: filter.sourceBundleID.flatMap { bid in
                facets.sources.first { $0.bundleID == bid }?.displayName
            },
            isActive: filter.sourceBundleID != nil
        ) {
            Button("Any app") { filter.sourceBundleID = nil }
            if !facets.sources.isEmpty {
                Divider()
                ForEach(facets.sources) { src in
                    Button(src.displayName) { filter.sourceBundleID = src.bundleID }
                }
            }
        }
    }

    private var statusChip: some View {
        MPRefChip(
            label: "Status",
            currentValue: filter.status.map(statusLabel),
            isActive: filter.status != nil
        ) {
            Button("Any status") { filter.status = nil }
            Divider()
            Button("Done") { filter.status = .done }
            Button("Processing") { filter.status = .processing }
            Button("Failed") { filter.status = .failed }
            Button("Manual paste ready") { filter.status = .manualPasteReady }
            Button("Recording") { filter.status = .recording }
        }
    }

    private var dateChip: some View {
        MPRefChip(
            label: "Date",
            currentValue: filter.dateRange == .all ? nil : filter.dateRange.rawValue,
            isActive: filter.dateRange != .all
        ) {
            ForEach(MeetingFilter.DateRange.allCases) { range in
                Button(range.rawValue) { filter.dateRange = range }
            }
        }
    }

    // MARK: Clear

    private var clearButton: some View {
        Button {
            filter = MeetingFilter()
        } label: {
            Text("Clear")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(filter.isEmpty
                                 ? Color(MPColors.fgFaint)
                                 : Color(MPColors.fgSubtle))
        }
        .buttonStyle(.plain)
        .disabled(filter.isEmpty)
        .padding(.leading, 2)
    }

    // MARK: Helpers

    private func statusLabel(_ s: Meeting.Status) -> String {
        switch s {
        case .recording: return "Recording"
        case .processing: return "Processing"
        case .manualPasteReady: return "Manual paste ready"
        case .done: return "Done"
        case .failed: return "Failed"
        case .unknown: return "Unknown"
        }
    }
}
