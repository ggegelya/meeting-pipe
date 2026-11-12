import SQLite3
import XCTest
@testable import MeetingPipe

/// Locks in the `DoctorCommand.execute` contract:
///   - Output marker per probe matches the documented format.
///   - Aggregate exit code: 0 unless at least one probe fails.
///   - `.warn` is informational and doesn't fail the run.
///
/// Each probe is injected as a canned `Probe` so the test doesn't drive
/// AX / AVFoundation / file system - those paths are exercised at
/// integration time via `MeetingPipe doctor` on a real machine.
final class DoctorCommandTests: XCTestCase {

    // MARK: - Output formatting

    func test_formatLine_renders_each_status_with_correct_marker() {
        let ok = DoctorCommand.ProbeResult(name: "x", status: .ok, message: "all good")
        XCTAssertEqual(DoctorCommand.formatLine(ok), "[ OK ] x: all good")

        let warn = DoctorCommand.ProbeResult(name: "x", status: .warn, message: "soft")
        XCTAssertEqual(DoctorCommand.formatLine(warn), "[WARN] x: soft")

        let fail = DoctorCommand.ProbeResult(name: "x", status: .fail, message: "broken")
        XCTAssertEqual(DoctorCommand.formatLine(fail), "[FAIL] x: broken")
    }

    // MARK: - Aggregate exit code

    private func probe(_ name: String, _ status: DoctorCommand.Status, _ msg: String = "") -> DoctorCommand.Probe {
        DoctorCommand.Probe(name: name) {
            DoctorCommand.ProbeResult(name: name, status: status, message: msg)
        }
    }

    func test_all_ok_exits_zero_and_prints_passed_summary() {
        var lines: [String] = []
        let code = DoctorCommand.execute(
            probes: [probe("a", .ok), probe("b", .ok)],
            writer: { lines.append($0) }
        )
        XCTAssertEqual(code, 0)
        XCTAssertTrue(lines.contains("doctor: all probes passed."))
    }

    func test_any_fail_exits_one_and_summary_counts_failures() {
        var lines: [String] = []
        let code = DoctorCommand.execute(
            probes: [probe("a", .ok), probe("b", .fail), probe("c", .fail)],
            writer: { lines.append($0) }
        )
        XCTAssertEqual(code, 1)
        XCTAssertTrue(lines.contains("doctor: 2 probes failed."))
    }

    func test_singular_summary_when_exactly_one_fails() {
        var lines: [String] = []
        let code = DoctorCommand.execute(
            probes: [probe("a", .fail)],
            writer: { lines.append($0) }
        )
        XCTAssertEqual(code, 1)
        XCTAssertTrue(lines.contains("doctor: 1 probe failed."))
    }

    func test_warn_does_not_count_as_failure() {
        var lines: [String] = []
        let code = DoctorCommand.execute(
            probes: [probe("a", .warn), probe("b", .warn), probe("c", .ok)],
            writer: { lines.append($0) }
        )
        XCTAssertEqual(code, 0, "WARN must not flip the exit code")
        XCTAssertTrue(lines.contains("doctor: all probes passed."))
    }

    // MARK: - Probe execution + ordering

    func test_each_probe_runs_exactly_once_in_input_order() {
        var calls: [String] = []
        let probes = ["one", "two", "three"].map { name in
            DoctorCommand.Probe(name: name) {
                calls.append(name)
                return DoctorCommand.ProbeResult(name: name, status: .ok, message: "")
            }
        }
        _ = DoctorCommand.execute(probes: probes, writer: { _ in })
        XCTAssertEqual(calls, ["one", "two", "three"])
    }

    // MARK: - Default probe set

    func test_defaultProbes_includes_every_documented_seam() {
        let names = DoctorCommand.defaultProbes().map { $0.name }
        XCTAssertTrue(names.contains("accessibility.trusted"))
        XCTAssertTrue(names.contains("permission.screen_recording"))
        XCTAssertTrue(names.contains("permission.microphone"))
        XCTAssertTrue(names.contains("pipeline.binary"))
        XCTAssertTrue(names.contains("pipeline.roundtrip"))
        XCTAssertTrue(names.contains("events.writable"))
        XCTAssertTrue(names.contains("search.index"))   // UX23
        XCTAssertTrue(names.contains("app.resources"))  // DIST4
        // Every known meeting app gets an ax.app.<bundle> probe.
        for bundleID in DoctorCommand.knownMeetingBundleIDs {
            XCTAssertTrue(
                names.contains("ax.app.\(bundleID)"),
                "missing per-app probe for \(bundleID)"
            )
        }
    }

