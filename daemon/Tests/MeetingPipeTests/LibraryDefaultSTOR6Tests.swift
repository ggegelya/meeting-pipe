import XCTest
@testable import MeetingPipe

/// STOR6: the library defaults moved out of `~/Documents`, an existing library at the old default
/// stays put, and the welcome step says what the configuration actually does.
@MainActor
final class LibraryDefaultSTOR6Tests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("stor6-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    // MARK: - Item 1: the defaults

    func test_the_defaults_are_outside_documents_and_no_sync_root_claims_them() throws {
        for path in [ConfigDefaults.outputDirPath, ConfigDefaults.filesystemOutputDirPath] {
            XCTAssertFalse(path.contains("Documents"), path)
            XCTAssertTrue(path.hasPrefix("~/Meetings/"), path)
            // In a scratch home whose Documents carries iCloud's attribute, the new default is
            // still not synced: it is not under Documents at all.
            let home = tempDir.appendingPathComponent("home")
            let documents = home.appendingPathComponent("Documents")
            try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
            let expanded = home.appendingPathComponent(String(path.dropFirst(2)))
            try FileManager.default.createDirectory(at: expanded, withIntermediateDirectories: true)
            XCTAssertNil(CloudSyncDetector.detect(path: expanded, home: home), path)
        }
    }

    // MARK: - Item 2: the pin

    private var lastURL: URL!

    private func store(_ toml: String?) throws -> ConfigStore {
        let url = tempDir.appendingPathComponent("config-\(UUID().uuidString).toml")
        if let toml { try toml.write(to: url, atomically: true, encoding: .utf8) }
        lastURL = url
        return ConfigStore(configURL: url)
    }

    func test_a_config_without_the_key_and_an_old_library_with_files_is_pinned() throws {
        let store = try store("[summarization]\nbackend = \"local\"\n")
        let pinned = store.pinLegacyDefaults(hasEntries: { $0 == ConfigDefaults.legacyOutputDirPath })
        XCTAssertEqual(pinned, [LibraryDefaultPin.recordings])
        XCTAssertEqual(store.outputDirPath, ConfigDefaults.legacyOutputDirPath)
        XCTAssertEqual(store.filesystemOutputDir, ConfigDefaults.filesystemOutputDirPath, "the empty one moves")
        let reread = try String(contentsOf: lastURL, encoding: .utf8)
        XCTAssertTrue(reread.contains("output_dir = \"~/Documents/Meetings/raw\""), "written into config.toml explicitly")
    }

    func test_no_old_library_leaves_the_new_default() throws {
        let store = try store("[summarization]\nbackend = \"local\"\n")
        XCTAssertEqual(store.pinLegacyDefaults(hasEntries: { _ in false }), [])
        XCTAssertEqual(store.outputDirPath, ConfigDefaults.outputDirPath)
    }

    func test_a_named_path_is_never_pinned_over() throws {
        let store = try store("[recording]\noutput_dir = \"~/Mine/raw\"\n")
        XCTAssertEqual(store.pinLegacyDefaults(hasEntries: { _ in true }).map(\.table), ["filesystem"])
        XCTAssertEqual(store.outputDirPath, "~/Mine/raw")
    }

    /// The advisor's case: one typo in config.toml makes the store run on defaults and refuse
    /// saves, so the pin cannot write; the in-memory default must still be the library the owner
    /// has, or the next recording lands in an empty new folder and the Library reads empty.
    func test_a_config_that_did_not_parse_still_records_into_the_old_library() throws {
        let url = tempDir.appendingPathComponent("broken.toml")
        try "[recording\noutput_dir = ".write(to: url, atomically: true, encoding: .utf8)
        let store = ConfigStore(configURL: url, legacyHasEntries: { $0 == ConfigDefaults.legacyOutputDirPath })
        XCTAssertNotNil(store.parseError)
        XCTAssertEqual(store.outputDirPath, ConfigDefaults.legacyOutputDirPath)
        XCTAssertTrue(store.config.recording.outputDir.path.hasSuffix("Documents/Meetings/raw"))
        XCTAssertEqual(store.filesystemOutputDir, ConfigDefaults.filesystemOutputDirPath, "an empty old default moves")
    }

    func test_with_no_old_library_a_fresh_store_reads_the_new_defaults() throws {
        let store = ConfigStore(configURL: tempDir.appendingPathComponent("absent.toml"), legacyHasEntries: { _ in false })
        XCTAssertEqual(store.outputDirPath, ConfigDefaults.outputDirPath)
        XCTAssertEqual(store.filesystemOutputDir, ConfigDefaults.filesystemOutputDirPath)
    }

    func test_the_suite_never_reads_a_real_old_library() {
        XCTAssertFalse(LibraryDefaultPin.defaultHasEntries(ConfigDefaults.legacyOutputDirPath))
    }

    func test_a_config_that_did_not_parse_is_not_written() throws {
        let store = try store("[recording\noutput_dir = ")
        XCTAssertNotNil(store.parseError)
        XCTAssertEqual(store.pinLegacyDefaults(hasEntries: { _ in true }), [])
    }

    func test_has_entries_ignores_a_lone_ds_store() throws {
        let dir = tempDir.appendingPathComponent("old")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertFalse(LibraryDefaultPin.hasEntries(dir.path))
        try Data().write(to: dir.appendingPathComponent(".DS_Store"))
        XCTAssertFalse(LibraryDefaultPin.hasEntries(dir.path))
        try Data().write(to: dir.appendingPathComponent("20260101-090000.wav"))
        XCTAssertTrue(LibraryDefaultPin.hasEntries(dir.path))
    }

    /// The pin is wiring only launch can do, so the calling is fenced: before the launch-time
    /// Config is taken from the store.
    func test_launch_pins_before_it_reads_the_config() throws {
        let app = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/MeetingPipe/App.swift"),
            encoding: .utf8
        )
        let pin = try XCTUnwrap(app.range(of: "store.pinLegacyDefaults()"))
        let config = try XCTUnwrap(app.range(of: "let config = store.config"))
        XCTAssertLessThan(pin.lowerBound, config.lowerBound)
    }

    // MARK: - Item 3: the welcome copy

    private func body(_ backend: String, regulated: Bool = false, synced: String? = nil) -> String {
        WelcomeCopy.body(
            configuredBackend: backend, regulatedMode: regulated, sinks: [],
            libraryPath: "~/Meetings/raw", syncedBy: synced
        )
    }

    func test_the_default_engine_is_named_on_the_welcome_step() {
        XCTAssertTrue(body("anthropic").contains("Anthropic"))
        XCTAssertFalse(body("local").contains("Anthropic"))
        XCTAssertFalse(body("anthropic", regulated: true).contains("sends the transcript to Anthropic"), "regulated mode clamps it")
    }

    func test_the_welcome_step_names_the_library_and_its_sync() {
        XCTAssertTrue(body("local").contains("~/Meetings/raw on this Mac"))
        XCTAssertTrue(body("local", synced: "iCloud Drive").contains("which iCloud Drive syncs"))
    }

    func test_the_welcome_step_makes_no_never_leaves_promise() {
        for text in [WelcomeCopy.title, body("anthropic"), body("local"), body("auto", synced: "Dropbox")] {
            XCTAssertFalse(text.lowercased().contains("never leave"), text)
        }
    }
}
