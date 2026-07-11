import XCTest
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

    func test_filterAndSort_applies_filters_and_orders_newest_first() {
        let events = [
            DiagnosticEvent(id: 0, timestamp: "a", date: Date(timeIntervalSince1970: 100), category: "detector", action: "started", detail: ""),
            DiagnosticEvent(id: 1, timestamp: "b", date: Date(timeIntervalSince1970: 300), category: "detector", action: "ended", detail: ""),
            DiagnosticEvent(id: 2, timestamp: "c", date: Date(timeIntervalSince1970: 200), category: "pipeline", action: "started", detail: ""),
        ]

        // Newest first, no filter.
        XCTAssertEqual(DiagnosticsLog.filterAndSort(events, since: nil, category: nil, action: nil).map(\.id), [1, 2, 0])

        // Category filter.
        XCTAssertEqual(DiagnosticsLog.filterAndSort(events, since: nil, category: "detector", action: nil).map(\.id), [1, 0])

        // Action filter.
        XCTAssertEqual(DiagnosticsLog.filterAndSort(events, since: nil, category: nil, action: "started").map(\.id), [2, 0])

        // Since filter (>= cutoff).
        let cutoff = Date(timeIntervalSince1970: 250)
        XCTAssertEqual(DiagnosticsLog.filterAndSort(events, since: cutoff, category: nil, action: nil).map(\.id), [1])
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
