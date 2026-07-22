import SwiftUI

/// The three-state Notion database picker (TECH-B8), shared by the workflow
/// editor, Preferences -> Integrations, and onboarding's publish-target step
/// (UX22). Populated cache -> a menu Picker + Refresh; empty cache -> a "Fetch
/// databases" button + a raw id field fallback; loading / failed -> a status
/// line alongside the fallback. The raw id field is always the escape hatch, so
/// a database the integration cannot list is still reachable by pasting its id.
///
/// Extracted verbatim from the inline `WorkflowsView` picker so the three call
/// sites cannot drift.
struct NotionDatabasePicker: View {
    @Binding var databaseID: String
    @ObservedObject var list: NotionDatabaseList
    /// Disable the network fetch (an NDA workflow, or global regulated mode).
    /// `NotionDatabaseList.refresh()` also refuses under regulated mode; this
    /// just greys the button so the refusal is not a surprise.
    var disableFetch: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !list.entries.isEmpty {
                Picker("Database", selection: $databaseID) {
                    Text("(none)").tag("")
                    ForEach(list.entries) { db in
                        Text(db.title).tag(db.id)
                    }
                    // Preserve a manually-pasted id not yet in the cache; without this clause SwiftUI's Picker silently snaps the selection to (none) and the user's input vanishes on the next render.
                    if !databaseID.isEmpty,
                       !list.entries.contains(where: { $0.id == databaseID }) {
                        Text("Custom · \(databaseID.prefix(8))…")
                            .tag(databaseID)
                    }
                }
                .pickerStyle(.menu)
            }
            HStack {
                if list.entries.isEmpty || databaseID.isEmpty {
                    TextField("paste DB id", text: $databaseID)
                        .textFieldStyle(.roundedBorder)
                        .font(.mpTextBase.monospaced())
                        .frame(minWidth: 220)
                }
                Spacer(minLength: 0)
                refreshButton
            }
            statusLabel
        }
    }

    @ViewBuilder
    private var refreshButton: some View {
        Button {
            list.refresh()
        } label: {
            Label(
                list.entries.isEmpty ? "Fetch databases" : "Refresh",
                systemImage: "arrow.clockwise"
            )
        }
        .buttonStyle(.borderless)
        .disabled(list.state == .loading || disableFetch)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch list.state {
        case .idle:
            EmptyView()
        case .loading:
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text("Fetching databases…")
                    .font(.mpTextSM)
                    .foregroundStyle(Color(MPColors.fgMuted))
            }
        case .loaded(let entries):
            Text("\(entries.count) database\(entries.count == 1 ? "" : "s") cached")
                .font(.mpTextXS)
                .foregroundStyle(Color(MPColors.fgSubtle))
        case .failed(let err):
            Text(err)
                .font(.mpTextSM)
                .foregroundStyle(.mpDanger)
                .lineLimit(2)
        }
    }
}
