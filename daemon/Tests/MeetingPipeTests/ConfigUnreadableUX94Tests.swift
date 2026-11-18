import XCTest
@testable import MeetingPipe

/// UX94: a config.toml that does not parse is said outside Preferences (an event, a menu row, a
/// Finish setup item), the pipeline's failure names the line, and the recordings folder does not
/// silently move to the default (F056).
final class ConfigUnreadableUX94Tests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mp-ux94-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private final class Memory {
        var value: String?
        var store: ConfigStore.LastGoodOutputDir {
            ConfigStore.LastGoodOutputDir(get: { self.value }, set: { self.value = $0 })
        }
    }

    private func write(_ text: String) throws -> URL {
        let url = dir.appendingPathComponent("config.toml")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - The failure cause

    func test_the_config_cause_decodes_from_the_golden_fixture() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "failure-metadata-golden", withExtension: "json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let cases = try XCTUnwrap(object["cases"] as? [[String: Any]])
        let config = try XCTUnwrap(cases.first { $0["name"] as? String == "config" })
        let payload = try JSONSerialization.data(withJSONObject: config["payload"] as Any)
        let decoded = try XCTUnwrap(FailureMetadata.decode(payload))
        XCTAssertEqual(decoded.cause, .config)
        XCTAssertEqual(decoded.remedy, "config")
    }

    func test_the_presentation_names_the_line_and_opens_preferences() {
        let metadata = FailureMetadata(cause: .config, operation: .summary, remedy: "config")
        let failure = FailurePresentation(
            diagnostics: "mp.config.ConfigUnreadableError: config.toml does not parse at line 2, column 1.",
            operation: .summary, metadata: metadata
        )
        XCTAssertEqual(failure.title, "Settings file has a syntax error")
        XCTAssertEqual(failure.explanation, "Fix line 2 of config.toml, then retry.")
        XCTAssertEqual(failure.settingsLabel, "Open Preferences")
    }

    func test_a_bad_value_names_its_key() {
        XCTAssertEqual(FailurePresentation.configFix("config.toml has an invalid `summarization.max_tokens` setting."),
                       "Check the summarization.max_tokens setting in config.toml, then retry.")
        XCTAssertEqual(FailurePresentation.configFix("nothing useful"), "Fix config.toml, then retry.")
    }

    // MARK: - The menu row and the Finish setup item

    func test_the_menu_row_appears_only_while_the_file_does_not_parse() {
        XCTAssertFalse(StatusBarModel.rows(.init()).contains { if case .configUnreadable = $0 { return true }; return false })
        let rows = StatusBarModel.rows(.init(configUnreadable: .syntaxError))
        XCTAssertTrue(rows.contains(.configUnreadable(title: "⚠ Settings file has a syntax error - open Preferences")))
        let paused = StatusBarModel.rows(.init(configUnreadable: .recordingsPaused))
        XCTAssertTrue(paused.contains(.configUnreadable(
            title: "⚠ Settings file cannot be read - recordings paused until it is fixed")))
    }

    func test_finish_setup_lists_the_settings_file_first() {
        XCTAssertEqual(SetupChecklist.decide(.init(configUnreadable: true)).first, .configUnreadable)
        XCTAssertEqual(SetupChecklist.Item.configUnreadable.fix, .preferences)
        XCTAssertFalse(SetupChecklist.decide(.init()).contains(.configUnreadable))
    }

    // MARK: - F056: the recordings folder does not move to the default

    func test_a_broken_file_keeps_the_last_parsed_output_dir() throws {
        let memory = Memory()
        let url = try write("[recording]\noutput_dir = \"~/Elsewhere/raw\"\n")
        let good = ConfigStore(configURL: url, legacyHasEntries: { _ in false }, lastGoodOutputDir: memory.store)
        XCTAssertEqual(good.outputDirPath, "~/Elsewhere/raw")
        XCTAssertEqual(memory.value, "~/Elsewhere/raw")

        _ = try write("[recording\noutput_dir = ")
        let broken = ConfigStore(configURL: url, legacyHasEntries: { _ in false }, lastGoodOutputDir: memory.store)
        XCTAssertNotNil(broken.parseError)
        XCTAssertEqual(broken.outputDirPath, "~/Elsewhere/raw")
        XCTAssertFalse(broken.recordingRootUnknown)
        XCTAssertEqual(memory.value, "~/Elsewhere/raw", "a broken file never overwrites the memory")
    }

    func test_with_nothing_remembered_and_no_old_library_a_start_is_refused() throws {
        let memory = Memory()
        let url = try write("[recording\noutput_dir = ")
        let store = ConfigStore(configURL: url, legacyHasEntries: { _ in false }, lastGoodOutputDir: memory.store)
        XCTAssertTrue(store.recordingRootUnknown)

        // A later file that parses clears both.
        _ = try write("[recording]\noutput_dir = \"~/Back/raw\"\n")
        store.reloadIfChangedOnDisk()
        XCTAssertNil(store.parseError)
        XCTAssertFalse(store.recordingRootUnknown)
        XCTAssertEqual(store.outputDirPath, "~/Back/raw")
    }

    /// PIPE42: the file parses but its regulated switch is wrong. Its own `output_dir` is the library,
    /// not the memory or a default, and nothing is refused.
    func test_a_file_that_parses_but_cannot_be_trusted_keeps_its_own_output_dir() throws {
        let memory = Memory()
        memory.value = "~/Remembered/raw"
        let url = try write("[recording]\noutput_dir = \"~/Named/raw\"\n[modes]\nregulated_mode = \"true\"\n")
        let store = ConfigStore(configURL: url, legacyHasEntries: { _ in false }, lastGoodOutputDir: memory.store)
        XCTAssertNotNil(store.parseError?.summary, "a PIPE42 refusal, not a syntax error")
        XCTAssertEqual(store.outputDirPath, "~/Named/raw")
        XCTAssertFalse(store.recordingRootUnknown)
        XCTAssertEqual(memory.value, "~/Remembered/raw", "an untrusted file is not remembered")
        XCTAssertEqual(StatusBarModel.configUnreadableTitle(.cannotBeTrusted),
                       "⚠ Settings file needs fixing - open Preferences")
    }

    func test_with_nothing_remembered_stor6s_old_library_is_still_used() throws {
        let url = try write("[recording\noutput_dir = ")
        let store = ConfigStore(configURL: url, legacyHasEntries: { $0 == ConfigDefaults.legacyOutputDirPath },
                                lastGoodOutputDir: Memory().store)
        XCTAssertEqual(store.outputDirPath, ConfigDefaults.legacyOutputDirPath)
        XCTAssertFalse(store.recordingRootUnknown)
    }
}
