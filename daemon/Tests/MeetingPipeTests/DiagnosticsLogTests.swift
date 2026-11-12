import XCTest
import os
@testable import MeetingPipe

/// UX20: the read-only diagnostics reader. Covers the pure parse/filter/sort and
/// reading across PERF7's rotated generations. The window/view are not unit-tested
/// (owner eyeball); this is the logic behind them.
final class DiagnosticsLogTests: XCTestCase {

    private func line(_ ts: String, _ category: String, _ action: String, _ attrs: [String: Any] = [:]) -> String {
        var obj = attrs
        obj["ts"] = ts
        obj["category"] = category
        obj["action"] = action
        let data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    func test_parseLine_extracts_fields_and_sorted_detail() {
        let raw = line("2026-07-11T10:00:00.000Z", "coordinator", "recording_started",
                       ["summary_mode": "auto", "bundle_id": "us.zoom.xos"])
        let ev = DiagnosticsLog.parseLine(raw, id: 0)
        XCTAssertEqual(ev?.category, "coordinator")
        XCTAssertEqual(ev?.action, "recording_started")
        // Sorted keys, ts/category/action skipped.
        XCTAssertEqual(ev?.detail, "bundle_id=us.zoom.xos summary_mode=auto")
        XCTAssertNotNil(ev?.date)
    }

    func test_parseLine_rejects_blank_and_malformed() {
        XCTAssertNil(DiagnosticsLog.parseLine("", id: 0))
        XCTAssertNil(DiagnosticsLog.parseLine("   ", id: 0))
        XCTAssertNil(DiagnosticsLog.parseLine("{not json", id: 0))
    }

    func test_load_applies_filters_and_orders_newest_first_across_both_families() throws {
        let dir = try tempDir()
        // The two families interleave in time; each ascends within its own file.
        try write(dir.appendingPathComponent("events.jsonl"), [
            line("1970-01-01T00:01:40.000Z", "detector", "started"),
            line("1970-01-01T00:05:00.000Z", "detector", "ended"),
        ])
        try write(dir.appendingPathComponent("pipeline_events.jsonl"), [
            line("1970-01-01T00:03:20.000Z", "pipeline", "started"),
        ])
        func actions(_ q: DiagnosticsQuery) -> [String] {
            DiagnosticsLog.load(logsDir: dir, query: q).events.map { "\($0.category).\($0.action)" }
        }
        XCTAssertEqual(actions(.init()), ["detector.ended", "pipeline.started", "detector.started"])
        XCTAssertEqual(actions(.init(category: "detector")), ["detector.ended", "detector.started"])
        XCTAssertEqual(actions(.init(action: "started")), ["pipeline.started", "detector.started"])
        XCTAssertEqual(actions(.init(since: Date(timeIntervalSince1970: 250))), ["detector.ended"])
    }

    // MARK: - PERF13: off main, bounded, counted

    private var dirs: [URL] = []

    override func tearDown() {
        for dir in dirs { try? FileManager.default.removeItem(at: dir) }
        dirs = []
        super.tearDown()
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp-diag13-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dirs.append(dir)
        return dir
    }

    private func write(_ url: URL, _ lines: [String]) throws {
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
    }

    private func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    func test_generations_wholly_before_since_are_never_opened() throws {
        let dir = try tempDir()
        let base = dir.appendingPathComponent("events.jsonl")
        let now = Date()
        let old = now.addingTimeInterval(-3 * 3600)
        try write(base, [line(iso(now.addingTimeInterval(-60)), "coordinator", "recent")])
        for k in 1...2 {
            let g = Log.generationURL(base, k)
            try write(g, [line(iso(old), "coordinator", "old\(k)")])
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: g.path)
        }
        var opened: [String] = []
        let result = DiagnosticsLog.load(
            logsDir: dir, query: .init(since: now.addingTimeInterval(-3600)),
            read: { url in opened.append(url.lastPathComponent); return try? String(contentsOf: url, encoding: .utf8) }
        )
        XCTAssertEqual(result.events.map(\.action), ["recent"])
        XCTAssertEqual(opened, ["events.jsonl"], "rotated generations older than since must not be read")
    }

