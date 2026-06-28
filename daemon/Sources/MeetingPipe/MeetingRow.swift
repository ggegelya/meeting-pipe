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
    /// Whether this row is the current list selection. Drives the teal selection
    /// wash that replaces the macOS system-blue highlight (the app `.tint` can't
    /// recolor inset-list selection). Pre-computed by the list against the set.
    let isSelected: Bool

    /// Equates only value-typed fields; closures are excluded because they're re-allocated each render and would defeat `.equatable()`.
    static func == (lhs: MeetingRow, rhs: MeetingRow) -> Bool {
        lhs.meeting == rhs.meeting
            && lhs.isLiveRecording == rhs.isLiveRecording
            && lhs.activeProcessing == rhs.activeProcessing
            && lhs.isSelected == rhs.isSelected
    }

    @State private var inFlight: InFlight? = nil

    enum InFlight: Equatable {
        case republishing
        case regenerating
    }

    var body: some View {
        // Single two-line tile at a fixed height. This row used to adapt between a
        // one-line layout and this tile via ViewThatFits, but inside a List
        // (NSTableView caches row heights) the chosen branch, and so the height,
        // depended on a column width that settled after the first cache. The first
        // rows then rendered crammed into a stale, too-short slot until a
        // scroll-recycle re-measured them. A fixed height gives the list one stable
        // value to cache; dropping ViewThatFits also removes the per-row
        // double-subtree measurement.
        stackedTile
            // TECH-DSN17: no side stripe. The live-recording row reads through the
            // coral wash (rowBackground) plus the coral pulse dot in the status pill.
            .padding(.horizontal, 14)
            .frame(height: 56)
            .background(rowBackground)
            .contentShape(Rectangle())
            .contextMenu { contextMenuItems }
    }

    /// The row layout: title + status on line 1; the caption (source · duration ·
    /// workflow) and the date on line 2. A single fixed-height layout (no
    /// ViewThatFits); see `body` for why the adaptive variant was removed.
    private var stackedTile: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                glyphView
                titleText
                Spacer(minLength: 8)
                trailingStatusCluster
            }
            HStack(spacing: 6) {
                captionContent
                Spacer(minLength: 8)
                Text(RelativeMeetingDateFormatter.string(from: meeting.startedAt))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Color(MPColors.fgMuted))
                    .lineLimit(1)
            }
            .lineLimit(1)
            // Align line 2 under the title, past the 22pt glyph + 10pt spacing.
            .padding(.leading, 32)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 7)
    }

    /// Leading glyph plus the markdown-bundle drag affordance, shared by both
    /// layouts. `.draggable` stays confined to the glyph (Finder/Mail convention):
    /// on the whole row it poisons NSTableView's select gesture so clicks fall
    /// through.
    private var glyphView: some View {
        leadingGlyph
            .frame(width: 22, height: 22)
            .draggable(MeetingDragItem(meeting: meeting))
            .help("Drag to export the markdown bundle")
    }

    /// Meeting title, always full-contrast `fg`. The NDA/local privacy signal is
    /// carried by the lock glyph and the "Local only" pill, not by dimming the
    /// title: local meetings are first-class, not a downgraded summary.
    private var titleText: some View {
        Text(meeting.displayTitle)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color(MPColors.fg))
            .lineLimit(1)
            .truncationMode(.tail)
    }

    /// Trailing status cluster (no date): an in-flight badge, or an optional
    /// inline-fix button plus the status pill / live processing indicator. Shared
    /// by both layouts; the date is appended separately so the tile can move it to
    /// line 2 without the one-line width reservation.
    @ViewBuilder
    private var trailingStatusCluster: some View {
        HStack(spacing: 8) {
            if let inFlight = inFlight {
                inFlightBadge(inFlight)
            } else {
                if effectiveStatus == .failed {
                    inlineFixButton("Retry") { runRetry() }
                } else if effectiveStatus == .manualPasteReady {
                    inlineFixButton("Regenerate") { Task { await regenerate() } }
                } else if showsInlineRepublish {
                    inlineFixButton("Republish") { Task { await republish() } }
                }
                if let progress = activeProcessing {
                    processingIndicator(progress)
                } else {
                    trailingPill
                }
            }
        }
    }

    // MARK: Row pieces

    /// Caption content: app name · duration · workflow chip. Factored without a
    /// trailing spacer so both the one-line VStack and the stacked tile's line 2
    /// can compose it (the tile appends the date after it on the same line).
    @ViewBuilder
    private var captionContent: some View {
        if let src = meeting.sourceDisplayName, !src.isEmpty {
            Text(src)
                .font(.system(size: 11))
                .foregroundStyle(Color(MPColors.fgSubtle))
        }
        if let d = meeting.durationSec {
            if meeting.sourceDisplayName?.isEmpty == false {
                Text("·").font(.mpTextXS).foregroundStyle(Color(MPColors.fgSubtle))
            }
            Text(Self.formatDuration(d))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Color(MPColors.fgSubtle))
        }
        if let workflow = meeting.workflowName, !workflow.isEmpty {
            Text("·").font(.mpTextXS).foregroundStyle(Color(MPColors.fgSubtle))
            WorkflowChip(name: workflow, colorHex: meeting.workflowColor)
        }
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
            switch meeting.publishState {
            case "partial":
                MPStatusPill(kind: .warning, label: "Partial")
                    .help("Published to some targets; at least one sink failed.")
            case "none":
                MPStatusPill(kind: .warning, label: "Unpublished")
                    .help("Every publish target failed for this meeting.")
            default:
                MPStatusPill(kind: .ready, label: "Ready")
            }
        case (.empty, _):
            MPStatusPill(kind: .neutral, label: (meeting.emptyReason ?? .noSpeech).pillLabel)
                .help((meeting.emptyReason ?? .noSpeech).detail)
        case (.unknown, _):
            MPStatusPill(kind: .neutral, label: "-")
        }
    }

    /// Skinny inline-fix button (TECH-DSN17): a compact bordered capsule that
    /// keeps the row light, replacing the stock `.controlSize(.small)` buttons.
    /// The action label stays accurate to what runs (Retry / Regenerate /
    /// Republish), so the same control reads correctly in any scope, including
    /// the "Needs you" rail filter.
    private func inlineFixButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color(MPColors.fg))
                .padding(.horizontal, 9)
                .frame(height: 20)
                .background(
                    RoundedRectangle(cornerRadius: MPRadius.xs, style: .continuous)
                        .fill(Color(MPColors.bgRaised))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: MPRadius.xs, style: .continuous)
                        .strokeBorder(Color(MPColors.borderStrong), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
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
                    // Pin to one line like MPStatusPill (TECH-DSN14); at narrow
                    // widths "Summarizing ..." otherwise wraps to ~3 lines.
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
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

    /// Inline Republish appears when the summary was edited since the last
    /// publish (TECH-UX2) or when a publish failed / only partially landed, so a
    /// row in the "Needs you" scope always carries its own fix (TECH-DSN17).
    /// NDA / local-only rows can never qualify: their `publishState` is nil, so
    /// the partial/none branch cannot fire, and the inline button never offers to
    /// egress a meeting that was kept local by design.
    private var showsInlineRepublish: Bool {
        if meeting.needsRepublish { return true }
        return effectiveStatus == .done
            && (meeting.publishState == "none" || meeting.publishState == "partial")
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

    /// Row wash. Selection wins: a selected row shows the signal-teal selection
    /// wash (replacing the macOS system-blue highlight) even while live-recording;
    /// the coral on-air cue still reads through the pulsing dot in the status pill.
    /// An unselected live row keeps its coral wash; resting rows stay on the canvas.
    @ViewBuilder
    private var rowBackground: some View {
        if isSelected {
            Color.mpSelectionWash
        } else if isLiveRecording {
            Color(MPColors.pulse600).opacity(0.06)
        } else {
            Color.clear
        }
    }

    private var isNDA: Bool {
        // TECH-DSN6: read the resolved zero-egress flag the daemon now persists
        // into the sidecar (an NDA workflow or global regulated mode at record
        // time). A privacy badge must never be inferred, so the old
        // backend == "local" heuristic is gone.
        meeting.isZeroEgress
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        // Sidecar presence is read from the scan (Meeting flags), not a per-row
        // FileManager stat: the context-menu closure is built with the row, so a
        // disk hit here would sit on the scroll path.
        let summaryExists = meeting.hasSummaryJSON
        let transcriptExists = meeting.hasTranscriptMD

        Button("Republish") {
            Task { await republish() }
        }
        .disabled(!summaryExists || inFlight != nil)

        Button("Regenerate summary") {
            Task { await regenerate() }
        }
        .disabled(!transcriptExists || inFlight != nil)

        if meeting.status == .failed {
            Button("Reprocess") {
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
