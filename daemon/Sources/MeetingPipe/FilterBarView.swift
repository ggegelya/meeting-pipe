import SwiftUI

/// Single 36pt filter bar: search input with match-count badge, Workflow chip, App/Status/Date ref-chips, and a trailing Clear button. The TECH-A3 FTS5 upgrade drops in behind `MeetingFilterEngine.apply` without touching this view.
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
            // TECH-DSN17: Clear only appears once a filter is active, so the
            // resting bar reads lighter (the count badge appears with it).
            if !filter.isEmpty {
                clearButton
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
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
            // TECH-DSN17: a real recessed well. The old white-5% fill was
            // invisible on the paper canvas; bgSunk reads on both themes.
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(MPColors.bgSunk))
        )
    }

    /// Show the badge once any filter is active so the user sees a running confirmation.
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
            // Render the actual WorkflowChip when set; fall back to a ref-chip-styled label so the slot is never empty.
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
