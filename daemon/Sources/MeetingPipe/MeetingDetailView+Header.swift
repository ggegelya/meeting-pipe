import AppKit
import SwiftUI

/// UX78: whether the detail header shows a playback transport, and what it reads.
///
/// The player is a `@StateObject` on the detail view and outlives a tab switch, which is
/// deliberate: it is what lets a summary citation jump into the transcript and keep its play head.
/// What was missing is that every transport control lives inside `AudioTab` and `TranscriptTab`, so
/// selecting Summary removed the whole surface while the audio kept going. The owner's report is
/// exact: "I have no controls, and playback still running". With nothing on screen to press, the
/// only exits were switching back to a tab that has controls or closing the window, which on a
/// shared screen is worse than inconvenient.
///
/// So the header grows a transport, and it is a decision rather than an `if isPlaying` because two
/// of its three rules are not about playing. Pausing from the header must not make the header
/// vanish, or the control that just stopped the audio cannot restart it. And after switching
/// meetings the player still holds the *previous* meeting's file, so a transport shown then would
/// play the wrong audio under the right title; the URL check is what makes that unreachable rather
/// than unlikely.
struct DetailTransport: Equatable {
    /// "1:05 / 42:18", in the same clock the rest of the Library uses.
    let position: String
    /// Drives the glyph and the accessibility label. Filled glyphs, matching `AudioTab`'s own
    /// transport rather than inventing a second vocabulary for the same control.
    let isPlaying: Bool

    var systemImage: String { isPlaying ? "pause.fill" : "play.fill" }
    var actionLabel: String { isPlaying ? "Pause" : "Play" }

    /// Nil means the header shows nothing, which is the resting state: the band must not grow a
    /// permanent row for a player nobody has started.
    static func decide(
        loadedURL: URL?,
        meetingAudioURL: URL?,
        isPlaying: Bool,
        currentTime: TimeInterval,
        duration: TimeInterval
    ) -> DetailTransport? {
        // The loaded file has to be this meeting's. Switching meetings from the Summary tab loads
        // nothing (only the two audio-bearing tabs call `load`), so without this the header would
        // offer a transport over the meeting the user just left.
        guard let loaded = loadedURL, let expected = meetingAudioURL, loaded == expected else {
            return nil
        }
        // A play head exists once it is playing or parked part-way through. Paused counts, so the
        // control survives its own press.
        guard isPlaying || currentTime > 0 else { return nil }
        return DetailTransport(
            position: "\(MeetingRow.formatDuration(currentTime)) / \(MeetingRow.formatDuration(duration))",
            isPlaying: isPlaying
        )
    }
}

// TECH-UI-X1: header rendering + title-editing/toolbar actions split out of
// MeetingDetailView.swift so the detail container stays focused on tab
// plumbing. Same type, a different file.
extension MeetingDetailView {

    // MARK: Header

