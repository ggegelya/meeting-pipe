import AppKit
import SwiftUI

/// Right-pane detail view: editable header + five tabs (Summary TECH-A5, Transcript A6, Audio A7, Corrections A8, Raw files A9).
struct MeetingDetailView: View {
    @EnvironmentObject var libraryModel: LibraryWindowModel
    let meeting: Meeting

    /// Loaded off-main via `.task(id:)`. Caching avoids `Data(contentsOf:)` on the main thread on every observable change, which beach-balled the UI during recording.
    @State private var cachedNotionURL: URL? = nil
    @State private var cachedObsidianURL: URL? = nil
    @State private var publishURLsLoadedForStem: String? = nil

    /// Persisted so reopening the window keeps the user's tab. A stem-keyed default would be over-engineered for a personal product.
    @AppStorage("MeetingDetailSelectedTab") private var selectedTab: String = Tab.summary.rawValue

    @State private var editingTitle: String = ""
    @State private var lastSyncedStem: String = ""

    /// Shared across Transcript (A6) and Audio (A7) so click-to-seek keeps the same play head when flipping tabs. Re-attached on stem change via `.task(id:)`.
    @StateObject private var playback = AudioPlaybackController()

    enum Tab: String, CaseIterable {
        case summary
        case transcript
        case audio
        case corrections
        case raw

        var label: String {
            switch self {
            case .summary:     return "Summary"
            case .transcript:  return "Transcript"
            case .audio:       return "Audio"
            case .corrections: return "Corrections"
            case .raw:         return "Raw files"
            }
        }

        var systemImage: String {
            switch self {
            case .summary:     return "text.alignleft"
            case .transcript:  return "text.bubble"
            case .audio:       return "waveform"
            case .corrections: return "pencil"
            case .raw:         return "folder"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)
            tabStrip
            Divider().overlay(Color(MPColors.borderFaint))
            tabContent
        }
        .frame(minWidth: 360)
        .onAppear { syncEditingTitle(force: true) }
        .onChange(of: meeting.stem) { _, _ in syncEditingTitle(force: true) }
        .onChange(of: meeting.displayTitle) { _, _ in syncEditingTitle(force: false) }
        .task(id: meeting.stem) { await reloadPublishURLs() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            titleRow
            TextField("Untitled meeting", text: $editingTitle, onCommit: commitTitle)
                .textFieldStyle(.plain)
                .font(.system(size: 19, weight: .semibold))
                .lineLimit(2)
            captionRow
        }
    }

    /// Workflow chip + ghost shortcuts above the title. Collapses to zero height when neither is present so the title rises to the top.
    @ViewBuilder
    private var titleRow: some View {
        let hasTopline = (meeting.workflowName?.isEmpty == false)
            || cachedNotionURL != nil
            || cachedObsidianURL != nil
        if hasTopline {
            HStack(spacing: 8) {
                if let workflow = meeting.workflowName, !workflow.isEmpty {
                    WorkflowChip(name: workflow, colorHex: meeting.workflowColor)
                }
                Spacer(minLength: 0)
                ghostShortcuts
            }
            .frame(minHeight: 18)
        }
    }