    /// UX23: the search-index probe is in the in-app doctor sheet's probe set too, not only the CLI.
    func test_daemonSelfCheckProbes_includes_search_index() {
        let names = DoctorCommand.daemonSelfCheckProbes().map { $0.name }
        XCTAssertTrue(names.contains("search.index"))
    }

    /// DIST4: the in-app doctor sheet names a misassembled app too, since the lookup no longer crashes.
    func test_daemonSelfCheckProbes_includes_app_resources() {
        let names = DoctorCommand.daemonSelfCheckProbes().map { $0.name }
        XCTAssertTrue(names.contains("app.resources"))
    }

    // MARK: - DIST4 app.resources

    func test_probeResources_ok_when_every_resource_loads() {
        let result = DoctorCommand.probeResources()
        XCTAssertEqual(result.status, .ok, result.message)
        XCTAssertEqual(result.name, "app.resources")
        XCTAssertTrue(result.message.contains(Bundle.appResources.bundlePath), result.message)
    }

    func test_probeResources_fails_naming_every_missing_resource() throws {
        struct Missing: Error {}
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("probeResources-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        let result = DoctorCommand.probeResources(
            loadMuteLabels: { throw Missing() },
            appBundle: try XCTUnwrap(Bundle(url: empty))
        )
        XCTAssertEqual(result.status, .fail)
        for name in ["MuteLabels.toml", "meeting_apps.toml", "_fallback.svg"] {
            XCTAssertTrue(result.message.contains(name), "\(name) not named in: \(result.message)")
        }
    }

    func test_app_bundle_name_matches_what_swiftpm_generated() {
        // Under `swift test` `appResources` resolves through `Bundle.module`, so its file name is
        // SwiftPM's own; the hardcoded name is what an installed app looks up in Contents/Resources.
        XCTAssertEqual(Bundle.appResources.bundleURL.deletingPathExtension().lastPathComponent, Bundle.appResourceBundleName)
    }

    // MARK: - Per-probe pure helpers

    func test_probeAppReachable_warns_when_app_not_installed() {
        // A bundle ID that definitely isn't installed anywhere.
        let result = DoctorCommand.probeAppReachable(bundleID: "com.test.does-not-exist-anywhere-12345")
        XCTAssertEqual(result.status, .warn)
        XCTAssertEqual(result.name, "ax.app.com.test.does-not-exist-anywhere-12345")
    }

    // MARK: - PERF20: search.index compares the index with the library

    private func searchProbeFixture() throws -> (dir: URL, library: URL, indexURL: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("probeSearch-\(UUID().uuidString)")
        let library = dir.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        for stem in ["20260301-100000", "20260302-100000"] {
            try Data().write(to: library.appendingPathComponent("\(stem).wav"))
            try Data("transcript".utf8).write(to: library.appendingPathComponent("\(stem).md"))
        }
        // Neither of these is a `<stem>.md` transcript, so neither is counted.
        try Data().write(to: library.appendingPathComponent("20260301-100000.READY_FOR_MANUAL.md"))
        try Data().write(to: library.appendingPathComponent("notes.md"))
        return (dir, library, dir.appendingPathComponent("index.sqlite"))
    }

    func test_probeSearchIndex_warns_for_an_empty_index_beside_a_library_with_transcripts() throws {
        let f = try searchProbeFixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let result = DoctorCommand.probeSearchIndex(indexURL: f.indexURL, recordingsDir: f.library)
        XCTAssertEqual(result.status, .warn)
        XCTAssertTrue(result.message.contains("0 meetings indexed"), result.message)
        XCTAssertTrue(result.message.contains("2 of the library's 2 transcripts"), result.message)
    }

    func test_probeSearchIndex_is_ok_when_every_transcript_is_indexed() throws {
        let f = try searchProbeFixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        do {
            let index = try XCTUnwrap(SearchIndex(url: f.indexURL))
            index.upsert(stem: "20260301-100000", sig: "s", body: "a")
            index.upsert(stem: "20260302-100000", sig: "s", body: "b")
        }
        let result = DoctorCommand.probeSearchIndex(indexURL: f.indexURL, recordingsDir: f.library)
        XCTAssertEqual(result.status, .ok, result.message)
        XCTAssertEqual(result.message, "FTS index reachable; 2 meetings indexed.")
    }

