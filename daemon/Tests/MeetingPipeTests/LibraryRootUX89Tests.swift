import XCTest
@testable import MeetingPipe

/// UX89: the library root is changed only by a confirmed move or a confirmed switch, the Library
/// follows the change without a relaunch, and a missing root is named rather than shown as a first
/// run. Every test runs on a temp library; nothing touches the real config or recordings.
@MainActor
final class LibraryRootUX89Tests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mp-ux89-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    // MARK: Fixtures

    private let stems = ["20260301-100000", "20260302-100000", "20260303-100000"]

    /// A library of finished meetings: recording, transcript with its measured length, summary.
    private func makeLibrary(_ name: String) throws -> URL {
        let lib = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        // Old enough that no stem reads as a meeting the pipeline still owns.
        for stem in stems {
            try Data().write(to: lib.appendingPathComponent("\(stem).wav"))
            try Data(#"{"audio_seconds": 60, "segments": []}"#.utf8)
                .write(to: lib.appendingPathComponent("\(stem).json"))
            try Data(#"{"title": "Meeting \#(stem)"}"#.utf8)
                .write(to: lib.appendingPathComponent("\(stem).summary.json"))
            try Data("Budget review \(stem)\n".utf8).write(to: lib.appendingPathComponent("\(stem).md"))
        }
        return lib
    }

    private func configStore(outputDir: URL) throws -> ConfigStore {
        let url = base.appendingPathComponent("config.toml")
        try Data("[recording]\noutput_dir = \"\(outputDir.path)\"\n".utf8).write(to: url)
        return ConfigStore(configURL: url)
    }

    private func statsStore(_ config: ConfigStore) -> StorageStatsStore {
        StorageStatsStore(
            configStore: config,
            workflowStore: WorkflowStore(directory: base.appendingPathComponent("workflows", isDirectory: true)),
            hubRoot: base.appendingPathComponent("hub", isDirectory: true)
        )
    }

    private func until(
        _ what: String, timeout: TimeInterval = 5, _ predicate: () -> Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() > deadline {
                XCTFail("timed out waiting for \(what)", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: The Recording pane

    private func daemonSource(_ relative: String) throws -> String {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MeetingPipeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // daemon
            .appendingPathComponent("Sources/MeetingPipe")
        return try String(contentsOf: sources.appendingPathComponent(relative), encoding: .utf8)
    }

    /// The defect: a `TextField` bound to `outputDirPath` saved a half-typed path 0.5 s after a
    /// keystroke. The pane keeps another `TextField` (the bundle-id entry), so the fence names the
    /// binding, not the control.
    func test_no_pane_binds_a_text_field_to_the_library_root() throws {
        for pane in ["Preferences/PreferencesView+Recording.swift", "Preferences/PreferencesView+Storage.swift"] {
            let text = try daemonSource(pane)
            XCTAssertFalse(text.contains("$store.outputDirPath"), "\(pane) must not bind the library root to an editable control")
            XCTAssertTrue(text.contains("LibraryRootButtons(stats: stats"), "\(pane) offers Move library and Use another folder")
            XCTAssertTrue(text.contains(".libraryRootDialogs(stats)"), "\(pane) confirms both actions")
        }
    }

    /// The re-root only works if something calls it: the Coordinator's start wires the
    /// `output_dir` subscription, and the subscription re-roots the Library's own store.
    func test_the_coordinator_wires_the_library_root_subscription() throws {
        let coordinator = try daemonSource("Coordinator.swift")
        XCTAssertTrue(coordinator.contains("        wireLibraryRoot()\n"), "start() wires the subscription")
        let wiring = try daemonSource("Coordinator+LibraryRoot.swift")
        XCTAssertTrue(wiring.contains("libraryRootCancellable = libraryModel.meetingStore.follow(configStore)"))
        XCTAssertFalse(coordinator.contains("a live\n        // change needs a daemon restart"), "the stale init-time comment is gone")
    }

    /// The advisor-found hole: a `config.toml` broken by hand reloads as defaults, and following that
    /// value re-rooted a moved library onto the creatable default path.
    func test_a_config_that_fails_to_parse_does_not_re_root_the_library() async throws {
        let lib = try makeLibrary("raw")
        let config = try configStore(outputDir: lib)
        let store = MeetingStore(recordingsDir: lib)
        let follow = store.follow(config)
        defer { follow.cancel() }

        try Data("[recording\noutput_dir = = broken".utf8).write(to: base.appendingPathComponent("config.toml"))
        config.reloadIfChangedOnDisk()
        XCTAssertNotNil(config.parseError)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(store.recordingsDir.standardizedFileURL, lib.standardizedFileURL)

        // A real change after the fix still follows.
        let other = base.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("[recording]\noutput_dir = \"\(other.path)\"\n".utf8).write(to: base.appendingPathComponent("config.toml"))
        config.reloadIfChangedOnDisk()
        await until("re-rooted") { store.recordingsDir.standardizedFileURL == other.standardizedFileURL }
    }

    // MARK: Use another folder

    func test_use_another_folder_writes_the_path_only_after_confirm() async throws {
        let lib = try makeLibrary("raw")
        let other = base.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let config = try configStore(outputDir: lib)
        let stats = statsStore(config)

        await stats.requestSwitch(to: other)
        XCTAssertEqual(stats.pendingSwitch, other)
        XCTAssertEqual(config.outputDirPath, lib.path, "the pick alone writes nothing")
        let onDisk = try String(contentsOf: base.appendingPathComponent("config.toml"), encoding: .utf8)
        XCTAssertTrue(onDisk.contains(lib.path))

        stats.cancelSwitch()
        XCTAssertNil(stats.pendingSwitch)
        XCTAssertEqual(config.outputDirPath, lib.path, "a cancel writes nothing")

        await stats.requestSwitch(to: other)
        await stats.confirmSwitch()
        XCTAssertEqual(config.outputDirPath, other.path)
        let saved = try String(contentsOf: base.appendingPathComponent("config.toml"), encoding: .utf8)
        XCTAssertTrue(saved.contains(other.path), "a confirmed switch is saved at once, not on the debounce")
        XCTAssertTrue(FileManager.default.fileExists(atPath: lib.appendingPathComponent("\(stems[0]).wav").path),
                      "nothing is moved")
    }

    func test_switch_message_says_the_current_library_stays_put() {
        let message = LibraryRootCopy.switchMessage(
            current: URL(fileURLWithPath: "/a/raw"), next: URL(fileURLWithPath: "/b/raw")
        )
        XCTAssertTrue(message.contains("/a/raw"))
        XCTAssertTrue(message.contains("/b/raw"))
        XCTAssertTrue(message.contains("stays where it is"))
    }

    // MARK: Refused while in flight

    func test_move_and_switch_are_refused_while_a_recording_is_live() async throws {
        let lib = try makeLibrary("raw")
        // A capture intermediate written just now is a live recording.
        try Data([1, 2, 3]).write(to: lib.appendingPathComponent("20260304-100000.mic.wav"))
        let config = try configStore(outputDir: lib)
        let stats = statsStore(config)
        let dest = base.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        await stats.requestMove(to: dest)
        XCTAssertNil(stats.pendingMove, "Move library uses LibraryMover.plan, which refuses a live recording")
        XCTAssertEqual(stats.moveError, LibraryMover.MoveError.busy("a recording is in progress").localizedDescription)

        await stats.requestSwitch(to: dest)
        XCTAssertNil(stats.pendingSwitch)
        XCTAssertEqual(stats.moveError, LibraryMover.MoveError.busy("a recording is in progress").localizedDescription)
        XCTAssertEqual(config.outputDirPath, lib.path)
    }

    // MARK: Missing root

    func test_a_missing_root_is_named_not_shown_as_a_first_run() async throws {
        let missing = base.appendingPathComponent("typo", isDirectory: true)
        let store = MeetingStore(recordingsDir: missing)
        store.start()
        defer { store.stop() }
        await until("first scan") { store.hasLoadedOnce }

        XCTAssertEqual(store.rootState, .missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path),
                       "a root that is not the first-run default is never created to hide the real library")
        XCTAssertEqual(
            LibraryListPlaceholder.decide(
                hasLoadedOnce: store.hasLoadedOnce, isEmpty: store.meetings.isEmpty,
                rootState: store.rootState, root: store.recordingsDir
            ),
            .missingRoot(path: (missing.path as NSString).abbreviatingWithTildeInPath)
        )
    }

    func test_the_first_run_default_is_still_created_and_shows_the_first_run_state() async throws {
        let fresh = base.appendingPathComponent("Meetings/raw", isDirectory: true)
        let store = MeetingStore(recordingsDir: fresh, creatableRoot: fresh)
        store.start()
        defer { store.stop() }
        await until("first scan") { store.hasLoadedOnce }

        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertTrue(store.isWatching)
        XCTAssertEqual(store.rootState, .readable)
        XCTAssertEqual(
            LibraryListPlaceholder.decide(hasLoadedOnce: true, isEmpty: true, rootState: store.rootState, root: fresh),
            .firstRun
        )
    }

    func test_placeholder_decision() {
        let root = URL(fileURLWithPath: "/x/raw")
        XCTAssertEqual(LibraryListPlaceholder.decide(hasLoadedOnce: false, isEmpty: true, rootState: .missing, root: root), .loading)
        XCTAssertEqual(LibraryListPlaceholder.decide(hasLoadedOnce: true, isEmpty: false, rootState: .readable, root: root), .none)
        XCTAssertEqual(LibraryListPlaceholder.decide(hasLoadedOnce: true, isEmpty: true, rootState: .readable, root: root), .firstRun)
        XCTAssertEqual(LibraryListPlaceholder.decide(hasLoadedOnce: true, isEmpty: true, rootState: .missing, root: root), .missingRoot(path: "/x/raw"))
    }

    func test_creation_rule() {
        let def = URL(fileURLWithPath: "/h/Documents/Meetings/raw")
        XCTAssertTrue(LibraryRootState.mayCreate(root: def, creatableRoot: def, departed: [], exists: false))
        XCTAssertFalse(LibraryRootState.mayCreate(root: def, creatableRoot: def, departed: [def], exists: false),
                       "a root the library was moved out of is never recreated")
        XCTAssertFalse(LibraryRootState.mayCreate(root: URL(fileURLWithPath: "/h/typo"), creatableRoot: def, departed: [], exists: false))
        XCTAssertFalse(LibraryRootState.mayCreate(root: def, creatableRoot: nil, departed: [], exists: false))
        XCTAssertFalse(LibraryRootState.mayCreate(root: def, creatableRoot: def, departed: [], exists: true))
    }

    /// F058's second acceptance line, on the pre-UX89 shape: a store whose root was moved away, then
    /// stopped and started (the Library closed and reopened), used to recreate the empty folder.
    func test_a_store_whose_root_was_moved_away_never_recreates_it() async throws {
        let lib = try makeLibrary("raw")
        let store = MeetingStore(recordingsDir: lib)
        store.start()
        await until("first scan") { store.hasLoadedOnce }
        store.stop()
        try FileManager.default.moveItem(at: lib, to: base.appendingPathComponent("moved", isDirectory: true))

        store.start()
        defer { store.stop() }
        store.refresh()
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lib.path))
    }

    // MARK: The Library follows the root (F058)

    func test_a_confirmed_move_re_roots_the_library_and_keeps_the_index_and_durations() async throws {
        let lib = try makeLibrary("raw")
        let cacheURL = base.appendingPathComponent("durations.json")
        let store = MeetingStore(recordingsDir: lib, durationCacheURL: cacheURL, creatableRoot: lib)
        let indexer = SearchIndexer(store: store, indexURL: base.appendingPathComponent("index.sqlite"))
        store.start()
        await until("first scan") { store.hasLoadedOnce && store.meetings.count == 3 }
        await until("index built") { indexer.health == .ready && indexer.matchingStems("budget")?.count == 3 }

        let config = try configStore(outputDir: lib)
        let stats = statsStore(config)
        let destParent = base.appendingPathComponent("local", isDirectory: true)
        try FileManager.default.createDirectory(at: destParent, withIntermediateDirectories: true)
        await stats.requestMove(to: destParent)
        let plan = try XCTUnwrap(stats.pendingMove, "move refused: \(stats.moveError ?? "?")")
        await stats.executeMove(plan)
        XCTAssertEqual(config.outputDirPath, plan.destination.path)
        // What `Coordinator.wireLibraryRoot`'s `$outputDirPath` sink does with that value.
        store.reroot(to: URL(fileURLWithPath: config.outputDirPath))

        // The Library closes and reopens.
        store.stop()
        store.start()
        defer { store.stop() }
        await until("re-rooted scan") {
            store.hasLoadedOnce && store.meetings.count == 3
                && store.meetings.allSatisfy { $0.recordingsDir.standardizedFileURL == plan.destination.standardizedFileURL }
        }
        indexer.waitForQueuedReconciles()
        try? await Task.sleep(nanoseconds: 200_000_000)
        indexer.waitForQueuedReconciles()

        XCTAssertFalse(FileManager.default.fileExists(atPath: lib.path), "the moved-away folder is not recreated")
        for meeting in store.meetings {
            XCTAssertEqual(meeting.audioURL?.deletingLastPathComponent().standardizedFileURL,
                           plan.destination.standardizedFileURL, "no row is served from the old root's cache")
        }
        XCTAssertEqual(store.recordingsDir.standardizedFileURL, plan.destination.standardizedFileURL)
        XCTAssertEqual(indexer.matchingStems("budget")?.count, 3, "the search index still holds every stem")
        let cache = MeetingDurationCache.load(from: cacheURL)
        XCTAssertEqual(Set(cache.entries.keys), Set(stems), "the duration cache still has every stem")
    }

    func test_a_scan_of_the_old_root_in_flight_never_publishes_after_a_re_root() async throws {
        let old = try makeLibrary("old")
        let new = base.appendingPathComponent("new", isDirectory: true)
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        let store = MeetingStore(recordingsDir: old)
        // Hold the scan queue so the old root's scan is in flight when the re-root lands.
        let gate = DispatchSemaphore(value: 0)
        store.enqueueOnScanQueue { gate.wait() }
        store.refresh()
        store.reroot(to: new)
        gate.signal()
        await until("re-rooted scan") { store.hasLoadedOnce }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(store.meetings.isEmpty, "the new root is empty; the old root's rows must not land")
        XCTAssertEqual(store.rootState, .readable)
    }
}
