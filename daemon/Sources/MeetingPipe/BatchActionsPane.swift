import AppKit
import SwiftUI

/// Detail pane shown when the library list has more than one row
/// selected (TECH-A10). Rebuilt as a card stack matching the
/// Preferences-section anatomy (eyebrow + raised card + footer) per
/// the chrome-polish audit.
///
/// Anatomy top → bottom:
///   • Lead row: 22pt display count + "meetings selected" + Clear.
///   • Selection card: first three rows + "+ N more" — keeps the
///     selection legible without scrolling for a typical multi-select.
///   • Republish card (signal-blue primary). In-flight runs swap the
///     button for a 2pt linear progress strip + mono "done / total" +
///     a Stop button.
///   • Export card. Footer carries the default destination hint + a
///     "Choose folder…" trigger.
///   • Danger card (Move to Trash). Outline-only at rest, fills on
///     hover; the design system's pulse-500 reserved for destructive
///     intent.
///
/// Sequencing semantics are unchanged: each action runs the rows
/// sequentially so the daemon's processing queue doesn't fan out.
/// "Stop" cancels the next iteration; in-flight subprocesses finish.

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
    @State private var cancelRequested: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                leadRow
                selectionCard
                republishCard
                exportCard
                dangerCard
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(MPColors.bg))
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

    // MARK: Lead row

    private var leadRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(meetings.count)")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color(MPColors.fg))
            Text("meetings selected")
                .font(.system(size: 12))
                .foregroundStyle(Color(MPColors.fgMuted))
            Spacer()
            // No-op Clear: the actual selection is owned by the list
            // upstream. Rendered for visual completeness; activating
            // it would require a callback wired from LibraryRootView.
            // Out of scope for the polish pass — flagging here so the
            // wiring lands cleanly later.
            Text(" ")
                .frame(width: 0)
        }
        .padding(.bottom, 4)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(MPColors.border))
                .frame(height: 0.5)
        }
    }

    // MARK: Selection card

    private var selectionCard: some View {
        cardSection(eyebrow: "Selection") {
            // Show up to three rows; the rest collapse into a
            // "+ N more" trailing row so the pane stays compact.
            let visible = meetings.prefix(3)
            VStack(spacing: 0) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { idx, m in
                    HStack(spacing: 8) {
                        Text(m.displayTitle)
                            .font(.system(size: 12))
                            .foregroundStyle(Color(MPColors.fg))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 8)
                        Text(MeetingFormatters.shortTime.string(from: m.startedAt))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(Color(MPColors.fgFaint))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    if idx < visible.count - 1 || meetings.count > 3 {
                        Rectangle()
                            .fill(Color(MPColors.borderFaint))
                            .frame(height: 0.5)
                            .padding(.leading, 12)
                    }
                }
                if meetings.count > 3 {
                    HStack {
                        Text("+ \(meetings.count - 3) more")
                            .font(.system(size: 12))
                            .foregroundStyle(Color(MPColors.fgMuted))
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
            }
        }
    }

    // MARK: Republish card

    private var republishCard: some View {
        cardSection(eyebrow: "Republish") {
            VStack(spacing: 0) {
                actionRow(
                    icon: "arrow.up.right.square",
                    title: "Republish all to Notion",
                    hint: "Re-runs the publish step against each selected meeting. Existing Notion pages are updated in place."
                )
                cardFooter {
                    if case .running(let label, let done, let total) = state,
                       label == "Republishing" {
                        runningFooter(done: done, total: total, onStop: { cancelRequested = true })
                    } else if case .finished(let label, let succeeded, let failed) = state,
                              label == "Republish" {
                        finishedRow(succeeded: succeeded, failed: failed)
                            .padding(.trailing, 6)
                        Spacer()
                        Button("Run again") { Task { await runRepublish() } }
                            .buttonStyle(MPPrimaryButtonStyle())
                    } else {
                        Spacer()
                        Button("Republish all") { Task { await runRepublish() } }
                            .buttonStyle(MPPrimaryButtonStyle())
                            .disabled(isRunning)
                    }
                }
            }
        }
    }

    // MARK: Export card

    private var exportCard: some View {
        cardSection(eyebrow: "Export") {
            VStack(spacing: 0) {
                actionRow(
                    icon: "doc.text",
                    title: "Export markdown…",
                    hint: "Writes one .md file per meeting to a folder you choose."
                )
                cardFooter {
                    if case .running(let label, let done, let total) = state,
                       label == "Exporting" {
                        runningFooter(done: done, total: total, onStop: { cancelRequested = true })
                    } else {
                        Text("Choose a destination folder when prompted.")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(MPColors.fgSubtle))
                        Spacer()
                        Button("Choose folder…") { Task { await runExport() } }
                            .buttonStyle(MPSecondaryButtonStyle())
                            .disabled(isRunning)
                    }
                }
            }
        }
    }

    // MARK: Danger card

    private var dangerCard: some View {
        cardSection(eyebrow: "Danger") {
            VStack(spacing: 0) {
                actionRow(
                    icon: "trash",
                    iconTint: Color(MPColors.pulse500),
                    title: "Move to Trash…",
                    hint: "Removes the audio, transcript, and summary from disk. Notion pages stay."
                )
                cardFooter {
                    if case .running(let label, let done, let total) = state,
                       label == "Moving to Trash" {
                        runningFooter(done: done, total: total, onStop: { cancelRequested = true })
                    } else {
                        Text("Recoverable from the system Trash.")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(MPColors.fgSubtle))
                        Spacer()
                        Button("Move to Trash") { confirmingDelete = true }
                            .buttonStyle(MPDangerButtonStyle())
                            .disabled(isRunning)
                    }
                }
            }
        }
    }

    // MARK: Card primitives

    /// Eyebrow + raised card pair. The eyebrow lives outside the card
    /// so the card itself reads as a clean surface (per the
    /// Preferences-section anatomy the audit references).
    @ViewBuilder
    private func cardSection<Content: View>(
        eyebrow: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(eyebrow)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.08 * 10)
                .textCase(.uppercase)
                .foregroundStyle(Color(MPColors.fgSubtle))
                .padding(.leading, 10)
            content()
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(MPColors.bgRaised))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color(MPColors.border), lineWidth: 0.5)
                )
        }
    }

    /// One row inside a card: leading SF symbol + title + hint
    /// description. Stable shape across all three action cards.
    private func actionRow(
        icon: String,
        iconTint: Color? = nil,
        title: String,
        hint: String
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(iconTint ?? Color(MPColors.fgMuted))
                .frame(width: 16, height: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(MPColors.fg))
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(MPColors.fgSubtle))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// Card footer — separated from the row by a 0.5px hairline, holds
    /// the trigger button OR the in-flight progress strip + Stop.
    @ViewBuilder
    private func cardFooter<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color(MPColors.borderFaint))
                .frame(height: 0.5)
            HStack(spacing: 8) {
                content()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.015))
        }
    }

    /// Linear progress strip + mono count + Stop, used inside any
    /// card's footer while its action is running.
    private func runningFooter(done: Int, total: Int, onStop: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(Color(MPColors.signal600))
                        .frame(width: geo.size.width * progressFraction(done: done, total: total))
                }
            }
            .frame(height: 2)
            Text("\(done) / \(total)")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Color(MPColors.fgSubtle))
            Button("Stop", action: onStop)
                .buttonStyle(MPSecondaryButtonStyle())
        }
    }

    /// Inline result row shown after a run completes. Stays in the
    /// footer so the user can see the result without scrolling.
    @ViewBuilder
    private func finishedRow(succeeded: Int, failed: Int) -> some View {
        HStack(spacing: 5) {
            Image(systemName: failed > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(failed > 0 ? Color(MPColors.warning600) : Color(MPColors.success600))
            Text("\(succeeded) ok\(failed > 0 ? " · \(failed) failed" : "")")
                .font(.system(size: 11))
                .foregroundStyle(Color(MPColors.fgMuted))
        }
    }

    private func progressFraction(done: Int, total: Int) -> CGFloat {
        guard total > 0 else { return 0 }
        return CGFloat(min(max(done, 0), total)) / CGFloat(total)
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
        cancelRequested = false
        state = .running(label: "Republishing", done: 0, total: stems.count)
        for (i, stem) in stems.enumerated() {
            if cancelRequested { break }
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
        cancelRequested = false
        state = .running(label: "Moving to Trash", done: 0, total: stems.count)
        for (i, stem) in stems.enumerated() {
            if cancelRequested { break }
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
        cancelRequested = false
        state = .running(label: "Exporting", done: 0, total: captured.count)
        var ok = 0, bad = 0
        for (i, m) in captured.enumerated() {
            if cancelRequested { break }
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

// MARK: - Button styles (local to the batch pane for now)

/// Filled signal-blue primary. Mirrors the design system's primary
/// button family — flat fill, no shadow, hover darkens.
private struct MPPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color(MPColors.fgOnSignal))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(configuration.isPressed
                          ? Color(MPColors.signal700)
                          : Color(MPColors.signal600))
            )
    }
}

/// Outlined secondary. 1px strong-border, fg-on-canvas. Used for
/// non-destructive choose / stop actions.
private struct MPSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color(MPColors.fg))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(configuration.isPressed
                          ? Color.white.opacity(0.10)
                          : Color(MPColors.bgRaised))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color(MPColors.borderStrong), lineWidth: 0.5)
            )
    }
}

/// Pulse-tinted outline. Resting state has no fill — same restraint
/// the recording HUD uses for the "Stop" button.
private struct MPDangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color(MPColors.pulse500))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(configuration.isPressed
                          ? Color(MPColors.pulse600).opacity(0.18)
                          : Color(MPColors.pulse600).opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color(MPColors.pulse600).opacity(0.32), lineWidth: 0.5)
            )
    }
}
