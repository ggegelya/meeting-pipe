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

/// PERF13: the logger is one locked `O_APPEND` writer. Before it, two lines in the same
/// millisecond sought to the same offset and the second overwrote the first (the one torn row
/// in the owner's `events.jsonl`), a first-create could drop a line, and two threads could both
/// rotate. Every concurrent case here uses real threads (`concurrentPerform`), not Swift tasks:
/// CI runs a one-thread cooperative pool, where tasks would serialize and pass vacuously.
final class LoggerConcurrencyPERF13Tests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp-perf13-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("MEETINGPIPE_LOGS_DIR", dir.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("MEETINGPIPE_LOGS_DIR")
        unsetenv("MEETINGPIPE_LOG_MAX_BYTES")
        try? FileManager.default.removeItem(at: dir)
    }

    private var events: URL { dir.appendingPathComponent("events.jsonl") }

    /// Every line across the base file and its generations, parsed; a torn line is a nil.
    private func rows(_ base: URL) throws -> [[String: Any]?] {
        try Log.logGenerations(base).flatMap { url -> [[String: Any]?] in
            let text = try String(contentsOf: url, encoding: .utf8)
            return text.split(separator: "\n").map { line in
                (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
            }
        }
    }

    func test_eight_concurrent_writers_lose_and_tear_nothing() throws {
        setenv("MEETINGPIPE_LOG_MAX_BYTES", "\(64 * 1024 * 1024)", 1)
        DispatchQueue.concurrentPerform(iterations: 8) { writer in
            for i in 0..<1_000 {
                Log.event(category: "test", action: "line", attributes: ["writer": writer, "i": i])
            }
        }
        let parsed = try rows(events)
        XCTAssertEqual(parsed.count, 8_000)
        XCTAssertFalse(parsed.contains { $0 == nil }, "a line was torn mid-write")
        let keys = Set(parsed.compactMap { row -> String? in
            guard let row, let w = row["writer"] as? Int, let i = row["i"] as? Int else { return nil }
            return "\(w):\(i)"
        })
        XCTAssertEqual(keys.count, 8_000, "every writer's every line, none overwritten by another")
    }

    func test_concurrent_writers_crossing_the_cap_rotate_once() throws {
        // About 40 KB in all against a 30 KB cap: exactly one crossing. Without the lock two
        // threads both passed the size check and shifted the generations twice.
        setenv("MEETINGPIPE_LOG_MAX_BYTES", "\(30 * 1024)", 1)
        let pad = String(repeating: "x", count: 40)
        DispatchQueue.concurrentPerform(iterations: 8) { writer in
            for i in 0..<50 {
                Log.event(category: "test", action: "line", attributes: ["writer": writer, "i": i, "pad": pad])
            }
        }
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: Log.generationURL(events, 1).path))
        XCTAssertFalse(fm.fileExists(atPath: Log.generationURL(events, 2).path), "rotated twice")
        let parsed = try rows(events)
        XCTAssertEqual(parsed.count, 400)
        XCTAssertFalse(parsed.contains { $0 == nil })
    }

    func test_a_write_after_rotation_lands_in_the_new_base_file() throws {
        setenv("MEETINGPIPE_LOG_MAX_BYTES", "100", 1)
        try Data(repeating: 0x61, count: 200).write(to: events)
        Log.event(category: "test", action: "after_rotation")
        let base = try String(contentsOf: events, encoding: .utf8)
        XCTAssertTrue(base.contains("after_rotation"))
        XCTAssertEqual(try Data(contentsOf: Log.generationURL(events, 1)).count, 200)
    }

    /// The documented flush bound is zero lines: writes are synchronous, so a line is in the
    /// kernel when `event` returns. `UncaughtExceptionLogger` and `flushAndExit` rely on it.
    func test_a_line_is_on_disk_when_event_returns() throws {
        Log.event(category: "test", action: "flushed")
        XCTAssertTrue(try String(contentsOf: events, encoding: .utf8).contains("\"action\":\"flushed\""))
        Log.writeLine("daemon", "flushed line")
        let daemon = dir.appendingPathComponent("daemon.log")
        XCTAssertTrue(try String(contentsOf: daemon, encoding: .utf8).contains("flushed line"))
    }

    func test_a_new_file_is_created_owner_only() throws {
        Log.event(category: "test", action: "first")
        let attrs = try FileManager.default.attributesOfItem(atPath: events.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    /// The other process appending `events.jsonl` is the doctor CLI. With `O_APPEND` on both
    /// sides the kernel places every write at the end, so neither overwrites the other.
    func test_a_child_process_appending_concurrently_loses_nothing() throws {
        setenv("MEETINGPIPE_LOG_MAX_BYTES", "\(64 * 1024 * 1024)", 1)
        Log.event(category: "test", action: "seed")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", """
            i=0
            while [ $i -lt 500 ]; do
              echo "{\\"category\\":\\"child\\",\\"action\\":\\"line\\",\\"i\\":$i}" >> "$1"
              i=$((i+1))
            done
            """, "sh", events.path]
        try child.run()
        for i in 0..<500 {
            Log.event(category: "parent", action: "line", attributes: ["i": i])
        }
        child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0)
        let parsed = try rows(events)
        XCTAssertFalse(parsed.contains { $0 == nil }, "a line was torn")
        XCTAssertEqual(parsed.filter { ($0?["category"] as? String) == "child" }.count, 500)
        XCTAssertEqual(parsed.filter { ($0?["category"] as? String) == "parent" }.count, 500)
    }

    /// `logsDir` stays per call: eleven suites `setenv` it mid-process.
    func test_a_changed_logs_dir_sends_the_next_line_to_the_new_directory() throws {
        Log.event(category: "test", action: "first_dir")
        let second = dir.appendingPathComponent("second", isDirectory: true)
        setenv("MEETINGPIPE_LOGS_DIR", second.path, 1)
        Log.event(category: "test", action: "second_dir")
        let first = try String(contentsOf: events, encoding: .utf8)
        let other = try String(contentsOf: second.appendingPathComponent("events.jsonl"), encoding: .utf8)
        XCTAssertTrue(first.contains("first_dir"))
        XCTAssertFalse(first.contains("second_dir"))
        XCTAssertTrue(other.contains("second_dir"))
    }

    /// No descriptor is kept, so a rename by another process (a rotation there) cannot leave
    /// this one appending into the renamed generation.
    func test_a_rename_by_another_process_sends_the_next_line_to_a_fresh_file() throws {
        Log.event(category: "test", action: "before_rename")
        let renamed = dir.appendingPathComponent("events.1.jsonl")
        try FileManager.default.moveItem(at: events, to: renamed)
        Log.event(category: "test", action: "after_rename")
        XCTAssertTrue(try String(contentsOf: events, encoding: .utf8).contains("after_rename"))
        XCTAssertFalse(try String(contentsOf: renamed, encoding: .utf8).contains("after_rename"))
    }

    /// A directory removed after `logsDir` created it once is recreated, not a lost line.
    func test_a_removed_logs_dir_is_recreated_on_the_next_line() throws {
        Log.event(category: "test", action: "first")
        try FileManager.default.removeItem(at: dir)
        Log.event(category: "test", action: "second")
        XCTAssertTrue(try String(contentsOf: events, encoding: .utf8).contains("second"))
    }

    // MARK: - Coerce, don't drop

    func test_non_json_attributes_are_coerced_into_one_parseable_row() throws {
        let uuid = UUID()
        Log.event(category: "test", action: "coerced", attributes: [
            "url": URL(fileURLWithPath: "/tmp/x.wav"),
            "web": URL(string: "https://example.com/a")!,
            "uuid": uuid,
            "nan": Double.nan,
            "inf": Double.infinity,
            "flag": true,
            "count": 3,
            "nested": ["when": Date(timeIntervalSince1970: 0), "ok": 1.5] as [String: Any],
        ])
        let parsed = try rows(events)
        XCTAssertEqual(parsed.count, 1)
        let row = try XCTUnwrap(parsed.first ?? nil)
        XCTAssertEqual(row["url"] as? String, "/tmp/x.wav")
        XCTAssertEqual(row["web"] as? String, "https://example.com/a")
        XCTAssertEqual(row["uuid"] as? String, uuid.uuidString)
        XCTAssertTrue(row["nan"] is NSNull)
        XCTAssertEqual(row["nan_invalid"] as? Bool, true)
        XCTAssertTrue(row["inf"] is NSNull)
        XCTAssertEqual(row["inf_invalid"] as? Bool, true)
        XCTAssertEqual(row["flag"] as? Bool, true, "a Bool is not a number to coerce")
        XCTAssertEqual(row["count"] as? Int, 3)
        let nested = try XCTUnwrap(row["nested"] as? [String: Any])
        XCTAssertEqual(nested["when"] as? String, "1970-01-01T00:00:00.000Z")
        XCTAssertEqual(nested["ok"] as? Double, 1.5)
    }

    // MARK: - A failed append is reported

    func test_a_failed_append_is_reported_once_per_family() throws {
        // A regular file where the directory should be: every open fails with ENOTDIR.
        let blocker = dir.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        let family = "perf13-unwritable-\(UUID().uuidString).jsonl"
        let url = blocker.appendingPathComponent(family)
        Log.append(Data("one\n".utf8), to: url)
        Log.append(Data("two\n".utf8), to: url)
        XCTAssertTrue(Log.reportedAppendFailures.contains(family))
    }

    // MARK: - pipeline.log

    /// Two `mp` spawns' output streams written at once, through the path `runMP` uses for
    /// every chunk, lose no bytes. The old per-spawn handle wrote at its own stale offset.
    func test_two_concurrent_pipeline_streams_lose_no_bytes() throws {
        setenv("MEETINGPIPE_LOG_MAX_BYTES", "\(64 * 1024 * 1024)", 1)
        let log = dir.appendingPathComponent("pipeline.log")
        DispatchQueue.concurrentPerform(iterations: 2) { stream in
            for i in 0..<500 {
                Log.append(Data("stream\(stream) chunk \(i)\n".utf8), to: log)
            }
        }
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 1_000)
        XCTAssertEqual(Set(lines).count, 1_000)
    }
}
