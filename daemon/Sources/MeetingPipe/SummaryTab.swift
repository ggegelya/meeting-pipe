import AppKit
import SwiftUI

/// Summary tab (TECH-A5). Read-only by default; the Edit button swaps in `CorrectionEditorBody`. Save persists a correction record and overwrites `<stem>.summary.json`; "Save & Republish" additionally spawns `mp publish-notion`.
struct SummaryTab: View {
    @EnvironmentObject var libraryModel: LibraryWindowModel
    /// Observed so an in-place rewrite of this stem's summary.json (after Retry /
    /// Regenerate / a correction edit) bumps `revision` and re-runs the reload
    /// task. Without it the pane kept showing the stale cached summary while a
    /// "Local Markdown ready" banner claimed it was done (the point-3 bug).
    @ObservedObject var store: MeetingStore
    let meeting: Meeting
    /// Bumped by the detail-pane `...` menu's "Edit summary" to enter edit mode (TECH-UI-5).
    var editToken: Int = 0

    /// Loaded off-main on stem change. Caching avoids disk IO on the main thread, which pinned it during recording.
    @State private var loadedSummary: MeetingSummary? = nil
    @State private var loadedForStem: String? = nil
    /// Modification time of the loaded summary.json, so a store-revision bump only
    /// re-parses when this stem's file actually changed on disk.
    @State private var loadedSummaryMtime: Date? = nil

    @State private var isEditing = false
    @State private var editorModel: CorrectionViewModel? = nil
    /// UX13: surfaced save outcome. `saveError` keeps the user in edit with an
    /// inline warning (edits preserved); `savedCue` shows a brief confirmation
    /// before the crossfade back to the reader.
    @State private var saveError: String? = nil
    @State private var savedCue = false

    /// BYO / long-meeting paste-back (TECH-UX3).
    @State private var pasteText = ""
    @State private var pasteSaving = false
    @State private var pasteError: String? = nil

    /// Local re-run preview (TECH-A16): a candidate summary shown next to the
    /// current one, never published until Keep. `candidateStem` tracks which
    /// meeting the candidate belongs to so navigating away cleans it up.
    @State private var candidate: MeetingSummary? = nil
    @State private var candidateStem: String? = nil
    @State private var previewing = false
    @State private var previewError: String? = nil

    /// TECH-FEAT7: reprocess with a custom prompt. `showReprocess` swaps the
    /// reader for a prompt editor; the generated candidate flows into the same
    /// A16 compare + Keep/Discard pane, so it never auto-publishes.
    @State private var showReprocess = false
    @State private var promptDraft = ""

    var body: some View {
        Group {
            if isEditing, let model = editorModel {
                editorBody(model: model)
                    .transition(.opacity)
            } else {
                readOnlyBody
                    .transition(.opacity)
            }
        }
        // UX13: crossfade the read<->edit swap (one of the sanctioned animation
        // moments) instead of a hard cut. Opacity-only keeps the pane frame stable.
        .animation(.easeInOut(duration: MPMotion.durBase), value: isEditing)
        // Reload when the stem changes OR when the store re-scanned (revision
        // bump) so an in-place summary rewrite refreshes the open pane; the mtime
        // guard in reloadSummary keeps unrelated rescans from re-parsing.
        .task(id: SummaryReloadKey(stem: meeting.stem, revision: store.revision)) {
            await reloadSummary()
        }
        .onChange(of: meeting.stem) { _, _ in
            // Discard in-flight edits on stem change; applying old edits to the new row would be a footgun.
            isEditing = false
            editorModel = nil
            saveError = nil
            savedCue = false
            // TECH-A16: drop any unkept candidate preview (and its sidecar) when
            // navigating to another meeting.
            if let s = candidateStem { libraryModel.discardCandidateSummary(stem: s) }
            candidate = nil
            candidateStem = nil
            previewError = nil
            showReprocess = false
            promptDraft = ""
        }
        .onChange(of: editToken) { _, _ in
            // TECH-UI-5: the detail-pane menu requested summary editing.
            beginEditing()
        }
    }

    // MARK: Read-only render

