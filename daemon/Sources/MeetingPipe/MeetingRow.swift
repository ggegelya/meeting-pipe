import AppKit
import SwiftUI

/// One row in the Library list. Title + source glyph + workflow chip
/// (when present) + duration + status pill. Right-click exposes the
/// per-row context menu (TECH-A12).
struct MeetingRow: View {
    @EnvironmentObject var libraryModel: LibraryWindowModel
    let meeting: Meeting

    @State private var inFlight: InFlight? = nil

    enum InFlight: Equatable {
        case republishing
        case regenerating
    }

    var body: some View {
        HStack(spacing: 10) {
            glyph
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.displayTitle)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(MeetingFormatters.shortTime.string(from: meeting.startedAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let d = meeting.durationSec {
                        Text("·").font(.caption).foregroundStyle(.tertiary)
                        Text(Self.formatDuration(d))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let workflow = meeting.workflowName {
                        WorkflowChip(name: workflow, colorHex: meeting.workflowColor)
                    }
                    Spacer(minLength: 0)
                }
            }
            Spacer(minLength: 0)
            if let inFlight = inFlight {
                inFlightBadge(inFlight)
            } else {
                StatusPill(status: meeting.status)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .contextMenu { contextMenuItems }
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        let summaryExists = FileManager.default.fileExists(atPath:
            meeting.recordingsDir.appendingPathComponent("\(meeting.stem).summary.json").path)
        let transcriptExists = FileManager.default.fileExists(atPath:
            meeting.recordingsDir.appendingPathComponent("\(meeting.stem).md").path)

        Button("Re-publish to Notion") {
            Task { await republish() }
        }
        .disabled(!summaryExists || inFlight != nil)

        Button("Regenerate summary") {
            Task { await regenerate() }
        }
        .disabled(!transcriptExists || inFlight != nil)

        Divider()

        Button("Export…") {
            promptExport()
        }
        .disabled(inFlight != nil)

        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([meeting.wavURL])
        }

        Divider()

        Button(role: .destructive) {
            promptDelete()
        } label: {
            Text("Move to Trash…")
        }
        .disabled(inFlight != nil)
    }

    private func inFlightBadge(_ state: InFlight) -> some View {
        HStack(spacing: 4) {
            ProgressView().controlSize(.small)
            Text(state == .republishing ? "Publishing" : "Regenerating")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Actions

    @MainActor
    private func republish() async {
        inFlight = .republishing
        let result = await libraryModel.republishMeeting(stem: meeting.stem)
        inFlight = nil
        if case .failure = result {
            // Coordinator already showed an error notification; nothing
            // more to surface in the row UI.
            return
        }
    }

    @MainActor
    private func regenerate() async {
        inFlight = .regenerating
        let result = await libraryModel.regenerateMeeting(stem: meeting.stem)
        inFlight = nil
        _ = result
    }

    private func promptExport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Export here"
        panel.message = "Choose a folder for the exported bundle (summary, transcript, audio)."
        if panel.runModal() == .OK, let dest = panel.url {
            switch libraryModel.exportMeeting(stem: meeting.stem, to: dest) {
            case .success(let n):
                NSWorkspace.shared.activateFileViewerSelecting([dest])
                Log.writeLine("daemon", "exported \(meeting.stem) → \(dest.path) (\(n) files)")
            case .failure(let err):
                presentAlert(
                    title: "Export failed",
                    message: err.localizedDescription
                )
            }
        }
    }

    private func promptDelete() {
        let alert = NSAlert()
        alert.messageText = "Move \(meeting.displayTitle) to Trash?"
        alert.informativeText = "Every file for this meeting (audio, transcript, summary, sidecars) will go to the Trash. You can restore from there until the Trash is emptied."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            switch libraryModel.softDeleteMeeting(stem: meeting.stem) {
            case .success: break
            case .failure(let err):
                presentAlert(
                    title: "Delete failed",
                    message: err.localizedDescription
                )
            }
        }
    }

    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @ViewBuilder
    private var glyph: some View {
        if let source = meeting.appSource {
            AppGlyphRepresentable(source: source)
                .frame(width: 24, height: 24)
        } else {
            // Manual recordings (⌃⌥M) carry no source. Use the menubar
            // ring as a neutral fallback so the row column stays aligned.
            Image(systemName: "waveform.circle")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
        }
    }

    static func formatDuration(_ s: TimeInterval) -> String {
        let total = Int(s.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let sec = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, sec)
        }
        return String(format: "%d:%02d", m, sec)
    }
}

// MARK: - Workflow chip (placeholder until TECH-B writes workflow_name)

/// Renders the workflow name + accent dot. Shared between the list row
/// and the detail header so styling stays in one place.
struct WorkflowChip: View {
    let name: String
    let colorHex: String?

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(chipColor)
                .frame(width: 6, height: 6)
            Text(name)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.secondary.opacity(0.2))
        )
    }

    private var chipColor: Color {
        if let hex = colorHex, let c = Color(hex: hex) { return c }
        return .secondary
    }
}

// MARK: - Status pill

private struct StatusPill: View {
    let status: Meeting.Status

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.caption2)
                .foregroundStyle(textColor)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(backgroundColor)
        )
    }

    private var label: String {
        switch status {
        case .recording:        return "Recording"
        case .processing:       return "Processing"
        case .manualPasteReady: return "Paste pending"
        case .done:             return "Ready"
        case .unknown:          return "—"
        }
    }

    private var dotColor: Color {
        switch status {
        case .recording:        return Color(MPColors.pulse600)
        case .processing:       return .yellow
        case .manualPasteReady: return .orange
        case .done:             return .green
        case .unknown:          return .secondary
        }
    }

    private var textColor: Color {
        status == .done ? .secondary : .secondary
    }

    private var backgroundColor: Color {
        Color(NSColor.controlBackgroundColor).opacity(0.55)
    }
}

// MARK: - AppGlyphView SwiftUI wrapper

/// `AppGlyphView` is AppKit-only; this bridge lets the SwiftUI row reuse
/// the same glyph resolution (bundle-id first, displayName fallback) the
/// MeetingPromptWindow uses.
private struct AppGlyphRepresentable: NSViewRepresentable {
    let source: AppSource

    func makeNSView(context: Context) -> AppGlyphView {
        AppGlyphView(source: source)
    }

    func updateNSView(_ nsView: AppGlyphView, context: Context) { }
}

// MARK: - Color hex helper

extension Color {
    /// "#RRGGBB" or "RRGGBB" → Color. Returns nil for malformed input so
    /// the workflow chip falls back to the neutral secondary tone.
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        let r = Double((v >> 16) & 0xFF) / 255.0
        let g = Double((v >>  8) & 0xFF) / 255.0
        let b = Double( v        & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}
