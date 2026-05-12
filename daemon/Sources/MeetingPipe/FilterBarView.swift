import SwiftUI

/// Filter bar at the top of the library list (TECH-A14). Free-text
/// search + chip dropdowns for workflow, source app, status, date
/// range. All in-memory — TECH-A3's FTS5 upgrade would replace the
/// `MeetingFilterEngine.apply` call with a SQLite-backed query.

struct FilterBarView: View {
    @Binding var filter: MeetingFilter
    let facets: MeetingFacets
    let matchCount: Int
    let totalCount: Int

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search titles, summaries, decisions…", text: $filter.query)
                    .textFieldStyle(.plain)
                if !filter.query.isEmpty {
                    Button {
                        filter.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    workflowChip
                    sourceChip
                    statusChip
                    dateChip
                    if !filter.isEmpty {
                        Button {
                            filter = MeetingFilter()
                        } label: {
                            Label("Clear", systemImage: "xmark.circle")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                    }
                    Spacer(minLength: 0)
                }
            }
            if !filter.isEmpty {
                HStack {
                    Text("\(matchCount) of \(totalCount) meetings")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: Chips

    private var workflowChip: some View {
        FilterChipMenu(
            label: "Workflow",
            currentValue: filter.workflow,
            isActive: filter.workflow != nil
        ) {
            Button("Any workflow") { filter.workflow = nil }
            if !facets.workflows.isEmpty {
                Divider()
                ForEach(facets.workflows, id: \.self) { wf in
                    Button(wf) { filter.workflow = wf }
                }
            }
        }
    }

    private var sourceChip: some View {
        FilterChipMenu(
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
        FilterChipMenu(
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
        FilterChipMenu(
            label: "Date",
            currentValue: filter.dateRange == .all ? nil : filter.dateRange.rawValue,
            isActive: filter.dateRange != .all
        ) {
            ForEach(MeetingFilter.DateRange.allCases) { range in
                Button(range.rawValue) { filter.dateRange = range }
            }
        }
    }

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

/// Reusable chip with a `Menu` dropdown. The visible label folds in
/// the current value when one is set (e.g. "App: Zoom"), giving the
/// filter state at-a-glance without needing a separate "currently
/// applied" row.
private struct FilterChipMenu<Content: View>: View {
    let label: String
    let currentValue: String?
    let isActive: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 3) {
                Text(currentValue.map { "\(label): \($0)" } ?? label)
                    .font(.caption)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isActive
                          ? Color.accentColor.opacity(0.2)
                          : Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isActive
                            ? Color.accentColor.opacity(0.5)
                            : Color.secondary.opacity(0.2))
            )
            .foregroundStyle(isActive ? Color.accentColor : Color.primary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}