    // MARK: - search.index is read-only: a diagnostic never creates or migrates the cache

    /// A raw-SQLite index at `version`, built without `SearchIndex` so it can carry a schema this
    /// build does not use. WAL like the real one.
    private func writeRawIndex(at url: URL, version: Int32, stems: [String]) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        var sql = "PRAGMA journal_mode=WAL; PRAGMA user_version = \(version);"
            + "CREATE TABLE doc_meta(stem TEXT PRIMARY KEY, sig TEXT NOT NULL, docid INTEGER NOT NULL);"
        for (i, stem) in stems.enumerated() { sql += "INSERT INTO doc_meta VALUES('\(stem)', 's', \(i));" }
        sql += "PRAGMA wal_checkpoint(TRUNCATE);"
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }

    private func rawUserVersionAndTables(at url: URL) throws -> (Int32, [String]) {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil)
        sqlite3_step(stmt)
        let version = sqlite3_column_int(stmt, 0)
        sqlite3_finalize(stmt)
        var tables: [String] = []
        sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name;", -1, &stmt, nil)
        while sqlite3_step(stmt) == SQLITE_ROW { tables.append(String(cString: sqlite3_column_text(stmt, 0))) }
        sqlite3_finalize(stmt)
        return (version, tables)
    }

    /// The 2026-11-12 incident: a newer build's doctor opened the live cache through `SearchIndex`,
    /// whose `prepareSchema` dropped and recreated the tables under a running older daemon.
    func test_probeSearchIndex_reports_another_schema_without_migrating_it() throws {
        let f = try searchProbeFixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        try writeRawIndex(at: f.indexURL, version: 1, stems: ["20260301-100000"])
        let result = DoctorCommand.probeSearchIndex(indexURL: f.indexURL, recordingsDir: f.library)
        XCTAssertEqual(result.status, .warn)
        XCTAssertTrue(result.message.contains("schema 1"), result.message)
        XCTAssertTrue(result.message.contains("schema \(SearchIndex.schemaVersion)"), result.message)
        let (version, tables) = try rawUserVersionAndTables(at: f.indexURL)
        XCTAssertEqual(version, 1, "doctor migrated the index")
        XCTAssertEqual(tables, ["doc_meta"], "doctor changed the index's tables")
    }

    func test_probeSearchIndex_does_not_create_a_missing_index() throws {
        let f = try searchProbeFixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let result = DoctorCommand.probeSearchIndex(indexURL: f.indexURL, recordingsDir: f.library)
        XCTAssertEqual(result.status, .warn)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.indexURL.path), "doctor created the index")
    }

    func test_probeSearchIndex_missing_index_beside_an_empty_library_is_ok() throws {
        let f = try searchProbeFixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let empty = f.dir.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let result = DoctorCommand.probeSearchIndex(indexURL: f.indexURL, recordingsDir: empty)
        XCTAssertEqual(result.status, .ok, result.message)
        XCTAssertEqual(result.message, "FTS index not built yet; 0 meetings indexed.")
    }

    /// A stopped daemon leaves a WAL-mode file with no `-shm`, where a plain read-only open fails
    /// with SQLITE_CANTOPEN; the probe still has to read it, and still without writing.
    func test_probeSearchIndex_reads_a_wal_index_with_no_shm_file() throws {
        let f = try searchProbeFixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        try writeRawIndex(at: f.indexURL, version: SearchIndex.schemaVersion, stems: ["20260301-100000", "20260302-100000"])
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: f.indexURL.path + suffix)
        }
        let before = try FileManager.default.attributesOfItem(atPath: f.indexURL.path)[.modificationDate] as? Date
        let result = DoctorCommand.probeSearchIndex(indexURL: f.indexURL, recordingsDir: f.library)
        XCTAssertEqual(result.status, .ok, result.message)
        XCTAssertEqual(result.message, "FTS index reachable; 2 meetings indexed.")
        let after = try FileManager.default.attributesOfItem(atPath: f.indexURL.path)[.modificationDate] as? Date
        XCTAssertEqual(before, after, "doctor wrote the index")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.indexURL.path + "-shm"), "doctor created a -shm file")
    }
}
