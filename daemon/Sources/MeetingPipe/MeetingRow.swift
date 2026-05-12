import AppKit
import SwiftUI

/// One row in the Library list. Title + source glyph + workflow chip
/// (when present) + duration + status pill. Right-click exposes the
/// per-row context menu (TECH-A12).
///
/// Deliberately holds NO `@ObservedObject` / `@EnvironmentObject` so
/// that broadcasts from `LibraryWindowModel` (status flips, processing
/// queue depth, model-download progress, …) don't invalidate every row
/// in the list. The list owns the model; it computes `isLiveRecording`
/// per row and passes plain closures down for the context-menu
/// actions.
struct MeetingRow: View, Equatable {
    let meeting: Meeting
    /// Pre-computed by the list view. The row never reads
    /// `liveRecordingStem` itself, so changes elsewhere in the model
    /// don't bubble through here.
    let isLiveRecording: Bool
    /// Plain closures so the row neither observes nor strongly retains
    /// the library model.
    let onRepublish: () async -> Void
    let onRegenerate: () async -> Void
    let onRetry: () -> Result<Void, Error>
    let onSoftDelete: () -> Void
    let onExport: (URL) -> Result<Int, Error>

    /// Equatable on value-typed fields only — closures are intentionally
    /// excluded because they're re-allocated by the parent on every
    /// re-render and would defeat the `.equatable()` optimization.
    static func == (lhs: MeetingRow, rhs: MeetingRow) -> Bool {
        lhs.meeting == rhs.meeting && lhs.isLiveRecording == rhs.isLiveRecording
    }

    @State private var inFlight: InFlight? = nil

    enum InFlight: Equatable {
        case republishing
        case regenerating
    }

    var body: some View {
        HStack(spacing: 10) {
            // Drag handle. `.draggable` attached to the *whole* row body
            // poisons SwiftUI's hit-test on macOS: NSTableView's
            // tap-to-select gesture loses to the row-wide drag gesture,
            // and clicks anywhere inside the row content fall through
            // (only the thin strips between rows still register).
            // Confining the draggable to the leading glyph matches the
            // platform convention (Finder, Mail) and leaves the rest of
            // the row free to drive selection.
            glyph
                .frame(width: 24, height: 24)
                .draggable(MeetingDragItem(meeting: meeting))
                .help("Drag to export the markdown bundle")
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
                StatusPill(status: effectiveStatus)
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

        if meeting.status == .failed {
            Button("Retry pipeline") {
                runRetry()
            }
        }

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
        await onRepublish()
        inFlight = nil
    }

    @MainActor
    private func regenerate() async {
        inFlight = .regenerating
        await onRegenerate()
        inFlight = nil
    }

    private func runRetry() {
        switch onRetry() {
        case .success: break
        case .failure(let err):
            presentAlert(title: "Retry failed", message: err.localizedDescription)
        }
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
            switch onExport(dest) {
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
            onSoftDelete()
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

    /// The on-disk status alone can't tell "wav still being written" from
    /// "wav done, pipeline running". The list view sets `isLiveRecording`
    /// when this row's stem matches the daemon's live-recording stem; we
    /// escalate the pill to `.recording` so the user sees the pulse on
    /// the actual in-flight meeting.
    private var effectiveStatus: Meeting.Status {
        isLiveRecording ? .recording : meeting.status
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
            // Only "in flight" states should pulse; .failed is terminal,
            // not active, so it gets a static dot.
            if status == .recording || status == .processing {
                PulsingDot(color: dotColor)
            } else {
                Circle()
                    .fill(dotColor)
                    .frame(width: 6, height: 6)
            }
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
        case .failed:           return "Failed"
        case .unknown:          return "—"
        }
    }

    private var dotColor: Color {
        switch status {
        case .recording:        return Color(MPColors.pulse600)
        case .processing:       return .yellow
        case .manualPasteReady: return .orange
        case .done:             return .green
        case .failed:           return .red
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

// MARK: - Pulsing status dot

/// Subtle infinite-pulse on the status pill's dot. Used for live
/// recordings (recording-tint) and in-flight pipeline runs
/// (processing-tint). The pulse mirrors the menu-bar recording dot's
/// 1 s breath so the two surfaces feel like one device.
private struct PulsingDot: View {
    let color: Color
    @State private var scale: CGFloat = 1.0

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .scaleEffect(scale)
            .onAppear {
                withAnimation(
                    .easeInOut(duration: 1.0).repeatForever(autoreverses: true)
                ) {
                    scale = 1.45
                }
            }
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
