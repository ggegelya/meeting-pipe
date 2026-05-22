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
                    }
                    trailingPill
                }
                trailingWhenStack
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(rowBackground)
        .overlay(alignment: .leading) {
            // 2pt signal accent on the leading edge for the active /
            // live-recording row — the design system's selected-row
            // treatment ported from the audit. Inset 6pt vertical so
            // it reads as an accent, not a full divider.
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

    /// Caption row: app name · duration · workflow chip. Drops the
    /// duplicate time stamp (the trailing day/time stack covers that)
    /// and folds the workflow chip inline as the third token.
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

    /// Trailing mono day/time stack — the audit's collapsed channel.
    /// "Yest 15:00" reads in two lines stacked, monospaced so a column
    /// of rows aligns.
    private var trailingWhenStack: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(relativeDayLabel)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Color(MPColors.fgMuted))
            Text(MeetingFormatters.shortTime.string(from: meeting.startedAt))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Color(MPColors.fgSubtle))
        }
        .frame(minWidth: 44, alignment: .trailing)
    }

    /// Status pill resolved through the design-audit's tone family. NDA
    /// rows surface as a muted "Local only" pill rather than the
    /// recording / processing colors — NDA isn't an error, just a
    /// privacy mode.
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

    /// Inline one-click retry for a failed row: the audit's fix for
    /// Retry being right-click-only. Sits next to the Failed pill so the
    /// owner sees the action without opening the context menu.
    private var retryButton: some View {
        Button("Retry") { runRetry() }
            .controlSize(.small)
    }

    /// Hover text for the failed pill: the persisted reason when the
    /// failure sidecar supplied one, a generic line for a `.failed` row
    /// inferred only from the staleness age heuristic.
    private var failureHelpText: String {
        if let reason = meeting.failureReason, !reason.isEmpty {
            return reason
        }
        return "The pipeline did not finish for this meeting."
    }

    /// Leading glyph — swaps to a lock for NDA / local-only meetings
    /// per the audit (NDA row's source is irrelevant; the privacy mode
    /// is the salient property).
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
            // Manual recordings (⌃⌥M) carry no source. Use the menubar
            // ring as a neutral fallback so the row column stays aligned.
            Image(systemName: "waveform.circle")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
        }
    }

    /// Subtle background wash: signal-tinted for the active / live row,
    /// pulse-tinted for any other live recording. Resting rows stay on
    /// the canvas — the design system's "hairlines, not fills" rule.
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
        // Per TECH-B9 the workflow's `flags.ndaMode` drives this — but
        // the row doesn't have the WorkflowStore at hand and the
        // sidecar doesn't (yet) persist the resolved flag. As a
        // visual-only heuristic we surface the lock when the meeting's
        // workflow color matches the pulse/danger family AND the
        // meeting's backend was forced to `local`. Both signals are
        // already on the meeting row.
        if meeting.backend == "local",
           meeting.workflowName?.isEmpty == false {
            return true
        }
        return false
    }

    /// "Today" / "Yest" / "Mon" / "May 8" — relative-date label for
    /// the trailing stack. Mirrors the spec mock's mono treatment so
    /// adjacent rows align.
    private var relativeDayLabel: String {
        let cal = Calendar.current
        let now = Date()
        let started = meeting.startedAt
        if cal.isDateInToday(started) { return "Today" }
        if cal.isDateInYesterday(started) { return "Yest" }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: started), to: cal.startOfDay(for: now)).day,
           days >= 0, days < 7 {
            return MeetingFormatters.shortWeekday.string(from: started)
        }
        return MeetingFormatters.shortMonthDay.string(from: started)
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
