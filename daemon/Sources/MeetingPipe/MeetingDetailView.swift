import AppKit
import SwiftUI

/// Right-pane detail view: header (editable title, date, workflow chip,
/// publish-target shortcuts) plus five tabs. TECH-A4 ships the shell;
/// each tab's real content lands in a later A-task.
///
///   - Summary: A5 swaps in the inline-editable view (current placeholder
///     renders the read-only summary fields if a `<stem>.summary.json`
///     exists).
///   - Transcript: A6 wires speaker-labeled markdown + audio sync.
///   - Audio: A7 renders the stereo waveform.
///   - Corrections: A8 renders the correction record.
///   - Raw files: A9 lists every `<stem>.*` file in the recordings dir.
struct MeetingDetailView: View {
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
        SummaryReadOnlyPlaceholder(meeting: meeting)
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

/// Bare read-only render of the existing summary.json so TECH-A4 has a
/// useful default before A5 wires the inline editor. Shows only the
/// bullet-form fields that the pipeline already emits.
private struct SummaryReadOnlyPlaceholder: View {
    let meeting: Meeting

    @State private var loaded: [String: Any]? = nil

    var body: some View {
        ScrollView {
            if let summary = loaded {
                renderedSummary(summary)
            } else if meeting.summaryTitle == nil {
                Text("No summary yet.\nIt appears here once the pipeline finishes.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(40)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(40)
            }
        }
        .onAppear { reload() }
        .onChange(of: meeting.stem) { _, _ in reload() }
    }

    @ViewBuilder
    private func renderedSummary(_ summary: [String: Any]) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            section("Summary", items: stringList(summary["summary"]))
            section("Decisions", items: stringList(summary["decisions"]))
            actionsSection(summary["actions"])
            section("Open questions", items: stringList(summary["questions"]))
            section("Attendees", items: stringList(summary["attendees"]))
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func section(_ title: String, items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .top, spacing: 6) {
                        Text("·").foregroundStyle(.tertiary)
                        Text(item).font(.body)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func actionsSection(_ raw: Any?) -> some View {
        if let arr = raw as? [[String: Any]], !arr.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Action items")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ForEach(arr.indices, id: \.self) { i in
                    let item = arr[i]
                    HStack(alignment: .top, spacing: 6) {
                        Text("·").foregroundStyle(.tertiary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text((item["task"] as? String) ?? "").font(.body)
                            HStack(spacing: 6) {
                                if let owner = item["owner"] as? String, !owner.isEmpty {
                                    Text(owner).font(.caption).foregroundStyle(.secondary)
                                }
                                if let due = item["due"] as? String, !due.isEmpty {
                                    Text("due \(due)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func stringList(_ raw: Any?) -> [String] {
        guard let arr = raw as? [Any] else { return [] }
        return arr.compactMap { ($0 as? String) }
    }

    private func reload() {
        let path = meeting.recordingsDir.appendingPathComponent("\(meeting.stem).summary.json")
        guard let data = try? Data(contentsOf: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            loaded = nil
            return
        }
        loaded = obj
    }
}
