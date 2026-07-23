import SwiftUI

/// Pure one-line rendering of what a saved folder actually holds (UX24). The name alone
/// says nothing ("Q3 stuff"), so the rail row uses this for its tooltip and its
/// VoiceOver hint, and the naming sheet shows it as a live preview of what is about to
/// be saved.
///
/// `sourceNames` maps a bundle id to its display name; an unresolved id falls back to
/// the raw bundle id, which is never wrong, only less readable.
enum SavedSearchSummary {
    static func text(for search: SavedSearch, sourceNames: [String: String] = [:]) -> String {
        parts(for: search, sourceNames: sourceNames).joined(separator: " · ")
    }

    static func parts(for search: SavedSearch, sourceNames: [String: String] = [:]) -> [String] {
        var out: [String] = []
        if search.base != .allMeetings { out.append(search.base.scope.title) }

        let query = search.filter.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty { out.append("\"\(query)\"") }

        if let wf = search.filter.workflow { out.append(wf) }
        if let bundleID = search.filter.sourceBundleID {
            out.append(sourceNames[bundleID] ?? bundleID)
        }
        if let status = search.filter.status { out.append(statusLabel(status)) }
        if search.filter.dateRange != .all { out.append(search.filter.dateRange.rawValue) }

        // A folder over the whole library with no chips is legal (an all-meetings
        // bookmark); say so rather than rendering an empty tooltip.
        return out.isEmpty ? ["All meetings"] : out
    }

    /// Mirrors `FilterBarView.statusLabel` so the summary and the chip read alike.
    static func statusLabel(_ status: Meeting.Status) -> String {
        switch status {
        case .recording:        return "Recording"
        case .processing:       return "Processing"
        case .manualPasteReady: return "Manual paste ready"
        case .done:             return "Done"
        case .empty:            return "No speech"
        case .failed:           return "Failed"
        case .unknown:          return "Unknown"
        }
    }
}

/// Name-a-smart-folder sheet (UX24), used for both "Save as smart folder" and the rail
/// row's "Rename…". Deliberately one field and a criteria preview: the criteria come
/// from the view the user is already looking at, so there is nothing else to edit here.
struct SmartFolderNameSheet: View {
    let title: String
    let confirmLabel: String
    /// Criteria preview, or nil when renaming (the folder's criteria are unchanged and
    /// the rail row's tooltip already shows them).
    let summary: String?
    /// Returns a warning to show under the field, or nil when the name is fine.
    let validate: (String) -> String?
    let onCancel: () -> Void
    let onConfirm: (String) -> Void

    @State private var name: String = ""
    @FocusState private var fieldFocused: Bool

    init(
        title: String,
        confirmLabel: String,
        initialName: String = "",
        summary: String? = nil,
        validate: @escaping (String) -> String? = { _ in nil },
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (String) -> Void
    ) {
        self.title = title
        self.confirmLabel = confirmLabel
        self.summary = summary
        self.validate = validate
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        _name = State(initialValue: initialName)
    }

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.mpTextMD.weight(.semibold))

            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(.mpTextSM)
                .focused($fieldFocused)
                .onSubmit { if !trimmed.isEmpty { onConfirm(trimmed) } }
                .accessibilityLabel("Smart folder name")

            if let warning = validate(trimmed), !trimmed.isEmpty {
                Label {
                    Text(warning).font(.mpTextXS)
                } icon: {
                    Image(systemName: "exclamationmark.triangle").font(.mpTextXS)
                }
                .foregroundStyle(Color.mpWarning)
            }

            if let summary {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Saves")
                        .font(.mpTextXS.weight(.semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(Color(MPColors.fgMuted))
                    Text(summary)
                        .font(.mpTextXS)
                        .foregroundStyle(Color(MPColors.fgMuted))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 2)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(confirmLabel) { onConfirm(trimmed) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
            .padding(.top, 4)
        }
        .padding(18)
        .frame(width: 360)
        .onAppear { fieldFocused = true }
    }
}
