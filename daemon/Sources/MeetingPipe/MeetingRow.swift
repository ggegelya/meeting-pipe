import AppKit
import SwiftUI

/// One Library list row (TECH-A12). Holds no `@ObservedObject`/`@EnvironmentObject` so model broadcasts (status flips, processing ticks) don't invalidate every row. The list computes `isLiveRecording` and passes plain closures for context-menu actions.
struct MeetingRow: View, Equatable {
    let meeting: Meeting
    /// Pre-computed by the list; the row never reads `liveRecordingStem` directly.
    let isLiveRecording: Bool
    /// Live pipeline progress for this row (TECH-UX5); nil unless it is the active job. Pre-matched by the list.
    let activeProcessing: ActiveProcessing?
    /// Plain closures so the row neither observes nor retains the library model.
    let onRepublish: () async -> Void
    let onRegenerate: () async -> Void
    let onRetry: () -> Result<Void, Error>
    let onSoftDelete: () -> Void
    let onExport: (URL) -> Result<Int, Error>
    let onCancelProcessing: () -> Void

    /// Equates only value-typed fields; closures are excluded because they're re-allocated each render and would defeat `.equatable()`.
    static func == (lhs: MeetingRow, rhs: MeetingRow) -> Bool {
        lhs.meeting == rhs.meeting
            && lhs.isLiveRecording == rhs.isLiveRecording
            && lhs.activeProcessing == rhs.activeProcessing
    }

    @State private var inFlight: InFlight? = nil

    enum InFlight: Equatable {
        case republishing
        case regenerating
    }

    var body: some View {
        HStack(spacing: 10) {
            // `.draggable` on the whole row poisons SwiftUI hit-test: NSTableView's select gesture loses to the row-wide drag and clicks fall through. Confining it to the leading glyph (Finder/Mail convention) leaves the rest of the row free for selection.
            leadingGlyph
                .frame(width: 22, height: 22)
                .draggable(MeetingDragItem(meeting: meeting))
                .help("Drag to export the markdown bundle")

            VStack(alignment: .leading, spacing: 1) {
                Text(meeting.displayTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isNDA ? Color(MPColors.fgMuted) : Color(MPColors.fg))
                    .lineLimit(1)
                    .truncationMode(.tail)
                captionLine
            }

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                if let inFlight = inFlight {
                    inFlightBadge(inFlight)
                } else {
                    if effectiveStatus == .failed {
                        retryButton
                    } else if effectiveStatus == .manualPasteReady {
                        regenerateButton
                    } else if meeting.needsRepublish {
                        republishButton
                    }
                    if let progress = activeProcessing {
                        processingIndicator(progress)
                    } else {
                        trailingPill
                    }
                }
                trailingWhenStack
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(rowBackground)
        .overlay(alignment: .leading) {
            // 2pt leading accent for the live-recording row. Inset 6pt vertical so it reads as an accent, not a divider.
            if showsLeadingAccent {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color(MPColors.signal600))
                    .frame(width: 2)
                    .padding(.vertical, 6)
            }
        }
        .contentShape(Rectangle())
        .contextMenu { contextMenuItems }
    }

    // MARK: Row pieces

    /// Caption row: app name · duration · workflow chip. The trailing day/time stack covers the timestamp.
    @ViewBuilder
    private var captionLine: some View {
        HStack(spacing: 6) {
            if let src = meeting.sourceDisplayName, !src.isEmpty {
                Text(src)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(MPColors.fgSubtle))
            }
            if let d = meeting.durationSec {
                if meeting.sourceDisplayName?.isEmpty == false {
                    Text("·").font(.system(size: 11)).foregroundStyle(Color(MPColors.fgFaint))
                }
                Text(Self.formatDuration(d))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Color(MPColors.fgSubtle))
            }
            if let workflow = meeting.workflowName, !workflow.isEmpty {
                Text("·").font(.system(size: 11)).foregroundStyle(Color(MPColors.fgFaint))
                WorkflowChip(name: workflow, colorHex: meeting.workflowColor)
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
    }

    /// Trailing relative date + time (TECH-UI-9). Single monospaced line; the
    /// width is reserved for the longest case ("14 May 2025") so the column
    /// does not jitter as rows cross date boundaries.
    private var trailingWhenStack: some View {
        Text(RelativeMeetingDateFormatter.string(from: meeting.startedAt))
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(Color(MPColors.fgMuted))
            .lineLimit(1)
            .frame(minWidth: 100, alignment: .trailing)
    }