    private var readOnlyBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                if let candidate = candidate, let current = loadedSummary {
                    comparePane(current: current, candidate: candidate)
                } else if showReprocess, loadedSummary != nil {
                    reprocessPane
                } else if let summary = loadedSummary {
                    VStack(alignment: .leading, spacing: 0) {
                        SummaryRenderedView(summary: summary)
                        reprocessBar
                    }
                } else if loadedForStem == meeting.stem {
                    emptyState
                } else {
                    // Load still in flight.
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(40)
                }
            }
            summaryFooter
        }
    }

    /// Current vs candidate, stacked, reusing the structured renderer (TECH-A16).
    private func comparePane(current: MeetingSummary, candidate: MeetingSummary) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Current", systemImage: "doc.text")
                .font(.headline)
                .foregroundStyle(.secondary)
            SummaryRenderedView(summary: current)
            Divider()
            // PRODUCT "no sparkle" rule: a plain inspect glyph, label "Candidate".
            Label("Candidate", systemImage: "doc.text.magnifyingglass")
                .font(.headline)
                .foregroundStyle(.mpSignal)
            SummaryRenderedView(summary: candidate)
        }
        .padding(.bottom, 8)
    }

    /// Footer: re-run/keep/discard for the local preview (TECH-A16). Republish
    /// feedback moved to the row altitude in DSN2 (the needs-republish badge).
    @ViewBuilder
    private var summaryFooter: some View {
        if candidate != nil {
            Divider()
            HStack(spacing: 8) {
                Text("Previewing a new local summary. Keep replaces the current one (you choose whether to publish).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Discard") { discardPreview() }
                Button("Keep") { keepPreview() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        } else if libraryModel.canPreviewLocally, loadedSummary != nil, !showReprocess {
            Divider()
            HStack(spacing: 8) {
                if let err = previewError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.mpWarning).lineLimit(2)
                }
                Spacer()
                if previewing {
                    ProgressView().controlSize(.small)
                    Text("Re-running on-device…").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("Re-run locally (preview)") { Task { await runPreview() } }
                        .help("Re-run summarization with the on-device model and compare, without publishing.")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private var candidateURL: URL {
        meeting.recordingsDir.appendingPathComponent("\(meeting.stem).summary.candidate.json")
    }

    private func runPreview(contextOverride: String? = nil) async {
        previewError = nil
        previewing = true
        let result = await libraryModel.previewSummary(stem: meeting.stem, contextOverride: contextOverride)
        previewing = false
        switch result {
        case .success:
            if let loaded = MeetingSummary.load(from: candidateURL) {
                candidate = loaded
                candidateStem = meeting.stem
                showReprocess = false   // the candidate compare pane takes over
            } else {
                previewError = "The re-run produced no readable summary."
            }
        case .failure(let err):
            previewError = err.localizedDescription
        }
    }

    // MARK: Reprocess with a custom prompt (TECH-FEAT7)

    /// Quiet entry at the foot of the reader: open the prompt editor. Offered on
    /// every backend (unlike the local-only A16 re-run); force-local under
    /// regulated / NDA is still enforced downstream by cloudSecretPolicy.
    private var reprocessBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Not quite right?")
                    .font(.system(size: 12, weight: .medium))
                Text("Edit the prompt and reprocess. You can compare before keeping it.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Reprocess\u{2026}") { beginReprocess() }
                .controlSize(.small)
        }
        .padding(10)
        .overlay(
            RoundedRectangle(cornerRadius: MPRadius.sm, style: .continuous)
                .strokeBorder(Color(MPColors.borderStrong),
                              style: StrokeStyle(lineWidth: 0.5, dash: [4]))
        )
        .frame(maxWidth: SummaryLayout.readingMeasure, alignment: .leading)
        .padding(.horizontal, MPSpace.s5)
        .padding(.bottom, MPSpace.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Prompt editor: edit the context, generate a candidate, never auto-publish.
    /// The result flows into the same A16 compare + Keep/Discard pane.
    private var reprocessPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reprocess with a custom prompt")
                .font(.headline)
            Text("Adjust the context the model is given, then generate a candidate to compare. Your live summary stays untouched until you keep it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Context prompt")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(MPColors.fgMuted))
            TextEditor(text: $promptDraft)
                .font(.system(size: 13))
                .frame(minHeight: 120)
                .overlay(
                    RoundedRectangle(cornerRadius: MPRadius.sm, style: .continuous)
                        .stroke(Color(MPColors.border))
                )
                .disabled(previewing)
            HStack(spacing: 8) {
                if let err = previewError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.mpWarning).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if previewing {
                    ProgressView().controlSize(.small)
                    Text("Reprocessing\u{2026}").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("Cancel") { showReprocess = false; previewError = nil }
                    Button("Generate candidate") { runReprocess() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(MPSpace.s5)
        .frame(maxWidth: SummaryLayout.readingMeasure, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func beginReprocess() {
        promptDraft = libraryModel.effectiveContextPrompt(stem: meeting.stem)
        previewError = nil
        showReprocess = true
    }

    private func runReprocess() {
        // An empty / whitespace prompt sends no override (a plain reprocess on
        // the configured context); the Python side treats it as a no-op too.
        let trimmed = promptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { await runPreview(contextOverride: trimmed.isEmpty ? nil : promptDraft) }
    }

    private func keepPreview() {
        if case .failure(let err) = libraryModel.keepCandidateSummary(stem: meeting.stem) {
            previewError = err.localizedDescription
            return
        }
        candidate = nil
        candidateStem = nil
        Task { await reloadSummary() }   // pick up the promoted summary
    }

    private func discardPreview() {
        libraryModel.discardCandidateSummary(stem: meeting.stem)
        candidate = nil
        candidateStem = nil
    }

    @ViewBuilder
    private var emptyState: some View {
        if meeting.status == .done {
            Text("Summary not on disk yet.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(40)
        } else if meeting.status == .failed {
            failedState
        } else if meeting.status == .manualPasteReady {
            byoPasteState
        } else if meeting.status == .empty {
            Text("No speech was detected, so there is nothing to summarize.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(40)
        } else {
            Text("No summary yet.\nIt appears here once the pipeline finishes.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(40)
        }
    }

    /// In-app paste-back for BYO / long-meeting rows (TECH-UX3): no terminal
    /// command. Saving writes `<stem>.summary.md` and runs publish-from-paste;
    /// failures surface inline (not as a notification).
    private var byoPasteState: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Paste your summary")
                    .font(.headline)
                Text("This meeting was transcribed but left for you to summarize. Paste a Markdown summary below, then Save to parse and publish it through your sinks.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextEditor(text: $pasteText)
                .font(.system(size: 13, design: .monospaced))
                .frame(minHeight: 180)
                .overlay(
                    RoundedRectangle(cornerRadius: 6).stroke(Color(MPColors.border))
                )
                .disabled(pasteSaving)
            if let err = pasteError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.mpWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if pasteSaving {
                    ProgressView().controlSize(.small)
                    Text("Publishing…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Save & publish") {
                    Task { await savePaste() }
                }
                .disabled(pasteSaving || pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func savePaste() async {
        pasteError = nil
        pasteSaving = true
        let result = await libraryModel.publishFromPaste(stem: meeting.stem, summaryText: pasteText)
        pasteSaving = false
        switch result {
        case .success:
            await reloadSummary()   // pick up the freshly written summary.json
        case .failure(let err):
            pasteError = err.localizedDescription
        }
    }

    private var failedState: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.mpWarning)
            Text("Pipeline failed")
                .font(.title3.weight(.semibold))
            if let stage = stageLabel {
                Text("Failed at: \(stage)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let reason = meeting.failureReason, !reason.isEmpty {
                ScrollView {
                    Text(reason)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: 460, maxHeight: 150)
            }
            Button("Retry pipeline") { runRetry() }
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private var stageLabel: String? {
        guard let raw = meeting.failureStage,
              let stage = PipelineFailureSidecar.Stage(rawValue: raw) else {
            return nil
        }
        return stage.displayName
    }

    private func runRetry() {
        switch libraryModel.retryMeeting(stem: meeting.stem) {
        case .success:
            break
        case .failure(let err):
            let alert = NSAlert()
            alert.messageText = "Retry failed"
            alert.informativeText = err.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private var summaryJsonURL: URL {
        meeting.recordingsDir.appendingPathComponent("\(meeting.stem).summary.json")
    }

    private var summaryMarkdownURL: URL {
        meeting.recordingsDir.appendingPathComponent("\(meeting.stem).summary.md")
    }

    /// Identity for the reload task: re-parse when the stem changes OR when the
    /// store re-scanned (revision bump), so an in-place summary rewrite refreshes
    /// the open pane. The mtime guard in `reloadSummary` makes a bump from an
    /// unrelated rescan a no-op.
    private struct SummaryReloadKey: Equatable {
        let stem: String
        let revision: Int
    }

    /// Loads `<stem>.summary.json` off-main. Called via `.task(id:)`; guards
    /// against stale stems and skips the parse when this stem's file is unchanged.
    @MainActor
    private func reloadSummary() async {
        let stem = meeting.stem
        let url = summaryJsonURL
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        // Already showing this stem's summary at this mtime: nothing changed on
        // disk, so a revision bump from an unrelated rescan is a no-op.
        if loadedForStem == stem, loadedSummaryMtime == mtime { return }
        let parsed: MeetingSummary? = await Task.detached(priority: .userInitiated) {
            MeetingSummary.load(from: url)
        }.value
        if meeting.stem == stem {
            loadedSummary = parsed
            loadedForStem = stem
            loadedSummaryMtime = mtime
        }
    }

    // MARK: Editor flow

    private func beginEditing() {
        guard let summary = MeetingSummary.load(from: summaryJsonURL) else {
            return
        }
        let model = CorrectionViewModel(
            stem: meeting.stem,
            recordingsDir: meeting.recordingsDir,
            runMeta: loadRunSidecar() ?? [:],
            originalSummary: summary
        )
        editorModel = model
        saveError = nil
        savedCue = false
        isEditing = true
    }

    private func editorBody(model: CorrectionViewModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            CorrectionEditorBody(model: model, contentPadding: 16, showsNotesField: true)
            Divider()
            footer(model: model)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
    }

    private func footer(model: CorrectionViewModel) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            footerStatus
            Spacer(minLength: 12)
            Button("Cancel") { cancelEditing() }
            // DSN2: one republish path. Save just persists the edit; republish is
            // the single canonical "..." menu / row affordance (the row's
            // needs-republish badge lights up once the summary is newer). Label
            // matches the standalone CorrectionWindow.
            Button("Save correction") { save(model: model) }
                .keyboardShortcut(.defaultAction)
        }
    }

    /// Left side of the footer: an inline warning when the last save failed (the
    /// user stays in edit, edits preserved), a brief success cue, or the resting
    /// helper caption. Reuses the same inline-error idiom as the preview / BYO
    /// rows in this file (UX13).
    @ViewBuilder
    private var footerStatus: some View {
        if let err = saveError {
            Label(err, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.mpWarning)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        } else if savedCue {
            Label("Saved", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.mpSuccess)
        } else {
            Text("Markdown supported. Save keeps it here; republish to push it to your sinks.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Persist the edit and surface the result instead of swallowing it (UX13).
    /// On failure the user stays in edit with the inline warning; on success a
    /// brief cue shows, then the body crossfades back to the reader.
    private func save(model: CorrectionViewModel) {
        guard persistEdit(model: model) else {
            saveError = "Could not save the correction. Check the file permissions and try again."
            return
        }
        saveError = nil
        savedCue = true
        Task {
            // Reflect the edit immediately rather than waiting for the directory
            // watcher's debounced rescan to bump the revision.
            await reloadSummary()
            try? await Task.sleep(nanoseconds: 900_000_000)
            await MainActor.run {
                savedCue = false
                isEditing = false
                editorModel = nil
            }
        }
    }

    private func cancelEditing() {
        saveError = nil
        savedCue = false
        isEditing = false
        editorModel = nil
    }

    /// Writes a correction record (verdict=edited) and overwrites `<stem>.summary.json`. Returns false on disk-write failure.
    private func persistEdit(model: CorrectionViewModel) -> Bool {
        let corrected = model.makeCorrectedSummary()
        let correctedDict = corrected.jsonObject()

        // 1. Correction record (same path as the standalone window so the LoRA training set sees both surfaces identically).
        do {
            try CorrectionStore.write(
                stem: model.stem,
                transcriptPath: model.transcriptPath,
                summaryJsonPath: model.summaryJsonPath,
                modelId: model.modelId,
                backend: model.backend,
                verdict: .edited,
                originalSummary: model.originalSummary.jsonObject(),
                correctedSummary: correctedDict,
                notes: model.notes.isEmpty ? nil : model.notes
            )
            Log.event(category: "library", action: "summary_edited", attributes: [
                "stem": model.stem,
            ])
        } catch {
            Log.main.warning("CorrectionStore.write failed: \(error.localizedDescription)")
            return false
        }

        // 2. Overwrite the live summary so the row, Markdown render, and any future republish see the corrected version (record preserves the original).
        if JSONSerialization.isValidJSONObject(correctedDict),
           let data = try? JSONSerialization.data(
               withJSONObject: correctedDict,
               options: [.prettyPrinted, .sortedKeys]
           ) {
            try? data.write(to: summaryJsonURL, options: .atomic)
        }
        return true
    }

    // MARK: Disk helpers

    private func loadRunSidecar() -> [String: Any]? {
        let url = meeting.recordingsDir.appendingPathComponent("\(meeting.stem).run.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }
}

// MARK: - Structured renderer
