import os
import XCTest
@testable import MeetingPipe

/// STOR11: a recordings folder that exists and cannot be read is named as such, by the Library,
/// by doctor and by the background sweeps, instead of passing for an empty library. Every test
/// works on a `chmod 000` temp folder and restores its mode before cleanup.
@MainActor
final class LibraryUnreadableSTOR11Tests: XCTestCase {
    private var base: URL!
    private var lib: URL!

    override func setUpWithError() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mp-stor11-\(UUID().uuidString)", isDirectory: true)
        lib = base.appendingPathComponent("raw", isDirectory: true)
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        for stem in ["20260301-100000", "20260302-100000"] {
            try Data().write(to: lib.appendingPathComponent("\(stem).wav"))
            try Data(#"{"title": "t"}"#.utf8).write(to: lib.appendingPathComponent("\(stem).summary.json"))
        }
        // A failed meeting, so the menu's count has something to count once readable.
        try Data().write(to: lib.appendingPathComponent("20260303-100000.wav"))
        try Data(#"{"stage": "summarize", "reason": "x"}"#.utf8)
            .write(to: lib.appendingPathComponent("20260303-100000.error.json"))
    }

    override func tearDownWithError() throws {
        chmod(lib.path, 0o700)
        try? FileManager.default.removeItem(at: base)
    }

    private func lock() { XCTAssertEqual(chmod(lib.path, 0), 0) }
    private func unlock() { XCTAssertEqual(chmod(lib.path, 0o700), 0) }

    private func until(_ what: String, _ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(5)
        while !predicate() {
            if Date() > deadline { XCTFail("timed out waiting for \(what)", file: file, line: line); return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: The root state

    func test_classifies_unreadable_missing_and_readable() throws {
        XCTAssertEqual(LibraryRootState.probe(lib), .readable)
        lock()
        guard case .unreadable(let code, let reason) = LibraryRootState.probe(lib) else {
            return XCTFail("a chmod 000 folder must read as unreadable, got \(LibraryRootState.probe(lib))")
        }
        XCTAssertEqual(code, EACCES)
        XCTAssertFalse(reason.isEmpty)
        XCTAssertTrue(LibraryRootState.probe(lib).isPermissionDenial)
        unlock()
        XCTAssertEqual(LibraryRootState.probe(base.appendingPathComponent("gone")), .missing)
    }

    /// The defect: `performScan` answered a failed listing with the same `[]` a readable empty
    /// library gives, so the Library showed "No recordings yet".
    func test_the_store_names_an_unreadable_root_and_recovers_when_it_reads_again() async throws {
        lock()
        let store = MeetingStore(recordingsDir: lib)
        store.start()
        defer { store.stop() }
        await until("first scan") { store.hasLoadedOnce }

        XCTAssertTrue(store.meetings.isEmpty)
        guard case .unreadable(let code, _) = store.rootState else {
            return XCTFail("expected unreadable, got \(store.rootState)")
        }
        XCTAssertEqual(code, EACCES)
        guard case .unreadableRoot(_, _, let permission) = LibraryListPlaceholder.decide(
            hasLoadedOnce: true, isEmpty: true, rootState: store.rootState, root: lib
        ) else { return XCTFail("the Library must name the unreadable folder, not show a first run") }
        XCTAssertTrue(permission, "EACCES offers Open Privacy & Security")
        XCTAssertFalse(store.isWatching, "nothing to watch while the folder cannot be opened")

        unlock()
        store.refresh()
        await until("readable rescan") { store.rootState == .readable && store.meetings.count == 3 }
        XCTAssertTrue(store.isWatching, "the watcher is re-attempted after the next scan that lists the root")
    }

    func test_a_non_permission_failure_offers_reveal_in_finder() {
        let state = LibraryRootState.unreadable(errno: EIO, reason: "Input/output error")
        XCTAssertEqual(
            LibraryListPlaceholder.decide(hasLoadedOnce: true, isEmpty: true, rootState: state, root: URL(fileURLWithPath: "/v/raw")),
            .unreadableRoot(path: "/v/raw", reason: "Input/output error", permission: false)
        )
    }

    // MARK: Doctor

    func test_library_readable_probe_fails_on_an_unreadable_folder_and_passes_on_a_readable_one() {
        XCTAssertEqual(DoctorCommand.probeLibraryReadable(dir: lib).status, .ok)
        lock()
        let result = DoctorCommand.probeLibraryReadable(dir: lib)
        XCTAssertEqual(result.status, .fail)
        XCTAssertTrue(result.message.contains(lib.path))
        XCTAssertTrue(result.message.contains("Privacy & Security"))
        unlock()
        XCTAssertEqual(DoctorCommand.probeLibraryReadable(dir: base.appendingPathComponent("gone")).status, .warn)
    }

    /// The defect: the orphan probe reported `.ok` "No orphaned recordings" over a listing that failed.
    func test_orphan_probe_is_not_ok_when_the_listing_fails() {
        lock()
        let result = DoctorCommand.probeOrphans(dir: lib)
        XCTAssertEqual(result.status, .warn)
        XCTAssertTrue(result.message.contains("skipped: library unreadable"))
        XCTAssertNotEqual(OrphanScan.scan(directory: lib).rootState, .readable)
    }

    func test_library_readable_runs_ahead_of_library_orphans_in_both_probe_sets() {
        for names in [DoctorCommand.defaultProbes().map(\.name), DoctorCommand.daemonSelfCheckProbes().map(\.name)] {
            let readable = try? XCTUnwrap(names.firstIndex(of: "library.readable"))
            let orphans = try? XCTUnwrap(names.firstIndex(of: "library.orphans"))
            XCTAssertNotNil(readable)
            if let readable, let orphans { XCTAssertLessThan(readable, orphans) }
        }
    }

    // MARK: Background sweeps

    func test_library_unreadable_fires_once_per_state_change_across_menu_counts() {
        let events = OSAllocatedUnfairLock<[[String: String]]>(initialState: [])
        let reporter = LibraryUnreadableReporter { attributes in
            let flat = attributes.mapValues { "\($0)" }
            events.withLock { $0.append(flat) }
        }

        lock()
        for _ in 0..<5 {
            XCTAssertEqual(MeetingLibraryService.failedMeetingCount(in: lib, reporter: reporter), 0)
        }
        XCTAssertEqual(events.withLock { $0.count }, 1, "five menu opens, one row")
        XCTAssertEqual(events.withLock { $0.first?["site"] }, "failed_count")
        XCTAssertEqual(events.withLock { $0.first?["errno"] }, "\(EACCES)")

        unlock()
        XCTAssertEqual(MeetingLibraryService.failedMeetingCount(in: lib, reporter: reporter), 1)
        lock()
        _ = MeetingLibraryService.failedMeetingCount(in: lib, reporter: reporter)
        _ = MeetingLibraryService.failedMeetingCount(in: lib, reporter: reporter)
        XCTAssertEqual(events.withLock { $0.count }, 2, "a readable scan then a new failure fires again")
    }

    func test_orphan_recovery_reports_its_skip() {
        let count = OSAllocatedUnfairLock(initialState: 0)
        let reporter = LibraryUnreadableReporter { attributes in
            if attributes["site"] as? String == "orphan_recovery" { count.withLock { $0 += 1 } }
        }
        lock()
        XCTAssertEqual(OrphanRecordingRecovery.scanOrphanStems(in: lib, reporter: reporter), [])
        XCTAssertEqual(OrphanRecordingRecovery.scanOrphanStems(in: lib, reporter: reporter), [])
        XCTAssertEqual(count.withLock { $0 }, 1)
    }

    func test_the_stranded_job_sweep_reports_through_the_shared_reporter() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MeetingPipe/Coordinator.swift")
        let text = try String(contentsOf: sources, encoding: .utf8)
        XCTAssertTrue(text.contains(#"LibraryUnreadableReporter.shared.note(LibraryRootState.classify(error), site: "stranded_jobs")"#))
    }
}
