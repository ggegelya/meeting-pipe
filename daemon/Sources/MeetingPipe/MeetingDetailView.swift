import AppKit
import SwiftUI

/// Right-pane detail view: header (editable title, date, workflow chip,
/// publish-target shortcuts) plus five tabs.
///
///   - Summary: renders `<stem>.summary.md` as Markdown read-only, with
///     an "Edit" toggle that swaps in the shared `CorrectionEditorBody`
///     (TECH-A5). Save writes a correction record AND overwrites the
///     summary on disk; "Save & Republish" additionally re-runs
///     `mp publish-notion` so the published page reflects the edit.
///   - Transcript: A6 wires speaker-labeled markdown + audio sync.
///   - Audio: A7 renders the stereo waveform.
///   - Corrections: A8 renders the correction record.
///   - Raw files: A9 lists every `<stem>.*` file in the recordings dir.
struct MeetingDetailView: View {
    @EnvironmentObject var libraryModel: LibraryWindowModel
    let meeting: Meeting

    /// Cached so the body never reads from disk synchronously. Reloaded
    /// off-main on stem change via `.task(id:)`. Without this the body
    /// hit `Data(contentsOf:)` on every observable change in the
    /// library model (status, processingCount, model-download progress,
    /// liveRecordingStem) and beach-balled the UI during recording.
    @State private var cachedNotionURL: URL? = nil
    @State private var cachedObsidianURL: URL? = nil
    @State private var publishURLsLoadedForStem: String? = nil

    /// Persisted across launches so reopening the window keeps the user
    /// on their preferred tab. Hidden behind a stem-keyed default would
    /// be over-engineered for a personal product.
    @AppStorage("MeetingDetailSelectedTab") private var selectedTab: String = Tab.summary.rawValue

    @State private var editingTitle: String = ""
    @State private var lastSyncedStem: String = ""

    /// Shared between the Transcript (TECH-A6) and Audio (TECH-A7) tabs
    /// so click-to-seek from a line keeps the same play head when the
    /// user flips to the waveform. Re-attached to the new wav on stem
    /// change via the transcript tab's `.task(id:)`.
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
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            Divider()
            TabView(selection: $selectedTab) {
                summaryTab
                    .tabItem { Label(Tab.summary.label, systemImage: Tab.summary.systemImage) }
                    .tag(Tab.summary.rawValue)
                transcriptTab
                    .tabItem { Label(Tab.transcript.label, systemImage: Tab.transcript.systemImage) }
                    .tag(Tab.transcript.rawValue)
                audioTab
                    .tabItem { Label(Tab.audio.label, systemImage: Tab.audio.systemImage) }
                    .tag(Tab.audio.rawValue)
                correctionsTab
                    .tabItem { Label(Tab.corrections.label, systemImage: Tab.corrections.systemImage) }
                    .tag(Tab.corrections.rawValue)
                rawTab
                    .tabItem { Label(Tab.raw.label, systemImage: Tab.raw.systemImage) }
                    .tag(Tab.raw.rawValue)
            }
            .padding(12)
        }
        .frame(minWidth: 360)
        .onAppear { syncEditingTitle(force: true) }
        .onChange(of: meeting.stem) { _, _ in syncEditingTitle(force: true) }
        .onChange(of: meeting.displayTitle) { _, _ in syncEditingTitle(force: false) }
        .task(id: meeting.stem) { await reloadPublishURLs() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Untitled meeting", text: $editingTitle, onCommit: commitTitle)
                .textFieldStyle(.plain)
                .font(.title2.weight(.semibold))
            HStack(alignment: .center, spacing: 12) {
                Text(MeetingFormatters.fullDateTime.string(from: meeting.startedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let workflow = meeting.workflowName {
                    WorkflowChip(name: workflow, colorHex: meeting.workflowColor)
                }
                if let d = meeting.durationSec {
                    Text("·").foregroundStyle(.tertiary)
                    Label(MeetingRow.formatDuration(d), systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                }
                Spacer()
                openInButtons
            }
        }
    }

    @ViewBuilder
    private var openInButtons: some View {
        HStack(spacing: 6) {
            if let url = cachedNotionURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Open in Notion", systemImage: "arrow.up.right.square")
                }
                .controlSize(.small)
            }
            if let url = cachedObsidianURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Open in Obsidian", systemImage: "arrow.up.right.square")
                }
                .controlSize(.small)
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([meeting.wavURL])
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            .controlSize(.small)
        }
    }

    // MARK: Tabs (placeholders — replaced by A5 / A6 / A7 / A8 / A9)

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
        TabPlaceholder(
            icon: Tab.raw.systemImage,
            title: "Raw files",
            blurb: "Every sidecar in the recordings dir, with Reveal in Finder. Lands with TECH-A9."
        )
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
            // Don't let the user blank out the title — restore the
            // computed display title so the field never goes empty.
            editingTitle = meeting.displayTitle
            return
        }
        if trimmed == meeting.summaryTitle || trimmed == meeting.meetingTitle {
            return
        }
        writeTitle(trimmed)
    }

    /// Persist the new title to the strongest sidecar that exists:
    /// summary.json's "title" (when there's an LLM summary on disk),
    /// otherwise meta.json's "meeting_title" (the source-app-derived
    /// fallback). The MeetingStore's directory watcher picks up the
    /// change on the next debounce tick.
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

