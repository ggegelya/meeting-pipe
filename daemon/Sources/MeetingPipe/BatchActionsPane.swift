import AppKit
import SwiftUI

/// Multi-selection action pane (TECH-A10). Card stack: lead row, selection preview, Republish, Export, and Danger (Trash). Actions run sequentially so the processing queue doesn't fan out; Stop cancels the next iteration but lets in-flight subprocesses finish.

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
                .font(.mpTextXL.weight(.semibold))
                .foregroundStyle(Color(MPColors.fg))
            Text("meetings selected")
                .font(.mpTextSM)
                .foregroundStyle(Color(MPColors.fgMuted))
            Spacer()
            // No-op placeholder; selection is owned upstream by LibraryRootView. Wiring a callback is out of scope for the polish pass.
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
            // Show up to three rows; remainder collapses to "+ N more".
            let visible = meetings.prefix(3)
            VStack(spacing: 0) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { idx, m in
                    HStack(spacing: 8) {
                        Text(m.displayTitle)
                            .font(.mpTextSM)
                            .foregroundStyle(Color(MPColors.fg))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 8)
                        Text(MeetingFormatters.shortTime.string(from: m.startedAt))
                            .font(.mpTextXS.monospacedDigit())
                            .foregroundStyle(Color(MPColors.fgSubtle))
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
                            .font(.mpTextSM)
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
                            .font(.mpTextXS)
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
                            .font(.mpTextXS)
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

    /// Eyebrow label + raised card. The eyebrow lives outside the card so the card surface stays clean.
    @ViewBuilder
    private func cardSection<Content: View>(
        eyebrow: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(eyebrow)
                .font(.mpTextXS.weight(.semibold))
                .tracking(0.08 * 10)
                .textCase(.uppercase)
                .foregroundStyle(Color(MPColors.fgSubtle))
                .padding(.leading, 10)
            content()
                .mpSurface(radius: 10, borderWidth: 0.5) // DSN19: the one raised-card primitive
        }
    }

    /// Leading icon + title + hint row, consistent across all action cards.
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
                    .font(.mpTextSM)
                    .foregroundStyle(Color(MPColors.fg))
                Text(hint)
                    .font(.mpTextXS)
                    .foregroundStyle(Color(MPColors.fgSubtle))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// Card footer below a 0.5px hairline: trigger button at rest, or progress strip + Stop while running.
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
            .background(Color.mpOverlayFaint)
        }
    }

    /// Linear progress strip + mono count + Stop button for any running action.
    private func runningFooter(done: Int, total: Int, onStop: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(Color.mpOverlayHover)
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(Color(MPColors.signal600))
                        .frame(width: geo.size.width * progressFraction(done: done, total: total))
                }
            }
            .frame(height: 2)
            Text("\(done) / \(total)")
                .font(.mpTextXS.monospacedDigit())
                .foregroundStyle(Color(MPColors.fgSubtle))
            Button("Stop", action: onStop)
                .buttonStyle(MPSecondaryButtonStyle())
        }
    }

    /// Inline result row shown after a run completes, in the footer so the result is visible without scrolling.
    @ViewBuilder
    private func finishedRow(succeeded: Int, failed: Int) -> some View {
        HStack(spacing: 5) {
            Image(systemName: failed > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(failed > 0 ? Color(MPColors.warning600) : Color(MPColors.success600))
            Text("\(succeeded) ok\(failed > 0 ? " · \(failed) failed" : "")")
                .font(.mpTextXS)
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

/// Filled signal-blue primary button.
private struct MPPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.mpTextSM.weight(.medium))
            .foregroundStyle(Color(MPColors.fgOnSignal))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    // White label needs >= 4.5:1, so the resting fill is signal700
                    // (6.0:1), not signal600 (4.1:1) (UX14); press lifts to signal600.
                    .fill(configuration.isPressed
                          ? Color(MPColors.signal600)
                          : Color(MPColors.signal700))
            )
    }
}

/// Outlined secondary button. Used for non-destructive choose/stop actions.
private struct MPSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.mpTextSM.weight(.medium))
            .foregroundStyle(Color(MPColors.fg))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(configuration.isPressed
                          ? Color.mpOverlayPress
                          : Color(MPColors.bgRaised))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color(MPColors.borderStrong), lineWidth: 0.5)
            )
    }
}

/// Pulse-tinted outline button, no fill at rest (matches the recording HUD's Stop button).
private struct MPDangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.mpTextSM.weight(.medium))
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
