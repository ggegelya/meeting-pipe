import Combine
import XCTest
@testable import MeetingPipe

/// UX91: a Preferences change that fails to reach `config.toml` (or the Keychain) used to
/// go only to os.Logger, so the control kept the new value while the pipeline ran on the
/// old one and nothing said so. The failure is now published, shown above every pane and
/// in the menu, and written to the event log without a value.
final class SettingSaveFailureTests: XCTestCase {
    private var dir: URL!
    private var logs: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mp-ux91-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        logs = dir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        setenv("MEETINGPIPE_LOGS_DIR", logs.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("MEETINGPIPE_LOGS_DIR")
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    private func rows(_ action: String) -> [[String: Any]] {
        let text = (try? String(contentsOf: logs.appendingPathComponent("events.jsonl"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }.filter { $0["action"] as? String == action }
    }

    /// A config path whose parent is a regular file, so `createDirectory` throws on every save
    /// until `unblock()` removes it.
    private func blockedConfig() throws -> (url: URL, unblock: () throws -> Void) {
        let blocker = dir.appendingPathComponent("meeting-pipe")
        try Data("not a directory".utf8).write(to: blocker)
        let url = blocker.appendingPathComponent("config.toml")
        return (url, { try FileManager.default.removeItem(at: blocker) })
    }

    // MARK: - ConfigStore

    func test_save_now_that_cannot_write_sets_save_error_and_a_later_save_clears_it() throws {
        let (url, unblock) = try blockedConfig()
        let store = ConfigStore(configURL: url)
        var persisted = 0
        let sub = store.didPersist.sink { persisted += 1 }
        defer { sub.cancel() }

        store.manualHotkey = "ctrl+option+k"
        XCTAssertThrowsError(try store.saveNow())

        let failure = try XCTUnwrap(store.saveError)
        XCTAssertEqual(failure.store, .config)
        XCTAssertFalse(failure.reason.isEmpty)
        XCTAssertEqual(persisted, 0)
        XCTAssertEqual(store.manualHotkey, "ctrl+option+k", "the control keeps the new value")

        try unblock()
        try store.saveNow()
        XCTAssertNil(store.saveError)
        XCTAssertEqual(persisted, 1)
    }

    func test_a_debounced_save_that_cannot_write_sets_save_error_without_did_persist() throws {
        let (url, unblock) = try blockedConfig()
        let store = ConfigStore(configURL: url)
        var persisted = 0
        let sub = store.didPersist.sink { persisted += 1 }
        defer { sub.cancel() }

        store.manualHotkey = "ctrl+option+k"
        let deadline = Date().addingTimeInterval(3)
        while store.saveError == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertNotNil(store.saveError)
        XCTAssertEqual(persisted, 0)

        try unblock()
        store.manualHotkey = "ctrl+option+j"   // the next edit retries
        let cleared = Date().addingTimeInterval(3)
        while persisted == 0 && Date() < cleared { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertEqual(persisted, 1)
        XCTAssertNil(store.saveError)
    }

    func test_a_failed_config_save_is_one_event_with_no_value() throws {
        let (url, _) = try blockedConfig()
        let store = ConfigStore(configURL: url)
        store.manualHotkey = "ctrl+option+secret"
        XCTAssertThrowsError(try store.saveNow())

        let events = rows("config_save_failed")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?["category"] as? String, "daemon")
        XCTAssertEqual(events.first?["store"] as? String, "config")
        XCTAssertNotNil(events.first?["domain"] as? String)
        XCTAssertNotNil(events.first?["code"] as? Int)
        let raw = (try? String(contentsOf: logs.appendingPathComponent("events.jsonl"), encoding: .utf8)) ?? ""
        XCTAssertFalse(raw.contains("secret"))
    }

    func test_a_failed_debounced_write_that_completes_after_a_successful_save_now_raises_no_banner() throws {
        let configDir = dir.appendingPathComponent("cfg", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let url = configDir.appendingPathComponent("config.toml")
        try "[detection]\nmanual_hotkey = \"ctrl+option+m\"\n".write(to: url, atomically: true, encoding: .utf8)
        let queue = DispatchQueue(label: "test.ux91.write")
        let store = ConfigStore(configURL: url, writeQueue: queue)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: configDir.path) }

        let release = DispatchSemaphore(value: 0)
        queue.async { release.wait() }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: configDir.path)
        store.manualHotkey = "cmd+shift+a"
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))   // write A rendered, held; it will fail
        queue.async {   // between A and B, the folder becomes writable again
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: configDir.path)
        }
        store.manualHotkey = "cmd+shift+b"
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { release.signal() }
        try store.saveNow()   // B lands
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))   // A's failure reaches main afterwards

        XCTAssertNil(store.saveError, "the file holds B; a stale failure must not raise the banner")
        XCTAssertEqual(rows("config_save_failed").count, 1, "A's failure is still recorded")
    }

    func test_a_file_broken_by_hand_after_a_failed_save_drops_the_banner() throws {
        let configDir = dir.appendingPathComponent("cfg2", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let url = configDir.appendingPathComponent("config.toml")
        try "[detection]\nmanual_hotkey = \"ctrl+option+m\"\n".write(to: url, atomically: true, encoding: .utf8)
        let store = ConfigStore(configURL: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: configDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: configDir.path) }
        store.manualHotkey = "ctrl+option+k"
        XCTAssertThrowsError(try store.saveNow())
        XCTAssertNotNil(store.saveError)

        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        handle.write(Data("[detection\n".utf8))
        try handle.close()
        store.reloadIfChangedOnDisk()

        XCTAssertNotNil(store.parseError)
        XCTAssertNil(store.saveError, "the unsaved change went with the reload; the parse-error pane speaks now")
    }

    // MARK: - The banner and the menu row

    func test_the_banner_is_absent_with_no_failure_and_names_the_reason_otherwise() {
        XCTAssertNil(SettingsSaveBanner.Model.make(config: nil, keychain: nil))

        let config = SettingSaveFailure(store: .config, reason: "the disk is full", at: Date())
        let model = SettingsSaveBanner.Model.make(config: config, keychain: nil)
        XCTAssertEqual(model?.message, "Your last change was not saved: the disk is full")
        XCTAssertEqual(model?.offersReveal, true)

        let keychain = SettingSaveFailure(store: .keychain, reason: "the Keychain refused to store NOTION_TOKEN", at: Date())
        let keychainOnly = SettingsSaveBanner.Model.make(config: nil, keychain: keychain)
        XCTAssertEqual(keychainOnly?.message, "Your last change was not saved: the Keychain refused to store NOTION_TOKEN")
        XCTAssertEqual(keychainOnly?.offersReveal, false, "there is no file to reveal for a Keychain item")

        let both = SettingsSaveBanner.Model.make(config: config, keychain: keychain)
        XCTAssertEqual(both?.message, "Your last change was not saved: the disk is full", "the file is named first")
        XCTAssertEqual(both?.offersReveal, true)
    }

    func test_the_banner_sits_above_every_pane() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/MeetingPipe/Preferences/PreferencesView.swift"),
            encoding: .utf8)
        let detail = try XCTUnwrap(source.range(of: "private var detailContent: some View {"))
        let body = source[detail.upperBound...]
        // In the branch that shows the panes, not the parse-error one, and ahead of them.
        let elseBranch = try XCTUnwrap(body.range(of: "} else {"))
        let banner = try XCTUnwrap(body.range(of: "SettingsSaveBanner("))
        let pane = try XCTUnwrap(body.range(of: "paneContent"))
        XCTAssertLessThan(elseBranch.lowerBound, banner.lowerBound)
        XCTAssertLessThan(banner.lowerBound, pane.lowerBound)
    }

    func test_the_menu_shows_one_unsaved_setting_row_only_while_a_save_failed() {
        let off = StatusBarModel.rows(StatusBarModel.Inputs(unsavedSetting: false))
        XCTAssertFalse(off.contains { if case .unsavedSetting = $0 { return true } else { return false } })

        let on = StatusBarModel.rows(StatusBarModel.Inputs(unsavedSetting: true))
        XCTAssertEqual(on.filter { if case .unsavedSetting = $0 { return true } else { return false } }.count, 1)
        XCTAssertTrue(on.contains(.unsavedSetting(title: "⚠ A setting was not saved - open Preferences")))
    }
}
