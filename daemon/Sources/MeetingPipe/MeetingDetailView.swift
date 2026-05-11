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

    /// Persisted across launches so reopening the window keeps the user
    /// on their preferred tab. Hidden behind a stem-keyed default would
    /// be over-engineered for a personal product.
    @AppStorage("MeetingDetailSelectedTab") private var selectedTab: String = Tab.summary.rawValue

    @State private var editingTitle: String = ""
    @State private var lastSyncedStem: String = ""

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
            if let url = notionURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Open in Notion", systemImage: "arrow.up.right.square")
                }
                .controlSize(.small)
            }
            if let url = obsidianURL {
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
        TabPlaceholder(
            icon: Tab.transcript.systemImage,
            title: "Transcript",
            blurb: "Speaker-labeled markdown with click-to-seek. Lands with TECH-A6."
        )
    }

    private var audioTab: some View {
        TabPlaceholder(
            icon: Tab.audio.systemImage,
            title: "Audio",
            blurb: "Stereo mic + system waveform with scrub + zoom. Lands with TECH-A7."
        )
    }

    private var correctionsTab: some View {
        TabPlaceholder(
            icon: Tab.corrections.systemImage,
            title: "Corrections",
            blurb: "Renders the correction record (verdict, edits, notes). Lands with TECH-A8."
        )
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

    private var notionURL: URL? {
        let path = meeting.recordingsDir.appendingPathComponent("\(meeting.stem).notion.json")
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
    private var obsidianURL: URL? {
        let path = meeting.recordingsDir.appendingPathComponent("\(meeting.stem).obsidian.json")
        guard let data = try? Data(contentsOf: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let notePath = obj["note_path"] as? String,
              let vault = obj["vault"] as? String else {
            return nil
        }
        let vaultURL = URL(fileURLWithPath: vault)
        let noteURL = URL(fileURLWithPath: notePath)
        guard let rel = Self.relativePath(of: noteURL, from: vaultURL) else { return nil }
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

/// Summary tab. Read-only by default — renders the pipeline's
/// `<stem>.summary.md` as Markdown via `AttributedString`. The "Edit"
/// button swaps in the shared `CorrectionEditorBody` so the inline
/// editor shares its field surface with the standalone correction
/// window.
///
/// Save persists a correction record (verdict = edited) AND overwrites
/// `<stem>.summary.json` so the next read of the row sees the new
/// content. "Save & Republish" additionally spawns `mp publish-notion`
/// so the published Notion page reflects the edit; the editor stays
/// disabled while the subprocess is running.
struct SummaryTab: View {
    @EnvironmentObject var libraryModel: LibraryWindowModel
    let meeting: Meeting

    /// Toggle between rendered Markdown and the editor form.
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
                if let attributed = renderedMarkdown {
                    Text(attributed)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                } else if meeting.status == .done {
                    Text("Summary markdown not on disk yet.")
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

    private var renderedMarkdown: AttributedString? {
        guard let raw = try? String(contentsOf: summaryMarkdownURL, encoding: .utf8) else {
            return nil
        }
        // `inlineOnlyPreservingWhitespace: true` keeps the line breaks
        // the pipeline writes (headings + bullets + horizontal rules) so
        // the rendered Text view looks the same as Notion's render of
        // the underlying Markdown.
        let opts = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return try? AttributedString(markdown: raw, options: opts)
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