    func test_detail_is_built_only_for_returned_rows() throws {
        let dir = try tempDir()
        let rows = (0..<10_000).map { i in
            line(iso(Date(timeIntervalSince1970: TimeInterval(1_000_000 + i))), "detector", "tick", ["i": i])
        }
        try write(dir.appendingPathComponent("events.jsonl"), rows)
        var formatted = 0
        let counting: DiagnosticsLog.Formatter = { formatted += 1; return DiagnosticsLog.formatDetail($0) }

        let none = DiagnosticsLog.load(logsDir: dir, query: .init(category: "micgate"), formatDetail: counting)
        XCTAssertTrue(none.events.isEmpty)
        XCTAssertEqual(formatted, 0, "a row rejected by its category must never have its detail built")

        let all = DiagnosticsLog.load(logsDir: dir, query: .init(), formatDetail: counting)
        XCTAssertEqual(all.events.count, DiagnosticsLog.displayLimit)
        XCTAssertEqual(formatted, DiagnosticsLog.displayLimit, "detail only for the rows returned")
        XCTAssertEqual(all.events.first?.detail, "i=9999", "newest first")
        XCTAssertEqual(Set(all.events.map(\.id)).count, all.events.count, "ids stay unique")
    }

    func test_a_torn_line_is_counted_as_skipped() throws {
        let dir = try tempDir()
        // The shape of the one torn row in the owner's log: a row's tail after a second write
        // overwrote its head.
        try write(dir.appendingPathComponent("events.jsonl"), [
            line("2026-10-16T09:46:28.257Z", "coordinator", "state_change"),
            #"n ","ts":"2026-10-16T09:46:28.265Z"}"#,
            line("2026-10-16T09:46:28.265Z", "lifecycle", "idle"),
        ])
        let result = DiagnosticsLog.load(logsDir: dir, query: .init())
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(result.events.map(\.action), ["idle", "state_change"])
    }

    /// Holds a load on a continuation rather than blocking a cooperative-pool thread (CI8).
    private actor Gate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var open = false
        func wait() async {
            if open { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func release() {
            open = true
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }

    @MainActor
    func test_an_older_reload_finishing_last_does_not_overwrite_the_newer_one() async {
        let olderGate = Gate()
        let ranOnMain = OSAllocatedUnfairLock(initialState: false)
        let model = DiagnosticsModel { query in
            if pthread_main_np() != 0 { ranOnMain.withLock { $0 = true } }
            if query.category == "older" { await olderGate.wait() }
            let event = DiagnosticEvent(
                id: 0, timestamp: "", date: nil, category: query.category ?? "", action: "", detail: ""
            )
            return DiagnosticsResult(events: [event], skipped: 0)
        }
        let older = model.reload(.init(category: "older"))
        XCTAssertTrue(model.isLoading)
        let newer = model.reload(.init(category: "newer"))
        await newer.value
        XCTAssertEqual(model.result.events.first?.category, "newer")
        await olderGate.release()
        await older.value
        XCTAssertEqual(model.result.events.first?.category, "newer", "a stale reload landed over a newer one")
        XCTAssertFalse(model.isLoading)
        XCTAssertTrue(model.hasLoaded)
        XCTAssertFalse(ranOnMain.withLock { $0 }, "the log read must run off main")
    }

    func test_load_reads_across_rotated_generations() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("mp-diag-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let base = dir.appendingPathComponent("events.jsonl")
        // Newest event in the live base, older event in a rotated generation.
        try (line("2026-07-11T10:05:00.000Z", "coordinator", "recording_stopped") + "\n")
            .data(using: .utf8)!.write(to: base)
        try (line("2026-07-11T10:00:00.000Z", "coordinator", "recording_started") + "\n")
            .data(using: .utf8)!.write(to: Log.generationURL(base, 1))

        let events = DiagnosticsLog.load(logsDir: dir, since: nil, category: "coordinator", action: nil)
        XCTAssertEqual(events.map(\.action), ["recording_stopped", "recording_started"])
    }

    func test_daemonSelfCheckProbes_excludes_pipeline_probes() {
        let names = DoctorCommand.daemonSelfCheckProbes().map(\.name)
        XCTAssertTrue(names.contains("accessibility.trusted"))
        XCTAssertTrue(names.contains("events.writable"))
        XCTAssertTrue(names.contains("library.orphans"))
        XCTAssertFalse(names.contains("pipeline.roundtrip"))
        XCTAssertFalse(names.contains("pipeline.binary"))
    }
}
