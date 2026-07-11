import XCTest
@testable import MeetingPipe

/// TECH-END4 (d): `swift test` must never write into the user's production
/// `~/Library/Logs/MeetingPipe/events.jsonl`. These pin the `Log.logsDir`
/// redirect so the dogfood corpus the END band analyzes stays clean.
final class LoggerTests: XCTestCase {
    func test_logsDir_honors_explicit_env_override() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp-logs-\(UUID().uuidString)", isDirectory: true)
        setenv("MEETINGPIPE_LOGS_DIR", tmp.path, 1)
        defer { unsetenv("MEETINGPIPE_LOGS_DIR") }
        XCTAssertEqual(Log.logsDir.standardizedFileURL, tmp.standardizedFileURL)
    }

    func test_logsDir_under_test_never_touches_production() {
        // No explicit override: the XCTest auto-isolation must keep us out of
        // the real logs directory regardless.
        unsetenv("MEETINGPIPE_LOGS_DIR")
        let production = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MeetingPipe", isDirectory: true)
        XCTAssertNotEqual(
            Log.logsDir.standardizedFileURL,
            production.standardizedFileURL,
            "swift test must not write into the user's real events.jsonl"
        )
    }

    // MARK: - PERF7 size-based rotation

    func test_generationURL_inserts_index_before_extension() {
        let jsonl = URL(fileURLWithPath: "/x/events.jsonl")
        XCTAssertEqual(Log.generationURL(jsonl, 1).lastPathComponent, "events.1.jsonl")
        let log = URL(fileURLWithPath: "/x/daemon.log")
        XCTAssertEqual(Log.generationURL(log, 2).lastPathComponent, "daemon.2.log")
    }

    func test_rotateIfNeeded_shifts_generations_and_bounds_count() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("mp-rot-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        setenv("MEETINGPIPE_LOG_MAX_BYTES", "100", 1)
        defer { unsetenv("MEETINGPIPE_LOG_MAX_BYTES") }

        let base = dir.appendingPathComponent("events.jsonl")
        let over = Data(repeating: 0x61, count: 200)

        try over.write(to: base)
        Log.rotateIfNeeded(base)
        XCTAssertFalse(fm.fileExists(atPath: base.path))
        XCTAssertTrue(fm.fileExists(atPath: Log.generationURL(base, 1).path))

        for _ in 0..<6 {
            try over.write(to: base)
            Log.rotateIfNeeded(base)
        }
        XCTAssertTrue(fm.fileExists(atPath: Log.generationURL(base, Log.maxLogGenerations).path))
        XCTAssertFalse(
            fm.fileExists(atPath: Log.generationURL(base, Log.maxLogGenerations + 1).path),
            "rotation must self-bound at maxLogGenerations backups"
        )
    }

    func test_rotateIfNeeded_below_cap_is_noop() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("mp-rot-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        setenv("MEETINGPIPE_LOG_MAX_BYTES", "10000", 1)
        defer { unsetenv("MEETINGPIPE_LOG_MAX_BYTES") }

        let base = dir.appendingPathComponent("events.jsonl")
        try Data(repeating: 0x61, count: 50).write(to: base)
        Log.rotateIfNeeded(base)
        XCTAssertTrue(fm.fileExists(atPath: base.path))
        XCTAssertFalse(fm.fileExists(atPath: Log.generationURL(base, 1).path))
    }

    func test_logGenerations_returns_oldest_first_base_last() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("mp-rot-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let base = dir.appendingPathComponent("events.jsonl")
        try Data("base".utf8).write(to: base)
        try Data("g1".utf8).write(to: Log.generationURL(base, 1))
        try Data("g2".utf8).write(to: Log.generationURL(base, 2))

        XCTAssertEqual(
            Log.logGenerations(base),
            [Log.generationURL(base, 2), Log.generationURL(base, 1), base]
        )
    }
}
