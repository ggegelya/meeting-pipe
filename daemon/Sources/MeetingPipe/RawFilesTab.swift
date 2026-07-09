import AppKit
import SwiftUI

/// Raw files tab (TECH-A9). Lists every sidecar sharing the meeting's stem, with size, modified time, and per-row Reveal in Finder.

struct RawFilesTab: View {
    let meeting: Meeting

    @State private var files: [RawFileEntry] = []
    @State private var loading: Bool = true
    @State private var loadedForStem: String? = nil

    var body: some View {
        content
            .task(id: meeting.stem) { await reload() }
    }

    @ViewBuilder
    private var content: some View {
        if loading && loadedForStem != meeting.stem {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if files.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(files) { entry in
                            RawFileRow(entry: entry)
                            Divider()
                                .padding(.leading, 16)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Divider()
                HStack(spacing: 8) {
                    Text("\(files.count) file\(files.count == 1 ? "" : "s") under \(meeting.recordingsDir.path)")
                        .font(.caption)
                        .foregroundStyle(Color(MPColors.fgSubtle))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([meeting.revealURL])
                    } label: {
                        Label("Open folder", systemImage: "folder")
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 32))
                .foregroundStyle(Color(MPColors.fgSubtle))
            Text("No sidecars on disk for this stem.")
                .font(.callout)
                .foregroundStyle(Color(MPColors.fgMuted))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    @MainActor
    private func reload() async {
        let stem = meeting.stem
        let dir = meeting.recordingsDir
        loading = true
        let entries = await Task.detached(priority: .userInitiated) {
            RawFilesLister.list(stem: stem, in: dir)
        }.value
        guard meeting.stem == stem else { return }
        files = entries
        loadedForStem = stem
        loading = false
    }
}

// MARK: - Entry + row

struct RawFileEntry: Identifiable, Equatable {
    let url: URL
    let sizeBytes: Int64
    let modified: Date?
    let kind: Kind

    var id: String { url.path }

    enum Kind: Int, Comparable {
        case wav = 0          // the recording itself - always first
        case transcript = 1   // <stem>.json
        case markdownTranscript = 2  // <stem>.md
        case summaryJSON = 3
        case summaryMarkdown = 4
        case meta = 5
        case run = 6
        case notion = 7
        case obsidian = 8
        case readyForManual = 9
        case correction = 10  // (lives in App Support, not here, but kept as a slot)
        case other = 99

        static func < (lhs: Kind, rhs: Kind) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        var label: String {
            switch self {
            case .wav: return "Recording (WAV)"
            case .transcript: return "Transcript (JSON)"
            case .markdownTranscript: return "Transcript (Markdown)"
            case .summaryJSON: return "Summary (JSON)"
            case .summaryMarkdown: return "Summary (Markdown)"
            case .meta: return "Meta sidecar"
            case .run: return "Pipeline run sidecar"
            case .notion: return "Notion publish sidecar"
            case .obsidian: return "Obsidian publish sidecar"
            case .readyForManual: return "Manual-paste handoff"
            case .correction: return "Correction record"
            case .other: return "Other"
            }
        }

        var systemImage: String {
            switch self {
            case .wav: return "waveform"
            case .transcript: return "text.bubble"
            case .markdownTranscript: return "doc.plaintext"
            case .summaryJSON, .summaryMarkdown: return "doc.text"
            case .meta, .run: return "info.circle"
            case .notion: return "link"
            case .obsidian: return "link"
            case .readyForManual: return "hand.raised"
            case .correction: return "pencil"
            case .other: return "doc"
            }
        }
    }
}

/// Pure-logic lister, separated from the view so tests can exercise it directly.
enum RawFilesLister {
    static func list(stem: String, in directory: URL) -> [RawFileEntry] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var out: [RawFileEntry] = []
        let prefix = "\(stem)."
        for url in entries {
            let name = url.lastPathComponent
            guard name == "\(stem)" || name.hasPrefix(prefix) else { continue }
            let vals = try? url.resourceValues(forKeys: Set(keys))
            let size = Int64(vals?.fileSize ?? 0)
            let mtime = vals?.contentModificationDate
            out.append(RawFileEntry(
                url: url,
                sizeBytes: size,
                modified: mtime,
                kind: classify(name: name, stem: stem)
            ))
        }
        out.sort { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
            return lhs.url.lastPathComponent < rhs.url.lastPathComponent
        }
        return out
    }

    static func classify(name: String, stem: String) -> RawFileEntry.Kind {
        // Kind ordering doubles as the sort key; match most specific suffix first.
        // A compressed meeting's recording is `<stem>.flac` (STOR1); both sort and
        // render as the recording row.
        if MeetingStore.finalRecordingExtensions.contains(where: { name == "\(stem).\($0)" }) {
            return .wav
        }
        if name == "\(stem).meta.json" { return .meta }
        if name == "\(stem).run.json" { return .run }
        if name == "\(stem).summary.json" { return .summaryJSON }
        if name == "\(stem).summary.md" { return .summaryMarkdown }
        if name == "\(stem).notion.json" { return .notion }
        if name == "\(stem).obsidian.json" { return .obsidian }
        if name == "\(stem).READY_FOR_MANUAL.md" { return .readyForManual }
        if name == "\(stem).json" { return .transcript }
        if name == "\(stem).md" { return .markdownTranscript }
        return .other
    }
}

private struct RawFileRow: View {
    let entry: RawFileEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.kind.systemImage)
                .frame(width: 22)
                .foregroundStyle(Color(MPColors.fgMuted))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(entry.url.lastPathComponent)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack(spacing: 6) {
                    Text(entry.kind.label)
                        .font(.caption)
                        .foregroundStyle(Color(MPColors.fgSubtle))
                    Text("·").foregroundStyle(Color(MPColors.fgSubtle))
                    Text(formatSize(entry.sizeBytes))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Color(MPColors.fgSubtle))
                    if let m = entry.modified {
                        Text("·").foregroundStyle(Color(MPColors.fgSubtle))
                        Text(MeetingFormatters.fullDateTime.string(from: m))
                            .font(.caption)
                            .foregroundStyle(Color(MPColors.fgSubtle))
                    }
                }
            }
            Spacer(minLength: 0)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([entry.url])
            } label: {
                Label("Reveal", systemImage: "folder")
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            NSWorkspace.shared.open(entry.url)
        }
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([entry.url])
            }
            Button("Open with default app") {
                NSWorkspace.shared.open(entry.url)
            }
            Button("Copy path") {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(entry.url.path, forType: .string)
            }
        }
    }
}

private func formatSize(_ bytes: Int64) -> String {
    let f = ByteCountFormatter()
    f.allowedUnits = [.useKB, .useMB, .useGB]
    f.countStyle = .file
    return f.string(fromByteCount: bytes)
}
