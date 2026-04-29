import Foundation
import os.log

enum Log {
    static let main = Logger(subsystem: "com.meetingpipe.daemon", category: "main")
    static let detector = Logger(subsystem: "com.meetingpipe.daemon", category: "detector")
    static let recorder = Logger(subsystem: "com.meetingpipe.daemon", category: "recorder")

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static var logsDir: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MeetingPipe", isDirectory: true)
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
