import AppKit
import SwiftUI

/// Detail pane shown when the library list has more than one row
/// selected (TECH-A10). Lists the selected meetings and exposes the
/// batch actions that meaningfully roll up across rows: republish to
/// Notion, export markdown bundles into a chosen folder, and move
/// everything to the Trash. The "change workflow" batch action from
/// the spec is left out until TECH-B wires the workflow data model —
/// stubbing it today would mutate sidecar fields no other code reads.

struct BatchActionsPane: View {
    let meetings: [Meeting]
    @ObservedObject var libraryModel: LibraryWindowModel

    enum BatchState: Equatable {
        case idle
        case running(label: String, done: Int, total: Int)
        case finished(label: String, succeeded: Int, failed: Int)
    }

    @State private var state: BatchState = .idle
    @State private var confirmingDelete: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            Divider()
            list
            Divider()
            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .alert(
            "Move \(meetings.count) meetings to Trash?",
            isPresented: $confirmingDelete,
            actions: {
                Button("Move to Trash", role: .destructive) {
                    Task { await runSoftDelete() }
                }
                Button("Cancel", role: .cancel) { }
            },
            message: {
                Text("Every sidecar (audio, transcript, summary) for these meetings goes to the system Trash. You can restore from there until the Trash is emptied.")
            }
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(meetings.count) meetings selected")
                .font(.title3.weight(.semibold))
            Text("Pick a batch action below. Each item runs sequentially so the daemon's processing queue doesn't fan out.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(meetings) { meeting in
                    HStack(spacing: 10) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 6))
                            .foregroundStyle(.tertiary)
                        Text(meeting.displayTitle)
                            .lineLimit(1)
                        Spacer()
                        Text(MeetingFormatters.shortTime.string(from: meeting.startedAt))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 6)
                    Divider().padding(.leading, 20)
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch state {
            case .idle:
                EmptyView()
            case .running(let label, let done, let total):
                HStack(spacing: 8) {
                    ProgressView(value: Double(done), total: Double(max(total, 1)))
                        .progressViewStyle(.linear)
                    Text("\(label) — \(done) / \(total)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            case .finished(let label, let succeeded, let failed):
                Label(
                    "\(label) finished: \(succeeded) succeeded, \(failed) failed",
                    systemImage: failed > 0 ? "exclamationmark.triangle" : "checkmark.circle"
                )
                .font(.caption)
                .foregroundStyle(failed > 0 ? .orange : .secondary)
            }
            HStack {
                Button {
                    Task { await runRepublish() }
                } label: {
                    Label("Republish all", systemImage: "arrow.up.right.square")
                }
                .disabled(isRunning)
                Button {
                    Task { await runExport() }
                } label: {
                    Label("Export markdown…", systemImage: "tray.and.arrow.down")
                }
                .disabled(isRunning)
                Spacer()
                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Label("Move to Trash…", systemImage: "trash")
                }
                .disabled(isRunning)
            }
        }
    }

    private var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    // MARK: Actions

    @MainActor
    private func runRepublish() async {
        let stems = meetings.map(\.stem)
        var ok = 0, bad = 0
        state = .running(label: "Republishing", done: 0, total: stems.count)
        for (i, stem) in stems.enumerated() {
            let result = await libraryModel.republishMeeting(stem: stem)
            switch result {
            case .success: ok += 1
            case .failure: bad += 1
            }
            state = .running(label: "Republishing", done: i + 1, total: stems.count)
        }
        state = .finished(label: "Republish", succeeded: ok, failed: bad)
    }

    @MainActor
    private func runSoftDelete() async {
        let stems = meetings.map(\.stem)
        var ok = 0, bad = 0
        state = .running(label: "Moving to Trash", done: 0, total: stems.count)
        for (i, stem) in stems.enumerated() {
            switch libraryModel.softDeleteMeeting(stem: stem) {
            case .success: ok += 1
            case .failure: bad += 1
            }
            state = .running(label: "Moving to Trash", done: i + 1, total: stems.count)
        }
        state = .finished(label: "Move to Trash", succeeded: ok, failed: bad)
    }

    private func runExport() async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Export here"
        panel.message = "Choose a folder. One markdown file per meeting will be written."
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let captured = meetings
        state = .running(label: "Exporting", done: 0, total: captured.count)
        var ok = 0, bad = 0
        for (i, m) in captured.enumerated() {
            let body = MeetingMarkdownBundle.build(stem: m.stem, in: m.recordingsDir)
            let safe = m.stem.replacingOccurrences(of: "/", with: "-")
            let url = dest.appendingPathComponent("\(safe).md", isDirectory: false)
            do {
                try body.data(using: .utf8)?.write(to: url, options: .atomic)
                ok += 1
            } catch {
                bad += 1
            }
            state = .running(label: "Exporting", done: i + 1, total: captured.count)
        }
        if ok > 0 {
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        }
        state = .finished(label: "Export", succeeded: ok, failed: bad)
    }
}