    var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let origin = libraryModel.openedFromInsight, origin.stem == meeting.stem {
                contextBanner(origin.source)
            }
            titleRow
            titleField
            captionRow
            provenanceRow
            if meeting.hasCorrections { editedCaption }
            if meeting.namesChangedSinceSummary { namesChangedCaption }
            if let earlier = resumedEarlierPart { resumedCaption(earlier: earlier) }
            processingRow
            transportRow
            publishStateLine
        }
    }

    /// UX78: play/pause and position, on every tab, for as long as there is a play head. Sits with
    /// `processingRow` because it is the same kind of row: conditional chrome reporting something
    /// in flight, with the one control for it beside the text. Play/pause and position only; the
    /// waveform, rate, channel and skip-silence controls stay in `AudioTab` where they belong.
    @ViewBuilder
    var transportRow: some View {
        if let transport = DetailTransport.decide(
            loadedURL: playback.loadedURL,
            meetingAudioURL: meeting.audioURL,
            isPlaying: playback.isPlaying,
            currentTime: playback.currentTime,
            duration: playback.duration
        ) {
            HStack(spacing: 8) {
                Button { playback.togglePlayPause() } label: {
                    Image(systemName: transport.systemImage)
                }
                .buttonStyle(.plain)
                .controlSize(.small)
                .fixedSize()
                .help("\(transport.actionLabel) this meeting's audio")
                .accessibilityLabel(transport.actionLabel)
                Text(transport.position)
                    .font(.mpTextXS.monospacedDigit())
                    .foregroundStyle(Color(MPColors.fgSubtle))
                    .lineLimit(1)
                    .accessibilityLabel("Position \(transport.position)")
            }
            .accessibilityElement(children: .contain)
        }
    }

    /// What the pipeline is doing for this meeting, and the control for it
    /// (UX28). The detail pane used to show nothing at all for a re-summarize
    /// started from its own `...` menu: the only busy state lived in the list
    /// row's private `@State`, so the surface the user was looking at when they
    /// clicked was the one surface that could not report it.
    @ViewBuilder
    var processingRow: some View {
        let processing = libraryModel.processing(for: meeting.stem)
        if processing.isBusy {
            HStack(spacing: 8) {
                if processing.isStalled {
                    MPStatusPill(kind: .failed, label: "Stalled")
                } else if processing.canCancel {
                    ProgressView().controlSize(.small)
                }
                // The label yields width, the control does not (same contract as
                // MeetingRow's processing cluster). Without `fixedSize` on the
                // button, a narrow detail pane compresses its title instead of
                // the prose and the control renders unlabelled.
                Text(processing.label)
                    .font(.mpTextXS)
                    .foregroundStyle(Color(MPColors.fgSubtle))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(processing.label)
                if processing.canCancel {
                    Button("Cancel") { libraryModel.cancelProcessing() }
                        .controlSize(.small)
                        .fixedSize()
                        .accessibilityLabel("Cancel processing")
                } else if let job = processing.queuedJob {
                    Button("Remove") { libraryModel.dequeueProcessing(id: job.id) }
                        .controlSize(.small)
                        .fixedSize()
                        .accessibilityLabel("Remove \(job.label) from the queue")
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    /// Dismissible "Opened from Facts/Ask" banner (DSN22 #9): those projections snap
    /// the scope to All meetings, so a small line explains why the surrounding list
    /// changed. Keyed to the opened stem, so navigating away hides it on its own.
    func contextBanner(_ source: String) -> some View {
        HStack(spacing: 8) {
            Text("Opened from \(source)")
                .font(.mpTextXS)
                .foregroundStyle(Color(MPColors.fgMuted))
            Button {
                libraryModel.openedFromInsight = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.mpTextXS)
                    .foregroundStyle(Color(MPColors.fgSubtle))
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 11)
        .padding(.trailing, 7)
        .frame(height: 23)
        .background(Capsule(style: .continuous).fill(Color(MPColors.bgSunk)))
        .overlay(Capsule(style: .continuous).strokeBorder(Color(MPColors.border), lineWidth: 0.5))
        .padding(.bottom, 4)
    }

    /// Edited-locally caption (DSN22 #6): the meeting carries a summary-correction
    /// record. Quiet, the same register as the provenance line above it.
    ///
    /// `fgSubtle`, not the mockup's fainter token: at `mpTextXS` this is the
    /// smallest type step in the header, and `fgFaint` sits near 2.8:1 against a
    /// 4.5:1 body floor (DSN18). The caption below it moved off `fgFaint` for
    /// exactly that reason and this one had been left behind (DOC12 item 10).
    var editedCaption: some View {
        HStack(spacing: 5) {
            Image(systemName: "pencil")
                .font(.mpTextXS)
                .foregroundStyle(Color(MPColors.fgSubtle))
            Text("Summary edited locally")
                .font(.mpTextXS)
                .foregroundStyle(Color(MPColors.fgSubtle))
        }
        .accessibilityElement(children: .combine)
    }

    /// Names-changed cue (UX41): the speaker overlay was written after the run
    /// that produced this summary, so the transcript says Anisha while the
    /// summary still says THEM-3. Nothing else says why, because display
    /// surfaces re-resolve the overlay and generated prose cannot: rewriting
    /// names inside the model's sentences would be unreliable (this library is
    /// half Ukrainian, where names decline by case) and would falsify what the
    /// summary claims to be. So the cue is truthful and the fix is one click,
    /// through the same menu the `...` menu offers, which means an NDA meeting's
    /// cue leads to the local-only offering rather than to a cloud call the
    /// clamp would silently substitute (UX29).
    ///
    /// Register: the caption slot beside "Summary edited locally", one line, no
    /// pill and no tint. `fgSubtle`, like that neighbour and like the provenance
    /// row above it: `fgFaint` sits near 2.8:1 against a 4.5:1 body floor, so
    /// nothing in this stack uses the mockup's fainter token.
    /// It clears itself: a re-summarize rewrites `run.json`'s `ts` (PIPE11), so
    /// the comparison behind it flips back on the next scan.
    var namesChangedCaption: some View {
        HStack(spacing: 5) {
            Image(systemName: "person.crop.circle")
                .font(.mpTextXS)
                .foregroundStyle(Color(MPColors.fgSubtle))
            Text("Speaker names changed after this summary.")
                .font(.mpTextXS)
                .foregroundStyle(Color(MPColors.fgSubtle))
                .fixedSize(horizontal: false, vertical: true)
            // The menu indicator stays visible here, unlike `actionsMenu`: that
            // label is an ellipsis glyph that already reads as a menu, and a
            // bare word in a caption row would read as more caption.
            Menu {
                reSummarizeItems
            } label: {
                Text("Re-summarize")
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()
            .help("Re-summarize this meeting so the summary uses the current speaker names")
            .accessibilityLabel("Re-summarize with the current speaker names")
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
    }

    /// END17 item 5: the recording this one resumed from, while it is still in the library. Nil
    /// once a merge folded this one in or the earlier part was deleted, so the offer clears itself.
    var resumedEarlierPart: Meeting? {
        guard let stem = meeting.resumedFrom else { return nil }
        return store.meetings.first { $0.stem == stem }
    }

    /// END17 item 5: this recording started because the same call came back right after an end,
    /// so it is probably the rest of the earlier one. Same caption slot and register as the
    /// names-changed cue, with the one action that joins them.
    func resumedCaption(earlier: Meeting) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "link")
                .font(.mpTextXS)
                .foregroundStyle(Color(MPColors.fgSubtle))
            Text(resumeMergeError ?? "Picks up where \(earlier.displayTitle) stopped.")
                .font(.mpTextXS)
                .foregroundStyle(Color(MPColors.fgSubtle))
                .fixedSize(horizontal: false, vertical: true)
            if mergingResumed {
                ProgressView().controlSize(.small)
            } else {
                Button("Merge") {
                    mergingResumed = true
                    resumeMergeError = nil
                    Task {
                        if case .failure(let error) = await libraryModel.mergeResumed(stem: meeting.stem) {
                            resumeMergeError = error.localizedDescription
                        }
                        mergingResumed = false
                    }
                }
                .controlSize(.small)
                .fixedSize()
                .help("Join this recording onto the earlier one as a single meeting, including the part the earlier recording held back")
                .accessibilityLabel("Merge with the earlier part of this meeting")
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
    }

    /// Publish-state line (DSN22 #4): a boxed status row that explains failures and
    /// local-only intent inline, surfacing the parsed failure reason. Shown only
    /// for states that want attention or are kept local; a cleanly-published
    /// meeting stays calm (no green banner), keeping with the quiet register.
    @ViewBuilder
    var publishStateLine: some View {
        if let info = publishStateInfo {
            HStack(spacing: 7) {
                Image(systemName: info.icon)
                    .font(.mpTextXS)
                    .foregroundStyle(info.tint)
                Text(info.text)
                    .font(.mpTextXS)
                    .foregroundStyle(Color(MPColors.fgMuted))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: MPRadius.sm, style: .continuous)
                    .fill(Color(MPColors.bgSunk))
            )
            .overlay(
                RoundedRectangle(cornerRadius: MPRadius.sm, style: .continuous)
                    .strokeBorder(Color(MPColors.border), lineWidth: 0.5)
            )
            .padding(.top, 4)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(info.text)
        }
    }

    /// Icon + tint + copy for the publish-state line, or nil to hide it (cleanly
    /// published, non-NDA). The failure reason rides on the `.failed` line, the one
    /// state whose error sidecar the scan reads into `failureReason`.
    private var publishStateInfo: (icon: String, tint: Color, text: String)? {
        // Actionable states first, so a failed / no-speech / paste-pending NDA
        // meeting still shows what needs doing rather than only "Kept local".
        switch meeting.status {
        case .failed:
            return nil
        case .empty:
            return ("exclamationmark.triangle", Color(MPColors.warning600),
                    (meeting.emptyReason ?? .noSpeech).detail)
        case .manualPasteReady:
            return ("exclamationmark.circle", Color(MPColors.warning600),
                    "Too long for an automatic summary. The transcript bundle is ready to paste.")
        case .done:
            if meeting.isZeroEgress {
                return ("lock.fill", Color(MPColors.fgSubtle),
                        "Kept local. On this Mac by design (NDA workflow).")
            }
            if meeting.publishState == "none" {
                return ("exclamationmark.circle", Color(MPColors.warning600), "Not published yet.")
            }
            if meeting.publishState == "partial" {
                return nil
            }
            return nil   // cleanly published: stay calm
        default:
            return nil
        }
    }

    /// Title as click-to-rename (TECH-UI-5). Static text until clicked, then an
    /// inline field; Return commits, Escape reverts, focus-loss commits.
    @ViewBuilder
    var titleField: some View {
        if isRenamingTitle {
            TextField("Untitled meeting", text: $editingTitle)
                .textFieldStyle(.plain)
                .font(.mpTextLG.weight(.semibold))
                .lineLimit(2)
                .focused($titleFieldFocused)
                .onSubmit { commitRename() }
                .onExitCommand { cancelRename() }
                .onChange(of: titleFieldFocused) { _, focused in
                    if !focused && isRenamingTitle { commitRename() }
                }
        } else {
            Text(editingTitle.isEmpty ? "Untitled meeting" : editingTitle)
                .font(.mpTextLG.weight(.semibold))
                .foregroundStyle(Color(MPColors.fg))
                .lineLimit(2)
                .contentShape(Rectangle())
                .onTapGesture { beginRename() }
                .help("Click to rename")
                .background(
                    // Return focuses the title for rename when nothing else
                    // claims the default action (read-only tabs). Hidden, zero-size.
                    Button("") { beginRename() }
                        .keyboardShortcut(.return, modifiers: [])
                        .opacity(0)
                        .frame(width: 0, height: 0)
                        .accessibilityHidden(true)
                )
        }
    }

    /// Workflow chip (left) + ghost shortcuts and the actions menu (right).
    /// Always present so the `...` menu is reachable even with no workflow/sink.
    var titleRow: some View {
        HStack(spacing: 8) {
            if let workflow = meeting.workflowName, !workflow.isEmpty {
                WorkflowChip(name: workflow, colorHex: meeting.workflowColor)
            }
            Spacer(minLength: 0)
            ghostShortcuts
            actionsMenu
        }
        .frame(minHeight: 18)
    }

    /// Detail-pane `...` actions menu (TECH-UI-5). Each item logs a
    /// `detail` / `toolbar_action` event for audit traceability.
    var actionsMenu: some View {
        Menu {
            Button("Rename") { beginRename() }
            Divider()
            Button("Edit summary") {
                toolbarAction("edit_summary") {
                    selectedTab = Tab.summary.rawValue
                    summaryEditToken += 1
                }
            }
            // Reprocess sits between Edit summary and Corrections (DSN22 #5) so the
            // re-run is findable, not buried under the publish verbs. It re-runs the
            // whole pipeline; Republish (below) only re-pushes the existing summary.
            Button("Reprocess\u{2026}") {
                toolbarAction("reprocess") { _ = libraryModel.retryMeeting(stem: meeting.stem) }
            }
            // PIPE6: re-summarize the existing transcript on a one-shot backend
            // without rewriting the workflow (that stays WF8's Reprocess). Regulated
            // / NDA still force local. Reuses regenerate (summarize + republish).
            reSummarizeMenu
            // ASR3: the transcript twin of Re-summarize. Re-runs ASR + diarization
            // over the audio so a glossary term or roster name learned since
            // reaches this meeting; the summary is left alone. The batch pane
            // carries the same action across a multi-selection.
            Button("Re-transcribe\u{2026}") {
                toolbarAction("retranscribe") { confirmRetranscribe() }
            }
            // WF8: re-route a misrouted meeting. Rewrites the meta sidecar's workflow
            // block (context prompt, sinks, DB, NDA posture), then offers Regenerate /
            // Republish. NDA transitions confirm explicitly in `beginReassign`.
            if libraryModel.workflowStore?.workflows.isEmpty == false {
                Menu("Change workflow\u{2026}") {
                    workflowChoices
                }
            }
            // No "Edit transcript" here: there is no transcript-wide edit mode.
            // Transcripts are corrected per line, via the hover pencil or the
            // right-click "Edit text..." in the Transcript tab (TECH-UX12).
            Button("Corrections\u{2026}") {
                toolbarAction("corrections") { showCorrectionsSheet = true }
            }
            Divider()
            // Republish re-pushes the existing summary to its sinks (DSN2).
            Button("Republish") {
                toolbarAction("republish") { Task { _ = await libraryModel.republishMeeting(stem: meeting.stem) } }
            }
            Divider()
            // FEAT16: the ad-hoc way out, for when the destination is a chat
            // compose box rather than a sink configured in advance. Two entries
            // rather than one control per tab, so either document is one click away
            // from whichever tab is up (including Audio) and neither reading column
            // gains chrome; the reasoning is in `copyRichText`.
            Button(MeetingShare.Surface.summary.menuLabel) {
                toolbarAction(MeetingShare.Surface.summary.rawValue) { copyRichText(.summary) }
            }
            Button(MeetingShare.Surface.transcript.menuLabel) {
                toolbarAction(MeetingShare.Surface.transcript.rawValue) { copyRichText(.transcript) }
            }
            Divider()
            Button("Open meta.json") {
                toolbarAction("open_meta") { openMetaJSON() }
            }
            Button("Copy meeting ID") {
                toolbarAction("copy_id") { copyMeetingID() }
            }
            Divider()
            Button("Delete\u{2026}", role: .destructive) {
                toolbarAction("delete") { confirmDelete() }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
        .accessibilityLabel("More actions")
    }

    /// Full date, duration (mono), and source app. Same hierarchy as the list row caption.
    var captionRow: some View {
        HStack(spacing: 6) {
            Text(MeetingFormatters.fullDateTime.string(from: meeting.startedAt))
                .font(.mpTextXS)
                .foregroundStyle(Color(MPColors.fgSubtle))
            if let d = meeting.durationSec {
                Text("·").font(.mpTextXS).foregroundStyle(Color(MPColors.fgSubtle))
                Text(MeetingRow.formatDuration(d))
                    .font(.mpTextXS.monospacedDigit())
                    .foregroundStyle(Color(MPColors.fgSubtle))
            }
            // Detected-language chip (TECH-UI-4): uppercase ISO code between duration and source, full name on hover. Hidden when unknown.
            if let langCode = languageChipCode {
                Text("·").font(.mpTextXS).foregroundStyle(Color(MPColors.fgSubtle))
                Text(langCode)
                    .font(.mpTextXS.monospaced())
                    .foregroundStyle(Color(MPColors.fgSubtle))
                    .help(languageChipTooltip ?? langCode)
            }
            if let src = meeting.sourceDisplayName, !src.isEmpty {
                Text("·").font(.mpTextXS).foregroundStyle(Color(MPColors.fgSubtle))
                Text(src)
                    .font(.mpTextXS)
                    .foregroundStyle(Color(MPColors.fgSubtle))
            }
        }
    }

    /// FEAT6: a quiet grey line naming the backend that produced the summary
    /// (Claude cloud / on-device MLX / Apple Intelligence). Hidden for legacy,
    /// paste, or skipped meetings with no recorded backend, so there is never an
    /// empty chip. Quiet about the AI: no sparkle, no teal, no coral; the model
    /// id lives only in the tooltip. Uses `fgSubtle` (not the mockup's fainter
    /// `fg-faint`) so the label clears the 4.5:1 text contrast floor.
    @ViewBuilder
    var provenanceRow: some View {
        if let label = provenanceLabel {
            HStack(spacing: 5) {
                Image(systemName: provenanceIcon)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(MPColors.fgSubtle))
                Text(label)
                    .font(.mpTextXS)
                    .foregroundStyle(Color(MPColors.fgSubtle))
            }
            .help(provenanceTooltip ?? label)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Summarized by \(label)")
        }
    }

    /// The engine that produced this summary, or nil for a backend this build
    /// does not know (a legacy / paste / skipped meeting with none recorded, or
    /// a run `mp summarize` could not attribute).
    var provenanceEngine: SummarizationEngine? {
        SummarizationEngine.resolve(meeting.backend)
    }

    /// Backend -> short, quiet label (UX31: the shared vocabulary, so this line
    /// and the `...` menu over it cannot name the same engine differently). Nil
    /// for an unknown backend so the row disappears entirely rather than showing
    /// an empty provenance line; a *known* backend always has a name now, which
    /// is what used to drop the row for an OpenAI meeting.
    var provenanceLabel: String? { provenanceEngine?.qualified }

    /// The model id rides only in the tooltip; the visible label stays readable.
    var provenanceTooltip: String? {
        guard let model = meeting.modelId, !model.isEmpty else { return nil }
        return model
    }

    /// Quiet monochrome glyph: a cloud for a hosted call, an on-device chip for
    /// the local backends. Keyed off the engine's locality rather than a single
    /// id, so the cloud providers added in UX31 get the cloud glyph instead of
    /// being drawn as if they ran on this Mac.
    private var provenanceIcon: String {
        provenanceEngine?.locality == .onDevice ? "cpu" : "cloud"
    }

    /// Uppercased 2-letter language code for the caption chip (TECH-UI-4); nil when unknown so the chip is hidden entirely.
    var languageChipCode: String? {
        guard let code = meeting.detectedLanguage, !code.isEmpty else { return nil }
        return String(code.prefix(2)).uppercased()
    }

    /// Full language name for the chip tooltip ("English", "Українська"). Uses the language's own locale for the endonym; nil when not resolvable.
    var languageChipTooltip: String? {
        guard let code = meeting.detectedLanguage, !code.isEmpty else { return nil }
        let base = String(code.prefix(2)).lowercased()
        guard let name = Locale(identifier: base).localizedString(forLanguageCode: base), !name.isEmpty else {
            return nil
        }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// Notion / Obsidian / local note / Reveal-in-Finder ghost icons. Reveal is rightmost since it's the most common action.
    ///
    /// The help strings come from `PublishSink`, not from literals here (UX49):
    /// this header and the done notification both name where a meeting landed,
    /// and while each spelled it itself the notification said Notion for every
    /// publish whatever ran. The icons come from there too since UX62, which is
    /// when a third button arrived and the inline-literal habit would have grown
    /// rather than stopped.
    ///
    /// The third button is the one that was missing for most meetings (UX62): a
    /// publish that landed only on the filesystem or the LAN share had no open
    /// action at all, which on the owner's filesystem-only default workflow was
    /// nearly every meeting rather than an edge.
    @ViewBuilder
    var ghostShortcuts: some View {
        HStack(spacing: 2) {
            if let url = cachedNotionURL {
                MPGhostIconButton(
                    systemImage: PublishSink.notion.symbolName,
                    help: PublishSink.notion.openPhrase
                ) { NSWorkspace.shared.open(url) }
            }
            if let url = cachedObsidianURL {
                MPGhostIconButton(
                    systemImage: PublishSink.obsidian.symbolName,
                    help: PublishSink.obsidian.openPhrase
                ) { NSWorkspace.shared.open(url) }
            }
            if let local = cachedLocalNote {
                MPGhostIconButton(
                    systemImage: local.sink.symbolName,
                    help: local.sink.openPhrase
                ) { NSWorkspace.shared.open(local.url) }
            }
            MPGhostIconButton(
                systemImage: "folder",
                help: "Show raw files in Finder"
            ) { NSWorkspace.shared.activateFileViewerSelecting([meeting.revealURL]) }
        }
    }


    // MARK: Title editing

    func syncEditingTitle(force: Bool) {
        if force || lastSyncedStem != meeting.stem {
            editingTitle = meeting.displayTitle
            lastSyncedStem = meeting.stem
        }
    }

    // MARK: Rename + toolbar actions (TECH-UI-5)

    func beginRename() {
        guard !isRenamingTitle else { return }
        editingTitle = meeting.displayTitle
        isRenamingTitle = true
        titleFieldFocused = true
    }

    func commitRename() {
        guard isRenamingTitle else { return }
        isRenamingTitle = false
        commitTitle()
    }

    func cancelRename() {
        editingTitle = meeting.displayTitle
        isRenamingTitle = false
    }

    /// Log a `detail` / `toolbar_action` event then run the action (TECH-UI-5).
    func toolbarAction(_ item: String, _ body: () -> Void) {
        Log.event(category: "detail", action: "toolbar_action", attributes: [
            "item": item,
            "stem": meeting.stem,
        ])
        body()
    }

    /// The engine picker, NDA-aware (UX29). Under an NDA workflow or global
    /// regulated mode the pipeline clamps to local whatever this passes, so
    /// offering the cloud item as if it would run in the cloud was a promise the
    /// product cannot keep: the owner clicked it twice on an NDA meeting, got
    /// local output both times, and filed a bug against a working guarantee.
    /// The clamp stays exactly as it is; only the menu learns to say so.
    @ViewBuilder
    var reSummarizeMenu: some View {
        Menu("Re-summarize with\u{2026}") {
            reSummarizeItems
        }
    }

    /// The rows themselves, so the `...` menu's submenu and UX41's inline cue in
    /// the header open one list rather than two copies that could drift on which
    /// engine is honest for this meeting. Same seam, and same reason, as
    /// `workflowChoices` one level down.
    @ViewBuilder
    var reSummarizeItems: some View {
        let state = reSummarizeState
        // UX31: the same two engines as before, named out of the shared
        // vocabulary so this menu and the provenance line under it agree.
        // Which engines a one-shot re-run may offer is UX29's question, not
        // a labelling one, so the pair is unchanged.
        Button(SummarizationEngine.local.qualified) {
            runReSummarize(backend: SummarizationEngine.local.id)
        }
        Button(SummarizationEngine.anthropic.qualified) {
            runReSummarize(backend: SummarizationEngine.anthropic.id)
        }
            .disabled(!state.cloudEnabled)
            .accessibilityLabel(state.accessibilityLabel(for: SummarizationEngine.anthropic.qualified))
        if let caption = state.caption {
            // A disabled row explains nothing on its own, so the reason sits
            // under it in the quiet register rather than in a dialog.
            Text(caption)
                .font(.mpTextXS)
                .foregroundStyle(Color(MPColors.fgSubtle))
        }
        if state.offersWorkflowChange {
            Divider()
            // The reassign flow is the designed escape hatch, and it already
            // confirms the NDA crossing explicitly, which is exactly the
            // path the owner ended up taking by hand.
            Menu("Change workflow\u{2026}") {
                workflowChoices
            }
        }
    }

    /// Whether the cloud engine can honestly be offered for this meeting (UX29).
    /// Reads the workflow flag off the same meta the row already loaded, plus the
    /// live global regulated flag; no new state.
    var reSummarizeState: ReSummarizeMenu {
        ReSummarizeMenu.resolve(
            workflowNDA: meeting.workflowNDAMode ?? false,
            regulatedMode: libraryModel.regulatedMode || (meeting.regulatedMode ?? false)
        )
    }

    /// The workflow list, shared by the top-level "Change workflow..." menu and
    /// UX29's deep link to it, so the two cannot drift on which workflows are
    /// offered or on the NDA confirmation each pick goes through.
    @ViewBuilder
    var workflowChoices: some View {
        if let workflows = libraryModel.workflowStore?.workflows {
            ForEach(workflows, id: \.id) { wf in
                Button(wf.name) { beginReassign(to: wf) }
                    .disabled(wf.name == meeting.workflowName)
            }
        }
    }

    /// PIPE6: re-summarize the existing transcript on a one-shot backend (summarize
    /// + republish via `regenerateMeeting`), from the "Re-summarize with..." menu.
    func runReSummarize(backend: String) {
        toolbarAction("re_summarize_\(backend)") {
            Task { _ = await libraryModel.regenerateMeeting(stem: meeting.stem, backend: backend) }
        }
    }

    /// WF8: reassign this meeting to `workflow`, rewriting the meta sidecar's workflow
    /// block. Entering or leaving NDA is the sharp edge and confirms explicitly. On
    /// success, offers Regenerate / Republish, never firing either on its own.
    func beginReassign(to workflow: Workflow) {
        let wasNDA = meeting.workflowNDAMode ?? false
        let willNDA = workflow.flags.ndaMode
        if wasNDA != willNDA, !confirmNDATransition(into: willNDA, workflowName: workflow.name) {
            return
        }
        toolbarAction("change_workflow") {
            switch libraryModel.reassignWorkflow(stem: meeting.stem, to: workflow) {
            case .success:
                offerReassignFollowups(to: workflow)
            case .failure(let error):
                presentReassignError(error)
            }
        }
    }

    /// Confirm an NDA boundary crossing. Into NDA re-clamps from now on but cannot
    /// un-egress past publishes; out of NDA is a deliberate downgrade. Returns whether
    /// the user confirmed.
    private func confirmNDATransition(into willNDA: Bool, workflowName: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        if willNDA {
            alert.messageText = "Move this meeting into the NDA workflow \(workflowName)?"
            alert.informativeText = "From now on it summarizes on-device and publishes to the filesystem only. This cannot un-publish anything already sent to Notion or another sink."
            alert.addButton(withTitle: "Move into NDA")
        } else {
            alert.messageText = "Move this meeting out of NDA into \(workflowName)?"
            alert.informativeText = "This is a deliberate downgrade: a later Regenerate or Republish may send this meeting's summary to the cloud and to the new workflow's sinks."
            alert.addButton(withTitle: "Move out of NDA")
        }
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Offer the two follow-ups with plain-English consequences. Regenerate re-summarizes
    /// with the new context prompt then republishes; Republish re-sends the existing
    /// summary to the new sinks / DB. Neither runs unless chosen.
    private func offerReassignFollowups(to workflow: Workflow) {
        let alert = NSAlert()
        alert.messageText = "Moved to \(workflow.name)."
        alert.informativeText = "Regenerate re-summarizes with the new workflow's context prompt, then publishes to its sinks. Republish keeps the summary and only re-sends it to the new workflow's sinks and database. Neither runs until you pick it."
        alert.addButton(withTitle: "Regenerate")
        alert.addButton(withTitle: "Republish")
        alert.addButton(withTitle: "Not now")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task { _ = await libraryModel.regenerateMeeting(stem: meeting.stem) }
        case .alertSecondButtonReturn:
            Task { _ = await libraryModel.republishMeeting(stem: meeting.stem) }
        default:
            break
        }
    }

    private func presentReassignError(_ error: Error) {
        FailureDialog.show(FailurePresentation(error: error, title: "Couldn't change the workflow"))
    }

    func openMetaJSON() {
        let metaURL = meeting.recordingsDir.appendingPathComponent("\(meeting.stem).meta.json")
        if FileManager.default.fileExists(atPath: metaURL.path) {
            NSWorkspace.shared.open(metaURL)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([meeting.revealURL])
        }
    }

    func copyMeetingID() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(meeting.stem, forType: .string)
    }

    /// FEAT16: put this meeting's summary or transcript on the clipboard in every
    /// flavor a paste can ask for, so it arrives formatted in a Teams chat and
    /// still arrives plain under Cmd+Shift+V.
    ///
    /// **Why the header rather than a control on each tab.** Both were on offer.
    /// This wins on three counts: either document is reachable from whichever tab
    /// is up, including Audio, where a per-tab control would make copying the
    /// transcript a tab switch first; `toolbarAction` is already the routing here,
    /// so the `detail` / `toolbar_action` event comes out the same shape as the ten
    /// actions beside it; and the two reading columns gain no chrome, which UX36
    /// spent a pass making quiet and DSN3 would have to re-check. The cost is that
    /// the content is re-read off disk instead of taken from the tab's own state,
    /// and that cost is small: it is a second *call* of the tabs' own resolutions
    /// (`MeetingShare.document`), never a second implementation of them, and every
    /// overlay it resolves lives in a sidecar rather than in view state.
    ///
    /// The load is detached because an 80-minute transcript is a real parse; the
    /// write is back on main because `RichTextShare.rtf` is main-thread-only.
    func copyRichText(_ surface: MeetingShare.Surface) {
        let stem = meeting.stem
        let directory = meeting.recordingsDir
        let title = meeting.displayTitle
        Task {
            let document = await Task.detached(priority: .userInitiated) {
                MeetingShare.document(surface, stem: stem, title: title, in: directory)
            }.value
            await MainActor.run {
                guard let document else {
                    reportNothingToCopy(surface)
                    return
                }
                RichTextShare.write(document, to: .general)
            }
        }
    }

    /// Say so rather than leaving whatever was on the clipboard before. Silence
    /// here is the worst outcome: the next paste would land the owner's previous
    /// copy and read as this meeting's.
    private func reportNothingToCopy(_ surface: MeetingShare.Surface) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "There is no \(surface.noun) to copy yet."
        alert.informativeText = "Nothing was put on the clipboard. A \(surface.noun) appears once the pipeline finishes this meeting."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// ASR3: confirm, run, then report what happened to the speaker names and
    /// text edits. A modal result rather than a toast because the interesting
    /// case is a drop: an override the carry could not re-anchor is work the
    /// owner did by hand that the new transcript has no home for.
    func confirmRetranscribe() {
        let alert = NSAlert()
        alert.messageText = "Re-transcribe \(meeting.displayTitle)?"
        alert.informativeText = "The recording is transcribed again from its audio, picking up glossary terms and roster names learned since. Your speaker names and text edits are re-anchored onto the new transcript; anything that no longer lines up is dropped. The summary is left alone; re-summarize afterwards if you want it to reflect the new transcript."
        alert.addButton(withTitle: "Re-transcribe")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            let result = await libraryModel.retranscribeMeeting(stem: meeting.stem)
            await MainActor.run { reportRetranscribe(result) }
        }
    }

    private func reportRetranscribe(
        _ result: Result<MeetingLibraryService.RetranscribeOutcome, Error>
    ) {
        // The copy lives in `LibraryDialogs` since FEAT13 gave this report a second
        // caller (the Clarify sheet's rule path, which can rebuild the meeting so a term
        // just added reaches it).
        LibraryDialogs.reportRetranscribe(meetingTitle: meeting.displayTitle, result: result)
    }

    func confirmDelete() {
        if LibraryDialogs.confirmSoftDelete(meetingTitle: meeting.displayTitle) {
            _ = libraryModel.softDeleteMeeting(stem: meeting.stem)
        }
    }

    func commitTitle() {
        let trimmed = editingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // Restore the computed display title so the field never goes empty.
            editingTitle = meeting.displayTitle
            return
        }
        if trimmed == meeting.summaryTitle || trimmed == meeting.meetingTitle {
            return
        }
        writeTitle(trimmed)
    }

    /// Writes to `summary.json["title"]` when it exists, else `meta.json["meeting_title"]`. The directory watcher picks up the change on the next debounce tick.
    func writeTitle(_ newTitle: String) {
        let summaryURL = meeting.recordingsDir.appendingPathComponent("\(meeting.stem).summary.json")
        let metaURL = meeting.recordingsDir.appendingPathComponent("\(meeting.stem).meta.json")

        let target: URL
        let key: String
        if FileManager.default.fileExists(atPath: summaryURL.path) {
            target = summaryURL
            key = "title"
        } else {
            target = metaURL
            key = "meeting_title"
        }

        var existing: [String: Any] = [:]
        if let data = try? Data(contentsOf: target),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            existing = obj
        }
        existing[key] = newTitle
        guard JSONSerialization.isValidJSONObject(existing),
              let data = try? JSONSerialization.data(
                  withJSONObject: existing,
                  options: [.prettyPrinted, .sortedKeys]
              ) else {
            return
        }
        try? data.write(to: target, options: .atomic)
        Log.event(category: "library", action: "title_edited", attributes: [
            "stem": meeting.stem,
            "target": target.lastPathComponent,
        ])
    }

}
