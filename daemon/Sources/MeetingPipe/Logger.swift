import Foundation
import os.log

enum Log {
    static let main = Logger(subsystem: Endpoints.logSubsystem, category: "main")
    static let detector = Logger(subsystem: Endpoints.logSubsystem, category: "detector")
    static let recorder = Logger(subsystem: Endpoints.logSubsystem, category: "recorder")

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static var logsDir: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(Endpoints.Paths.logsRelative, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Append-only line writer for permanent records. os.Logger goes to the unified
    /// log; this writes a tail-able file matching SPEC §9 ("logs all events to
    /// ~/Library/Logs/MeetingPipe/<category>.log").
    static func writeLine(_ category: String, _ message: String) {
        let url = logsDir.appendingPathComponent("\(category).log")
        let line = "[\(isoFormatter.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        appendData(data, to: url)
    }

    /// Structured event log. One JSON object per line in `events.jsonl`,
    /// alongside the human-readable text logs. The text logs stay tailable
    /// for live debugging; JSONL is for grepping with `jq` after the fact.
    ///
    /// Attribute values must be JSON-serializable (String, Bool, Int,
    /// Double, Array, Dictionary, or NSNull). A non-serializable value
    /// drops the event silently rather than crashing the daemon: an event
    /// log going dark is preferable to a meeting going unrecorded.
    static func event(
        category: String,
        action: String,
        attributes: [String: Any] = [:]
    ) {
        var dict: [String: Any] = attributes
        dict["ts"] = isoFormatter.string(from: Date())
        dict["category"] = category
        dict["action"] = action
        guard JSONSerialization.isValidJSONObject(dict),
              let json = try? JSONSerialization.data(
                withJSONObject: dict, options: [.sortedKeys, .withoutEscapingSlashes]
              ) else {
            return
        }
        var line = json
        line.append(0x0A) // newline
        appendData(line, to: logsDir.appendingPathComponent("events.jsonl"))
    }

    private static func appendData(_ data: Data, to url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: data)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