    /// Status pill. NDA rows show "Local only" rather than recording/processing colors; NDA is a privacy mode, not an error.
    @ViewBuilder
    private var trailingPill: some View {
        switch (effectiveStatus, isNDA) {
        case (_, true):
            MPStatusPill(kind: .nda, label: "Local only")
        case (.recording, _):
            MPStatusPill(kind: .recording, label: "Recording")
        case (.processing, _):
            MPStatusPill(kind: .processing, label: "Processing")
        case (.manualPasteReady, _):
            MPStatusPill(kind: .processing, label: "Paste pending")
        case (.failed, _):
            MPStatusPill(kind: .failed, label: "Failed")
                .help(failureHelpText)
        case (.done, _):
            MPStatusPill(kind: .ready, label: "Ready")
        case (.unknown, _):
            MPStatusPill(kind: .neutral, label: "—")
        }
    }

    /// Inline retry button so the owner can act without opening the context menu.
    private var retryButton: some View {
        Button("Retry") { runRetry() }
            .controlSize(.small)
    }

    /// Inline Regenerate on paste-ready rows (TECH-UX2); same action as the context menu.
    private var regenerateButton: some View {
        Button("Regenerate") { Task { await regenerate() } }
            .controlSize(.small)
    }

    /// Live pipeline progress for the active row (TECH-UX5): stage + elapsed, or
    /// a Stalled pill with a Cancel button when the heartbeat lapses.
    @ViewBuilder
    private func processingIndicator(_ p: ActiveProcessing) -> some View {
        if p.stalled {
            HStack(spacing: 6) {
                MPStatusPill(kind: .failed, label: "Stalled")
                Button("Cancel") { onCancelProcessing() }
                    .controlSize(.small)
            }
        } else {
            HStack(spacing: 5) {
                ProgressView().controlSize(.small)
                Text("\(Self.stageLabel(p.stage)) \(MeetingRow.formatDuration(Double(p.elapsedSec)))")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Color(MPColors.fgSubtle))
            }
        }
    }

    /// Maps a pipeline stage id to a present-tense label.
    static func stageLabel(_ stage: String) -> String {
        switch stage {
        case "finalize":        return "Finalizing"
        case "diarize_cleanup": return "Cleaning up"
        case "summarize":       return "Summarizing"
        case "publish":         return "Publishing"
        default:                return "Processing"
        }
    }

    /// Inline Republish when the local summary is newer than the last publish (TECH-UX2).
    private var republishButton: some View {
        Button("Republish") { Task { await republish() } }
            .controlSize(.small)
    }

    /// Hover text for the failed pill: persisted reason when available, generic fallback for staleness-age-inferred failures.
    private var failureHelpText: String {
        if let reason = meeting.failureReason, !reason.isEmpty {
            return reason
        }
        return "The pipeline did not finish for this meeting."
    }

    /// Leading glyph; swaps to a lock for NDA meetings (privacy mode trumps source identity).
    @ViewBuilder
    private var leadingGlyph: some View {
        if isNDA {
            Image(systemName: "lock.fill")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Color(MPColors.fgSubtle))
                .frame(width: 22, height: 22)
        } else if let source = meeting.appSource {
            AppGlyphRepresentable(source: source)
                .frame(width: 22, height: 22)
        } else {
            // Manual recordings (⌃⌥M) have no source; use the waveform ring to keep the column aligned.
            Image(systemName: "waveform.circle")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
        }
    }

    /// Pulse-tinted background wash for the live row; resting rows stay on the canvas.
    @ViewBuilder
    private var rowBackground: some View {
        if isLiveRecording {
            Color(MPColors.pulse600).opacity(0.06)
        } else {
            Color.clear
        }
    }

    private var showsLeadingAccent: Bool { isLiveRecording }

    private var isNDA: Bool {
        // TECH-B9: the authoritative flag is `workflow.flags.ndaMode`, but the row has no WorkflowStore and the sidecar doesn't yet persist the resolved flag. Heuristic: lock when backend == "local" and a workflow is set.
        if meeting.backend == "local",
           meeting.workflowName?.isEmpty == false {
            return true
        }
        return false
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

    /// On-disk status alone can't distinguish "wav being written" from "pipeline running"; escalate to `.recording` when `isLiveRecording` is set.
    private var effectiveStatus: Meeting.Status {
        isLiveRecording ? .recording : meeting.status
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

// MARK: - AppGlyphView SwiftUI wrapper

/// NSViewRepresentable bridge so the SwiftUI row can reuse `AppGlyphView`'s bundle-id-first glyph resolution.
private struct AppGlyphRepresentable: NSViewRepresentable {
    let source: AppSource

    func makeNSView(context: Context) -> AppGlyphView {
        AppGlyphView(source: source)
    }

    func updateNSView(_ nsView: AppGlyphView, context: Context) { }
}

// MARK: - Color hex helper

extension Color {
    /// "#RRGGBB" / "RRGGBB" → Color. Nil for malformed input so the chip falls back to the neutral tone.
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