/// File-parsing helpers for the publish-target sidecars. Pulled out of
/// `MeetingDetailView` so they aren't inferred as main-actor-isolated
/// via View conformance; the loader calls them from a detached Task.
enum PublishURLs {
    static func notion(at path: URL) -> URL? {
        guard let data = try? Data(contentsOf: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let s = obj["page_url"] as? String else {
            return nil
        }
        return URL(string: s)
    }

    /// `obsidian://open?vault=<name>&file=<rel>` lets Obsidian pick up
    /// the note via its registered URL scheme. We derive `rel` by
    /// trimming the vault prefix off the absolute note path the pipeline
    /// wrote into `<stem>.obsidian.json`. Returns nil when the sidecar
    /// doesn't exist or the vault relationship can't be resolved.
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

// MARK: - Placeholders

private struct TabPlaceholder: View {
    let icon: String
    let title: String
    let blurb: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text(title).font(.headline).foregroundStyle(.secondary)
            Text(blurb)
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

// MARK: - Summary tab (TECH-A5)

/// Summary tab. Read-only by default — renders the structured
/// `<stem>.summary.json` as proper SwiftUI sections (Summary,
/// Decisions, Actions, Open Questions, Attendees). Inline markdown
/// inside individual bullets is preserved via `AttributedString`. The
/// "Edit" button swaps in the shared `CorrectionEditorBody` so the
/// inline editor shares its field surface with the standalone
/// correction window.
///
/// Save persists a correction record (verdict = edited) AND overwrites
/// `<stem>.summary.json` so the next read of the row sees the new
/// content. "Save & Republish" additionally spawns `mp publish-notion`
/// so the published Notion page reflects the edit; the editor stays
/// disabled while the subprocess is running.
struct SummaryTab: View {
    @EnvironmentObject var libraryModel: LibraryWindowModel
    let meeting: Meeting

    /// Cached summary payload — loaded asynchronously on stem change so
    /// the view body never reads from disk synchronously. SwiftUI calls
    /// body any time an observed object changes; doing IO there pinned
    /// the main thread during recording.
    @State private var loadedSummary: [String: Any]? = nil
    @State private var loadedForStem: String? = nil

    /// Toggle between rendered summary and the editor form.
    @State private var isEditing = false
    /// Holds the in-flight editor model so isEditing changes can
    /// dispose / recreate it cleanly.
    @State private var editorModel: CorrectionViewModel? = nil
    /// Republish state for the footer button + status label.
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
            // Switching meetings discards in-flight edits — saving with
            // unsubmitted changes would be a footgun (the user expects
            // a fresh row, not their old edits applied to it).
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
                    // We loaded for this stem and got nothing back.
                    emptyState
                } else {
                    // Initial / cross-meeting load still in flight.
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
        } else {
            Text("No summary yet.\nIt appears here once the pipeline finishes.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(40)
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

    /// Off-main load of the structured summary, called via `.task(id:)`.
    /// Done off-main because a busy daemon may have us body-evaluating
    /// many times per second; reading from disk on body would beach-ball.
    @MainActor
    private func reloadSummary() async {
        let stem = meeting.stem
        let url = summaryJsonURL
        let parsed: [String: Any]? = await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return obj
        }.value
        // Stem may have changed mid-load; only commit if still relevant.
        if meeting.stem == stem {
            loadedSummary = parsed
            loadedForStem = stem
        }
    }

    // MARK: Editor flow

    private func beginEditing() {
        guard let summary = loadSummaryJSON() else {
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

    /// Writes a correction record (verdict=edited) AND overwrites
    /// `<stem>.summary.json` with the corrected payload so subsequent
    /// reads (and republish) see the new content. Returns true on
    /// success; false (with a logged warning) on disk-write failure.
    private func persistEdit(model: CorrectionViewModel) -> Bool {
        let corrected = model.makeCorrectedSummary()

        // 1. Correction record. Reuses the exact path the standalone
        //    correction window uses so the LoRA training set sees both
        //    surfaces identically.
        do {
            try CorrectionStore.write(
                stem: model.stem,
                transcriptPath: model.transcriptPath,
                summaryJsonPath: model.summaryJsonPath,
                modelId: model.modelId,
                backend: model.backend,
                verdict: .edited,
                originalSummary: model.originalSummary,
                correctedSummary: corrected,
                notes: model.notes.isEmpty ? nil : model.notes
            )
            Log.event(category: "library", action: "summary_edited", attributes: [
                "stem": model.stem,
            ])
        } catch {
            Log.main.warning("CorrectionStore.write failed: \(error.localizedDescription)")
            return false
        }

        // 2. Overwrite the live summary so the row + Markdown render +
        //    any future republish all see the corrected version. The
        //    correction record preserves the original.
        if JSONSerialization.isValidJSONObject(corrected),
           let data = try? JSONSerialization.data(
               withJSONObject: corrected,
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

    private func loadSummaryJSON() -> [String: Any]? {
        guard let data = try? Data(contentsOf: summaryJsonURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

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

/// Renders a parsed `<stem>.summary.json` as proper SwiftUI sections.
/// Replaces the earlier `AttributedString(markdown:)` rendering, which
/// only supports inline syntax and collapsed everything to one
/// paragraph. Inline emphasis / code / links inside individual bullets
/// is still honoured by per-bullet `AttributedString` parsing.
struct SummaryRenderedView: View {
    let summary: [String: Any]

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
            if let lang = detectedLanguage, !lang.isEmpty {
                Text("Detected language: \(lang)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    // MARK: Field accessors

    private var summaryBullets: [String] { stringList(summary["summary"]) }
    private var decisions: [String]      { stringList(summary["decisions"]) }
    private var questions: [String]      { stringList(summary["questions"]) }
    private var attendees: [String]      { stringList(summary["attendees"]) }
    private var detectedLanguage: String? {
        (summary["detected_language"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
    private var actions: [ActionItemRow.Action] {
        guard let arr = summary["actions"] as? [[String: Any]] else { return [] }
        return arr.map { dict in
            ActionItemRow.Action(
                task: (dict["task"] as? String) ?? "",
                owner: (dict["owner"] as? String) ?? "",
                due: (dict["due"] as? String) ?? "",
                confidence: (dict["confidence"] as? String) ?? "medium"
            )
        }.filter { !$0.task.isEmpty }
    }

    private func stringList(_ raw: Any?) -> [String] {
        guard let arr = raw as? [Any] else { return [] }
        return arr.compactMap { ($0 as? String) }.filter { !$0.isEmpty }
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

    /// Per-bullet inline-markdown parsing. Headings + block-level lists
    /// don't apply here because each bullet is one paragraph already; we
    /// just want **bold**, *italic*, `code`, and [links](url) to render.
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
