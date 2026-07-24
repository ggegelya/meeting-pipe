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
    /// Where the merged content landed, shown after a successful merge (FEAT9).
    @State private var mergeNote: String?
    /// ASR3: true while the re-transcribe confirmation is up.
    @State private var confirmingRetranscribe: Bool = false
    /// ASR3: what the last re-transcribe did to the speaker names and text edits
    /// on those meetings. Shown verbatim rather than summarised to "done",
    /// because a dropped override is work the owner did that is now gone.
    @State private var retranscribeNote: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                leadRow
                selectionCard
                mergeCard
                transcriptCard
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
                Text("Every sidecar (audio, transcript, summary) for these meetings goes to the system Trash. "
                     + LibraryDialogs.trashRecoveryNote)
            }
        )
        .alert(
            "Re-transcribe \(meetings.count) meetings?",
            isPresented: $confirmingRetranscribe,
            actions: {
                Button("Re-transcribe") {
                    Task { await runRetranscribe() }
                }
                Button("Cancel", role: .cancel) { }
            },
            message: {
                Text("Each recording is transcribed again from its audio, so the transcript is replaced. Speaker names and text edits are re-anchored onto the new transcript; anything that no longer lines up is dropped, and the count is reported. Summaries are left alone.")
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

    // MARK: Merge card (FEAT9)

    /// Merge a dropped-and-rejoined call's fragments into one meeting. Shown for
    /// any multi-selection; the button is offered only when the pure eligibility
    /// gate passes (same workflow, matching privacy posture, all finished, audio
    /// present), otherwise the card explains why it can't.
    private var mergeCard: some View {
        cardSection(eyebrow: "Merge") {
            VStack(spacing: 0) {
                switch MeetingMergeEligibility.decide(meetings) {
                case .success(let plan):
                    actionRow(
                        icon: "arrow.triangle.merge",
                        title: "Merge into one meeting…",
                        hint: "Joins \(meetings.count) recordings into “\(plan.primary.displayTitle)”, re-summarizes, and republishes. The other fragments move to Trash."
                    )
                    cardFooter {
                        if case .running(let label, _, _) = state, label == "Merging" {
                            Text("Merging \(meetings.count) recordings…")
                                .font(.mpTextXS)
                                .foregroundStyle(Color(MPColors.fgSubtle))
                            Spacer()
                            ProgressView().controlSize(.small)
                        } else if case .finished(let label, let succeeded, let failed) = state,
                                  label == "Merge" {
                            finishedRow(succeeded: succeeded, failed: failed)
                            if let note = mergeNote {
                                Text(note)
                                    .font(.mpTextXS)
                                    .foregroundStyle(Color(MPColors.fgSubtle))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                        } else {
                            Spacer()
                            Button("Merge…") { Task { await runMerge() } }
                                .buttonStyle(MPPrimaryButtonStyle())
                                .disabled(isRunning)
                        }
                    }
                case .failure(let reason):
                    actionRow(
                        icon: "arrow.triangle.merge",
                        title: "Merge into one meeting…",
                        hint: "Rejoin a dropped-and-rejoined call into a single meeting."
                    )
                    cardFooter {
                        Text(reason.reason)
                            .font(.mpTextXS)
                            .foregroundStyle(Color(MPColors.fgSubtle))
                        Spacer()
                    }
                }
            }
        }
    }

    // MARK: Transcript card (ASR3)

    /// Re-transcribe the selection against the current stack. Transcripts are
    /// otherwise frozen at the quality they were captured at: a glossary term or
    /// a roster name added since never reaches an old meeting, and Reprocess /
    /// Regenerate only re-run summarize over the transcript already on disk.
    ///
    /// Runs transcription + finalize only, so it costs nothing and publishes
    /// nothing. Re-summarize is offered afterwards as its own step, because that
    /// is the part that can reach a paid engine and rewrite a published page.
    private var transcriptCard: some View {
        cardSection(eyebrow: "Transcript") {
            VStack(spacing: 0) {
                actionRow(
                    icon: "waveform",
                    title: "Re-transcribe with the current stack\u{2026}",
                    hint: "Transcribes each recording again, picking up glossary terms and roster names learned since. Your speaker names and text edits are carried over. Summaries are untouched."
                )
                cardFooter {
                    if case .running(let label, let done, let total) = state,
                       label == "Re-transcribing" {
                        runningFooter(done: done, total: total, onStop: { cancelRequested = true })
                    } else if case .finished(let label, let succeeded, let failed) = state,
                              label == "Re-transcribe" {
                        finishedRow(succeeded: succeeded, failed: failed)
                            .padding(.trailing, 6)
                        if let note = retranscribeNote {
                            Text(note)
                                .font(.mpTextXS)
                                .foregroundStyle(Color(MPColors.fgSubtle))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        Spacer()
                        // The follow-up the ratchet earns: the new transcript is
                        // on disk, so a summary generated from it is now worth
                        // paying for. Never automatic, because this is the step
                        // that can egress and rewrite a published page.
                        Button("Re-summarize all") { Task { await runRegenerate() } }
                            .buttonStyle(MPPrimaryButtonStyle())
                            .disabled(isRunning)
                    } else if case .finished(let label, let succeeded, let failed) = state,
                              label == "Re-summarize" {
                        finishedRow(succeeded: succeeded, failed: failed)
                            .padding(.trailing, 6)
                        Text("Summaries regenerated from the new transcripts.")
                            .font(.mpTextXS)
                            .foregroundStyle(Color(MPColors.fgSubtle))
                        Spacer()
                    } else if case .running(let label, let done, let total) = state,
                              label == "Re-summarizing" {
                        runningFooter(done: done, total: total, onStop: { cancelRequested = true })
                    } else {
                        Text("On-device. No engine call, nothing published.")
                            .font(.mpTextXS)
                            .foregroundStyle(Color(MPColors.fgSubtle))
                        Spacer()
                        Button("Re-transcribe\u{2026}") { confirmingRetranscribe = true }
                            .buttonStyle(MPSecondaryButtonStyle())
                            .disabled(isRunning)
                    }
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
                    title: "Republish all",
                    hint: "Re-runs the publish step against each selected meeting, fanning out to every sink that meeting's workflow configures. Idempotent: an existing Notion page or Markdown file is updated in place."
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

    /// ASR3. Sequential like every other batch action, so a 20-meeting run never
    /// puts two transcription jobs on the Neural Engine at once; each meeting
    /// still queues behind any live recording's own job.
    @MainActor
    private func runRetranscribe() async {
        let stems = meetings.map(\.stem)
        var ok = 0, bad = 0, carried = 0, dropped = 0, retired = 0
        cancelRequested = false
        retranscribeNote = nil
        state = .running(label: "Re-transcribing", done: 0, total: stems.count)
        for (i, stem) in stems.enumerated() {
            if cancelRequested { break }
            switch await libraryModel.retranscribeMeeting(stem: stem) {
            case .success(let outcome):
                ok += 1
                carried += outcome.carried
                dropped += outcome.dropped
                retired += outcome.retired
            case .failure:
                bad += 1
            }
            state = .running(label: "Re-transcribing", done: i + 1, total: stems.count)
        }
        retranscribeNote = BatchActionsPane.carryNote(carried: carried, dropped: dropped, retired: retired)
        state = .finished(label: "Re-transcribe", succeeded: ok, failed: bad)
    }

    /// One line about what happened to the speaker names and text edits. Nil when
    /// the selection carried none, so an untouched batch shows no filler.
    static func carryNote(carried: Int, dropped: Int, retired: Int) -> String? {
        var parts: [String] = []
        if carried > 0 { parts.append("\(carried) edit\(carried == 1 ? "" : "s") carried") }
        if retired > 0 { parts.append("\(retired) already fixed") }
        if dropped > 0 { parts.append("\(dropped) dropped") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The re-transcribe follow-up: re-summarize each meeting from its new
    /// transcript and republish, reusing the single-meeting Regenerate path.
    @MainActor
    private func runRegenerate() async {
        let stems = meetings.map(\.stem)
        var ok = 0, bad = 0
        cancelRequested = false
        state = .running(label: "Re-summarizing", done: 0, total: stems.count)
        for (i, stem) in stems.enumerated() {
            if cancelRequested { break }
            switch await libraryModel.regenerateMeeting(stem: stem) {
            case .success: ok += 1
            case .failure: bad += 1
            }
            state = .running(label: "Re-summarizing", done: i + 1, total: stems.count)
        }
        state = .finished(label: "Re-summarize", succeeded: ok, failed: bad)
    }

    @MainActor
    private func runMerge() async {
        guard case .success(let plan) = MeetingMergeEligibility.decide(meetings) else { return }
        mergeNote = nil
        state = .running(label: "Merging", done: 0, total: 1)
        let result = await libraryModel.mergeMeetings(
            primary: plan.primary.stem,
            fragments: plan.fragments.map(\.stem)
        )
        switch result {
        case .success(let url):
            mergeNote = url.map { "Published: \($0.absoluteString)" } ?? "Combined summary saved locally."
            state = .finished(label: "Merge", succeeded: 1, failed: 0)
        case .failure:
            state = .finished(label: "Merge", succeeded: 0, failed: 1)
        }
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
        guard let dest = LibraryDialogs.chooseExportFolder(
            message: "Choose a folder. One markdown file per meeting will be written."
        ) else { return }
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
