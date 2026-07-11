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
        let dir = resolveLogsDir()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Resolve the logs directory. An explicit `MEETINGPIPE_LOGS_DIR` wins (sandboxed
    /// runs, targeted tests); otherwise, under XCTest we redirect to a temp dir so
    /// `swift test` never appends fixture rows (clip.wav, stem "m", "Boom error",
    /// notion.example) into the user's production events.jsonl, which would corrupt
    /// every events-log consumer (`mp analyze-detection`, dogfood reports). Matches the
    /// existing MEETINGPIPE_FFMPEG / MEETING_PIPE_DRY_RUN env-override convention.
    private static func resolveLogsDir() -> URL {
        if let override = ProcessInfo.processInfo.environment["MEETINGPIPE_LOGS_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if isRunningUnderTests {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("MeetingPipe-test-logs", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(Endpoints.Paths.logsRelative, isDirectory: true)
    }

    /// True when the process is hosting an XCTest bundle. Checks the runner env vars
    /// first, then falls back to the loaded `XCTestCase` class so the guard holds even
    /// if a future toolchain stops exporting them. The production app never links XCTest.
    private static var isRunningUnderTests: Bool {
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil
            || env["XCTestBundlePath"] != nil
            || env["XCTestSessionIdentifier"] != nil {
            return true
        }
        return NSClassFromString("XCTestCase") != nil
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
        rotateIfNeeded(url)
        if !FileManager.default.fileExists(atPath: url.path) {
            // 0600: the event log and the tail logs carry verbatim meeting titles
            // and transcript-derived context, so they stay private to the user (SEC11).
            FileManager.default.createFile(
                atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]
            )
            return
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    // PERF7: size-based rename rotation so the event log and the tail logs
    // self-bound. `events.jsonl` grew to 63 MB / 338k lines on the dogfood Mac
    // (1 Hz ax/mute state for the whole of every meeting) with no trim.
    static let maxLogGenerations = 3
    private static var maxLogBytes: UInt64 {
        if let raw = ProcessInfo.processInfo.environment["MEETINGPIPE_LOG_MAX_BYTES"],
           let n = UInt64(raw) {
            return n
        }
        return 5 * 1024 * 1024
    }

    /// Rename-rotate `url` when it reaches the size cap. `url` -> `url.1`, shifting
    /// older generations up and dropping the oldest, so a log family self-bounds at
    /// ~`(maxLogGenerations + 1) * maxLogBytes`. Called before every append (the
    /// writers open-per-write) and before the `pipeline.log` handle opens, so there
    /// is never an open handle to a file being renamed. Renames are atomic, so a
    /// writer that loses a rotation race just appends to a fresh file.
    static func rotateIfNeeded(_ url: URL) {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64,
              size >= maxLogBytes else { return }
        try? fm.removeItem(at: generationURL(url, maxLogGenerations))
        var k = maxLogGenerations - 1
        while k >= 1 {
            let src = generationURL(url, k)
            if fm.fileExists(atPath: src.path) {
                let dst = generationURL(url, k + 1)
                try? fm.removeItem(at: dst)
                try? fm.moveItem(at: src, to: dst)
            }
            k -= 1
        }
        let firstGen = generationURL(url, 1)
        try? fm.removeItem(at: firstGen)
        try? fm.moveItem(at: url, to: firstGen)
    }

    /// `events.jsonl` -> `events.1.jsonl`, `daemon.log` -> `daemon.2.log`. The index
    /// goes before the extension so a rotated file stays valid JSONL / a tail-able log.
    static func generationURL(_ url: URL, _ k: Int) -> URL {
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        let name = ext.isEmpty ? "\(stem).\(k)" : "\(stem).\(k).\(ext)"
        return url.deletingLastPathComponent().appendingPathComponent(name)
    }

    /// Existing log files for `url`, oldest first (base last / newest). A reader
    /// concatenating these sees the recent window across a rotation boundary.
    static func logGenerations(_ url: URL) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        var k = maxLogGenerations
        while k >= 1 {
            let g = generationURL(url, k)
            if fm.fileExists(atPath: g.path) { out.append(g) }
            k -= 1
        }
        if fm.fileExists(atPath: url.path) { out.append(url) }
        return out
    }

    /// Best-effort one-time tightening of existing log files to 0600 (SEC11).
    /// New files are created 0600 by `appendData`; this closes the hole for logs
    /// that predate that change (they were created 0644). Call once at startup.
    static func tightenLogPermissions() {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: logsDir, includingPropertiesForKeys: nil
        ) else { return }
        for url in items where url.pathExtension == "jsonl" || url.pathExtension == "log" {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path
            )
        }
    }
}
