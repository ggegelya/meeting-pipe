import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// Drag-out payload for a Meeting (TECH-A11). Writes a `meetingpipe-<stem>.md` bundle to `NSTemporaryDirectory()` on demand; re-dragging the same row overwrites the previous temp file rather than fanning out copies.
struct MeetingDragItem: Transferable, Codable {
    let stem: String
    let directoryPath: String
    let displayTitle: String

    init(meeting: Meeting) {
        self.stem = meeting.stem
        self.directoryPath = meeting.recordingsDir.path
        self.displayTitle = meeting.displayTitle
    }

    var directory: URL { URL(fileURLWithPath: directoryPath) }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .fileURL) { item in
            let url = try item.writeBundleToTemp()
            return SentTransferredFile(url, allowAccessingOriginalFile: false)
        }
    }

    /// Builds the markdown bundle and writes it to `NSTemporaryDirectory()`.
    func writeBundleToTemp() throws -> URL {
        let body = MeetingMarkdownBundle.build(stem: stem, in: directory)
        let safeStem = stem.replacingOccurrences(of: "/", with: "-")
        let out = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("meetingpipe-\(safeStem).md", isDirectory: false)
        try body.data(using: .utf8)?.write(to: out, options: .atomic)
        return out
    }
}

/// Renders a meeting's on-disk artefacts into a single markdown document. Pure logic so drag-out behaviour is testable without SwiftUI.
enum MeetingMarkdownBundle {

    static func build(stem: String, in directory: URL) -> String {
        var out: [String] = []

        let summaryJSON = directory.appendingPathComponent("\(stem).summary.json")
        let summaryMD = directory.appendingPathComponent("\(stem).summary.md")
        let transcriptMD = directory.appendingPathComponent("\(stem).md")

        if let body = readSummaryMarkdown(at: summaryMD) {
            out.append(body.trimmingCharacters(in: .whitespacesAndNewlines))
        } else if let summary = readJSON(at: summaryJSON) {
            out.append(renderSummary(summary, stem: stem))
        } else {
            out.append("# \(stem)")
            out.append("_No summary on disk for this meeting._")
        }

        if let transcript = readText(at: transcriptMD)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !transcript.isEmpty {
            out.append("")
            out.append("---")
            out.append("")
            out.append("## Transcript")
            out.append("")
            out.append(transcript)
        }

        return out.joined(separator: "\n") + "\n"
    }

    // MARK: Renderers

    static func renderSummary(_ summary: [String: Any], stem: String) -> String {
        var lines: [String] = []
        let title = (summary["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? stem
        lines.append("# \(title)")
        if let bullets = stringList(summary["summary"]), !bullets.isEmpty {
            lines.append("")
            lines.append("## Summary")
            for b in bullets { lines.append("- \(b)") }
        }
        if let decisions = stringList(summary["decisions"]), !decisions.isEmpty {
            lines.append("")
            lines.append("## Decisions")
            for (i, d) in decisions.enumerated() { lines.append("\(i + 1). \(d)") }
        }
        if let actions = summary["actions"] as? [[String: Any]], !actions.isEmpty {
            lines.append("")
            lines.append("## Action items")
            for a in actions {
                guard let task = (a["task"] as? String), !task.isEmpty else { continue }
                let owner = (a["owner"] as? String) ?? ""
                let due = (a["due"] as? String) ?? ""
                var suffix: [String] = []
                if !owner.isEmpty { suffix.append("owner: \(owner)") }
                if !due.isEmpty { suffix.append("due: \(due)") }
                let trailing = suffix.isEmpty ? "" : " (\(suffix.joined(separator: ", ")))"
                lines.append("- \(task)\(trailing)")
            }
        }
        if let questions = stringList(summary["questions"]), !questions.isEmpty {
            lines.append("")
            lines.append("## Open questions")
            for q in questions { lines.append("- \(q)") }
        }
        if let attendees = stringList(summary["attendees"]), !attendees.isEmpty {
            lines.append("")
            lines.append("## Attendees")
            lines.append(attendees.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Helpers

    private static func readSummaryMarkdown(at url: URL) -> String? {
        return readText(at: url)
    }

    private static func readJSON(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func readText(at url: URL) -> String? {
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private static func stringList(_ raw: Any?) -> [String]? {
        guard let arr = raw as? [Any] else { return nil }
        let strings = arr.compactMap { ($0 as? String) }.filter { !$0.isEmpty }
        return strings.isEmpty ? nil : strings
    }
}
