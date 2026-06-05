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

    /// Append-only tail-able log file (logging conventions in CONVENTIONS.md). os.Logger goes to the unified log; this writes ~/Library/Logs/MeetingPipe/<category>.log.
    static func writeLine(_ category: String, _ message: String) {
        let url = logsDir.appendingPathComponent("\(category).log")
        let line = "[\(isoFormatter.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        appendData(data, to: url)
    }

    /// Write one JSON object per line to `events.jsonl` for `jq`-based post-hoc analysis. A non-serializable attribute value drops the event silently rather than crashing the daemon.
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
