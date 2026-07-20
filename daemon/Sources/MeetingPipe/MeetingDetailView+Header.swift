import AppKit
import SwiftUI

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
            publishStateLine
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
    /// record. Quiet and faint, the same register as the provenance line above it.
    var editedCaption: some View {
        HStack(spacing: 5) {
            Image(systemName: "pencil")
                .font(.mpTextXS)
                .foregroundStyle(Color(MPColors.fgFaint))
            Text("Summary edited locally")
                .font(.mpTextXS)
                .foregroundStyle(Color(MPColors.fgFaint))
        }
        .accessibilityElement(children: .combine)
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
            let reason = meeting.failureReason
            let because = (reason?.isEmpty == false) ? ": \(reason!)" : ""
            return ("exclamationmark.triangle.fill", Color(MPColors.danger600),
                    "Processing failed\(because).")
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
                return ("exclamationmark.triangle", Color(MPColors.warning600),
                        "Published to some targets; at least one sink failed.")
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
            Menu("Re-summarize with\u{2026}") {
                Button("Local (on-device)") { runReSummarize(backend: "local") }
                Button("Anthropic (cloud)") { runReSummarize(backend: "anthropic") }
            }
            // WF8: re-route a misrouted meeting. Rewrites the meta sidecar's workflow
            // block (context prompt, sinks, DB, NDA posture), then offers Regenerate /
            // Republish. NDA transitions confirm explicitly in `beginReassign`.
            if let workflows = libraryModel.workflowStore?.workflows, !workflows.isEmpty {
                Menu("Change workflow\u{2026}") {
                    ForEach(workflows, id: \.id) { wf in
                        Button(wf.name) { beginReassign(to: wf) }
                            .disabled(wf.name == meeting.workflowName)
                    }
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

    /// Backend -> short, quiet label. Nil for an unknown backend so the row
    /// disappears entirely rather than showing an empty provenance line.
    var provenanceLabel: String? {
        switch meeting.backend {
        case "anthropic":          return "Claude (cloud)"
        case "local":              return "On-device (MLX)"
        case "apple_intelligence": return "Apple Intelligence"
        default:                   return nil
        }
    }

    /// The model id rides only in the tooltip; the visible label stays readable.
    var provenanceTooltip: String? {
        guard let model = meeting.modelId, !model.isEmpty else { return nil }
        return model
    }

    /// Quiet monochrome glyph: a cloud for the hosted call, an on-device chip for
    /// the two local backends.
    private var provenanceIcon: String {
        meeting.backend == "anthropic" ? "cloud" : "cpu"
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

    /// Notion / Obsidian / Reveal-in-Finder ghost icons. Reveal is rightmost since it's the most common action.
    @ViewBuilder
    var ghostShortcuts: some View {
        HStack(spacing: 2) {
            if let url = cachedNotionURL {
                MPGhostIconButton(
                    systemImage: "arrow.up.right.square",
                    help: "Open in Notion"
                ) { NSWorkspace.shared.open(url) }
            }
            if let url = cachedObsidianURL {
                MPGhostIconButton(
                    systemImage: "book.closed",
                    help: "Open in Obsidian"
                ) { NSWorkspace.shared.open(url) }
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
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't change the workflow."
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
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

    func confirmDelete() {
        let alert = NSAlert()
        alert.messageText = "Move \(meeting.displayTitle) to Trash?"
        alert.informativeText = "Every file for this meeting (audio, transcript, summary, sidecars) goes to the Trash. You can restore from there until the Trash is emptied."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
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