    /// Full date, duration (mono), and source app. Same hierarchy as the list row caption.
    private var captionRow: some View {
        HStack(spacing: 6) {
            Text(MeetingFormatters.fullDateTime.string(from: meeting.startedAt))
                .font(.system(size: 11))
                .foregroundStyle(Color(MPColors.fgSubtle))
            if let d = meeting.durationSec {
                Text("·").font(.system(size: 11)).foregroundStyle(Color(MPColors.fgFaint))
                Text(MeetingRow.formatDuration(d))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Color(MPColors.fgSubtle))
            }
            // Detected-language chip (TECH-UI-4): uppercase ISO code between duration and source, full name on hover. Hidden when unknown.
            if let langCode = languageChipCode {
                Text("·").font(.system(size: 11)).foregroundStyle(Color(MPColors.fgFaint))
                Text(langCode)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color(MPColors.fgSubtle))
                    .help(languageChipTooltip ?? langCode)
            }
            if let src = meeting.sourceDisplayName, !src.isEmpty {
                Text("·").font(.system(size: 11)).foregroundStyle(Color(MPColors.fgFaint))
                Text(src)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(MPColors.fgSubtle))
            }
        }
    }

    /// Uppercased 2-letter language code for the caption chip (TECH-UI-4); nil when unknown so the chip is hidden entirely.
    private var languageChipCode: String? {
        guard let code = meeting.detectedLanguage, !code.isEmpty else { return nil }
        return String(code.prefix(2)).uppercased()
    }

    /// Full language name for the chip tooltip ("English", "Українська"). Uses the language's own locale for the endonym; nil when not resolvable.
    private var languageChipTooltip: String? {
        guard let code = meeting.detectedLanguage, !code.isEmpty else { return nil }
        let base = String(code.prefix(2)).lowercased()
        guard let name = Locale(identifier: base).localizedString(forLanguageCode: base), !name.isEmpty else {
            return nil
        }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// Notion / Obsidian / Reveal-in-Finder ghost icons. Reveal is rightmost since it's the most common action.
    @ViewBuilder
    private var ghostShortcuts: some View {
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
                help: "Reveal raw audio in Finder"
            ) { NSWorkspace.shared.activateFileViewerSelecting([meeting.wavURL]) }
        }
    }

    // MARK: Tab strip

    private var tabStrip: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.rawValue) { tab in
                tabButton(tab)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
    }

    private func tabButton(_ tab: Tab) -> some View {
        let isActive = selectedTab == tab.rawValue
        return Button {
            selectedTab = tab.rawValue
        } label: {
            VStack(spacing: 0) {
                Text(tab.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isActive ? Color(MPColors.fg) : Color(MPColors.fgMuted))
                    .padding(.vertical, 9)
                Rectangle()
                    .fill(isActive ? Color(MPColors.signal600) : Color.clear)
                    .frame(height: 1.5)
                    .cornerRadius(0.75)
            }
            .padding(.horizontal, 0)
            .padding(.trailing, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case Tab.summary.rawValue:     summaryTab
        case Tab.transcript.rawValue:  transcriptTab
        case Tab.audio.rawValue:       audioTab
        case Tab.corrections.rawValue: correctionsTab
        case Tab.raw.rawValue:         rawTab
        default:                       summaryTab
        }
    }

    // MARK: Tabs

    private var summaryTab: some View {
        SummaryTab(meeting: meeting)
            .environmentObject(libraryModel)
    }

    private var transcriptTab: some View {
        TranscriptTab(playback: playback, meeting: meeting)
    }

    private var audioTab: some View {
        AudioTab(playback: playback, meeting: meeting)
    }

    private var correctionsTab: some View {
        CorrectionsTab(meeting: meeting, selectedTab: $selectedTab)
    }

    private var rawTab: some View {
        RawFilesTab(meeting: meeting)
    }

    // MARK: Title editing

    private func syncEditingTitle(force: Bool) {
        if force || lastSyncedStem != meeting.stem {
            editingTitle = meeting.displayTitle
            lastSyncedStem = meeting.stem
        }
    }

    private func commitTitle() {
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
    private func writeTitle(_ newTitle: String) {
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

    // MARK: Publish-target URLs

    @MainActor
    private func reloadPublishURLs() async {
        let stem = meeting.stem
        let notionPath = meeting.recordingsDir.appendingPathComponent("\(stem).notion.json")
        let obsidianPath = meeting.recordingsDir.appendingPathComponent("\(stem).obsidian.json")

        let (notion, obsidian) = await Task.detached(priority: .userInitiated) {
            (PublishURLs.notion(at: notionPath), PublishURLs.obsidian(at: obsidianPath))
        }.value

        if meeting.stem == stem {
            cachedNotionURL = notion
            cachedObsidianURL = obsidian
            publishURLsLoadedForStem = stem
        }
    }
}

/// Publish-target sidecar parsers. Kept outside the View so they aren't inferred as main-actor-isolated; the loader calls them from a detached Task.
enum PublishURLs {
    static func notion(at path: URL) -> URL? {
        guard let data = try? Data(contentsOf: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let s = obj["page_url"] as? String else {
            return nil
        }
        return URL(string: s)
    }

    /// Builds `obsidian://open?vault=...&file=...` from `<stem>.obsidian.json`. Returns nil when the sidecar is missing or the vault relationship can't be resolved.
    static func obsidian(at path: URL) -> URL? {
        guard let data = try? Data(contentsOf: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let notePath = obj["note_path"] as? String,
              let vault = obj["vault"] as? String else {
            return nil
        }
        let vaultURL = URL(fileURLWithPath: vault)
        let noteURL = URL(fileURLWithPath: notePath)
        guard let rel = relativePath(of: noteURL, from: vaultURL) else { return nil }
        let vaultName = vaultURL.lastPathComponent
        var comps = URLComponents()
        comps.scheme = "obsidian"
        comps.host = "open"
        comps.queryItems = [
            URLQueryItem(name: "vault", value: vaultName),
            URLQueryItem(name: "file", value: rel),
        ]
        return comps.url
    }

    static func relativePath(of file: URL, from base: URL) -> String? {
        let fileComps = file.standardizedFileURL.pathComponents
        let baseComps = base.standardizedFileURL.pathComponents
        guard fileComps.count > baseComps.count else { return nil }
        guard Array(fileComps.prefix(baseComps.count)) == baseComps else { return nil }
        return fileComps.suffix(from: baseComps.count).joined(separator: "/")
    }
}

// MARK: - Summary tab (TECH-A5)

/// Summary tab (TECH-A5). Read-only by default; the Edit button swaps in `CorrectionEditorBody`. Save persists a correction record and overwrites `<stem>.summary.json`; "Save & Republish" additionally spawns `mp publish-notion`.
struct SummaryTab: View {
    @EnvironmentObject var libraryModel: LibraryWindowModel
    let meeting: Meeting

    /// Loaded off-main on stem change. Caching avoids disk IO on the main thread, which pinned it during recording.
    @State private var loadedSummary: MeetingSummary? = nil
    @State private var loadedForStem: String? = nil

    @State private var isEditing = false
    @State private var editorModel: CorrectionViewModel? = nil
    @State private var republishing = false
    @State private var lastRepublishResult: RepublishResult? = nil

    enum RepublishResult: Equatable {
        case success(URL?)
        case failure(String)
    }

    var body: some View {
        Group {
            if isEditing, let model = editorModel {
                editorBody(model: model)
            } else {
                readOnlyBody
            }
        }
        .task(id: meeting.stem) {
            await reloadSummary()
        }
        .onChange(of: meeting.stem) { _, _ in
            // Discard in-flight edits on stem change; applying old edits to the new row would be a footgun.
            isEditing = false
            editorModel = nil
            lastRepublishResult = nil
        }
    }

    // MARK: Read-only render

    private var readOnlyBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                if let summary = loadedSummary {
                    SummaryRenderedView(summary: summary)
                } else if loadedForStem == meeting.stem {
                    emptyState
                } else {
                    // Load still in flight.
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(40)
                }
            }
            Divider()
            HStack {
                if let result = lastRepublishResult {
                    statusBadge(for: result)
                }
                Spacer()
                Button("Edit") {
                    beginEditing()
                }
                .disabled(!hasSummaryOnDisk)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
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
        } else {
            Text("No summary yet.\nIt appears here once the pipeline finishes.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(40)
        }
    }

    private var failedState: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.orange)
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

    @ViewBuilder
    private func statusBadge(for result: RepublishResult) -> some View {
        switch result {
        case .success(let url):
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if let url = url {
                    Button("Republished — view in Notion") {
                        NSWorkspace.shared.open(url)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                } else {
                    Text("Republished")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .failure(let err):
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Republish failed: \(err)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var hasSummaryOnDisk: Bool {
        FileManager.default.fileExists(atPath: summaryJsonURL.path)
    }

    private var summaryJsonURL: URL {
        meeting.recordingsDir.appendingPathComponent("\(meeting.stem).summary.json")
    }

    private var summaryMarkdownURL: URL {
        meeting.recordingsDir.appendingPathComponent("\(meeting.stem).summary.md")
    }

    /// Loads `<stem>.summary.json` off-main. Called via `.task(id:)`; guards against stale stems.
    @MainActor
    private func reloadSummary() async {
        let stem = meeting.stem
        let url = summaryJsonURL
        let parsed: MeetingSummary? = await Task.detached(priority: .userInitiated) {
            MeetingSummary.load(from: url)
        }.value
        if meeting.stem == stem {
            loadedSummary = parsed
            loadedForStem = stem
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
        .disabled(republishing)
        .overlay(alignment: .top) {
            if republishing {
                ProgressView("Republishing…")
                    .progressViewStyle(.linear)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(NSColor.controlBackgroundColor))
                    )
                    .padding(8)
            }
        }
    }

    private func footer(model: CorrectionViewModel) -> some View {
        HStack(spacing: 8) {
            Button("Cancel") {
                isEditing = false
                editorModel = nil
            }
            Spacer()
            Button("Save") {
                _ = persistEdit(model: model)
                isEditing = false
            }
            Button("Save & Republish") {
                Task {
                    if persistEdit(model: model) {
                        await runRepublish(stem: model.stem)
                        isEditing = false
                    }
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(libraryModel.coordinator == nil)
        }
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

    private func runRepublish(stem: String) async {
        republishing = true
        let result = await libraryModel.republishMeeting(stem: stem)
        republishing = false
        switch result {
        case .success(let url):
            lastRepublishResult = .success(url)
        case .failure(let err):
            lastRepublishResult = .failure(err.localizedDescription)
        }
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

/// Renders a typed `MeetingSummary` as SwiftUI sections. Inline emphasis/code/links inside bullets use per-bullet `AttributedString` parsing.
struct SummaryRenderedView: View {
    let summary: MeetingSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if !summaryBullets.isEmpty {
                section(title: "Summary", systemImage: "doc.text") {
                    bulletList(summaryBullets, numbered: false)
                }
            }
            if !decisions.isEmpty {
                section(title: "Decisions", systemImage: "checkmark.seal") {
                    bulletList(decisions, numbered: true)
                }
            }
            if !actions.isEmpty {
                section(title: "Action items", systemImage: "checklist") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(actions.enumerated()), id: \.offset) { _, a in
                            ActionItemRow(action: a)
                        }
                    }
                }
            }
            if !questions.isEmpty {
                section(title: "Open questions", systemImage: "questionmark.bubble") {
                    bulletList(questions, numbered: false)
                }
            }
            if !attendees.isEmpty {
                section(title: "Attendees", systemImage: "person.2") {
                    AttendeeChips(names: attendees)
                }
            }
            // TECH-UI-4: the detected-language indicator moved to the detail header caption row.
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    // MARK: Field accessors

    private var summaryBullets: [String] { nonEmpty(summary.summary) }
    private var decisions: [String]      { nonEmpty(summary.decisions) }
    private var questions: [String]      { nonEmpty(summary.questions) }
    private var attendees: [String]      { nonEmpty(summary.attendees) }
    private var actions: [ActionItemRow.Action] {
        summary.actions.map { a in
            ActionItemRow.Action(
                task: a.task,
                owner: a.owner ?? "",
                due: a.due ?? "",
                confidence: a.confidence
            )
        }.filter { !$0.task.isEmpty }
    }

    private func nonEmpty(_ items: [String]) -> [String] {
        items.filter { !$0.isEmpty }
    }

    // MARK: Section + bullet helpers

    @ViewBuilder
    private func section<C: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> C
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func bulletList(_ items: [String], numbered: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(numbered ? "\(idx + 1)." : "•")
                        .foregroundStyle(.tertiary)
                        .font(.callout.monospacedDigit())
                        .frame(minWidth: 16, alignment: .trailing)
                    Text(inlineMarkdown(item))
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Parse inline markdown per bullet (bold, italic, code, links only - each bullet is already one paragraph).
    private func inlineMarkdown(_ s: String) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnly,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: s, options: opts)) ?? AttributedString(s)
    }
}

private struct ActionItemRow: View {
    struct Action {
        var task: String
        var owner: String
        var due: String
        var confidence: String
    }

    let action: Action

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "circle")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
                Text(taskAttributed)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !chipRow.isEmpty {
                HStack(spacing: 6) {
                    Spacer().frame(width: 16)
                    ForEach(chipRow, id: \.text) { chip in
                        Self.chip(chip)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var taskAttributed: AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnly,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: action.task, options: opts))
            ?? AttributedString(action.task)
    }

    struct Chip: Hashable {
        let text: String
        let systemImage: String?
        let tint: Color
    }

    private var chipRow: [Chip] {
        var chips: [Chip] = []
        if !action.owner.isEmpty {
            chips.append(Chip(text: action.owner, systemImage: "person", tint: .accentColor))
        }
        if !action.due.isEmpty {
            chips.append(Chip(text: action.due, systemImage: "calendar", tint: .orange))
        }
        if !action.confidence.isEmpty, action.confidence != "medium" {
            chips.append(Chip(
                text: action.confidence,
                systemImage: "gauge",
                tint: action.confidence == "high" ? .green : .secondary
            ))
        }
        return chips
    }

    @ViewBuilder
    static func chip(_ chip: Chip) -> some View {
        HStack(spacing: 3) {
            if let img = chip.systemImage {
                Image(systemName: img).font(.caption2)
            }
            Text(chip.text).font(.caption2)
        }
        .foregroundStyle(chip.tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(chip.tint.opacity(0.12))
        )
    }
}

private struct AttendeeChips: View {
    let names: [String]

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 6)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(names, id: \.self) { name in
                HStack(spacing: 4) {
                    Image(systemName: "person.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(NSColor.controlBackgroundColor).opacity(0.6))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.15))
                )
            }
        }
    }
}
