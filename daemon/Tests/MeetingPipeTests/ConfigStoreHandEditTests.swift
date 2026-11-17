import Combine
import XCTest
@testable import MeetingPipe

/// UX96: a hand edit to `config.toml` made while the app runs survives the next
/// Preferences save, and the store picks it up when nothing of its own is pending.
/// Before UX96 the store parsed the file once at launch and every save serialised
/// that launch-time document back, so a hand-set `modes.regulated_mode = true`
/// silently reverted on the next unrelated toggle.
final class ConfigStoreHandEditTests: XCTestCase {
    private var dir: URL!
    private var url: URL!
    private var logs: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mp-ux96-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("config.toml")
        logs = dir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        setenv("MEETINGPIPE_LOGS_DIR", logs.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("MEETINGPIPE_LOGS_DIR")
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    private let launchFile = """
    [detection]
    manual_hotkey = "ctrl+option+m"

    [modes]
    regulated_mode = false

    [obsidian]
    folder = "Meetings"
    """

    private func onDisk() throws -> String { try String(contentsOf: url, encoding: .utf8) }

    /// Rewrite the file the way an editor's atomic save does (a new inode).
    private func handEdit(_ text: String) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Change the file without replacing it (an in-place editor save).
    private func writeInPlace(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        handle.write(Data(text.utf8))
        try handle.close()
    }

    /// Make the store's writes fail: its temp file goes in this directory.
    private func lockDirectory() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
    }

    private func spin(until done: () -> Bool, timeout: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        while !done() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    private func rows(_ action: String) -> [[String: Any]] {
        let text = (try? String(contentsOf: logs.appendingPathComponent("events.jsonl"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }.filter { $0["action"] as? String == action }
    }

    // MARK: - The save re-reads before it writes

    func test_a_save_keeps_an_unmodeled_key_added_by_hand_after_launch() throws {
        try handEdit(launchFile)
        let store = ConfigStore(configURL: url)
        try handEdit(launchFile + "\ntemplate_path = \"~/vault/tpl.md\"\n")

        store.manualHotkey = "ctrl+option+k"
        try store.saveNow()

        let reread = ConfigStore(configURL: url)
        XCTAssertEqual(reread.manualHotkey, "ctrl+option+k")
        XCTAssertEqual(try onDisk().contains("template_path = \"~/vault/tpl.md\""), true)
    }

    func test_a_save_keeps_a_hand_set_regulated_mode_and_the_store_adopts_it() throws {
        try handEdit(launchFile)
        let store = ConfigStore(configURL: url)
        try handEdit(launchFile.replacingOccurrences(of: "regulated_mode = false", with: "regulated_mode = true"))

        store.manualHotkey = "ctrl+option+k"
        try store.saveNow()

        let reread = ConfigStore(configURL: url)
        XCTAssertEqual(reread.regulatedMode, true)
        XCTAssertEqual(reread.manualHotkey, "ctrl+option+k")
        XCTAssertTrue(store.regulatedMode, "the daemon acts on what the file now says, not the launch-time value")
    }

    func test_the_debounced_save_also_keeps_a_hand_set_regulated_mode() throws {
        try handEdit(launchFile)
        let store = ConfigStore(configURL: url)
        try handEdit(launchFile.replacingOccurrences(of: "regulated_mode = false", with: "regulated_mode = true"))

        let persisted = expectation(description: "debounced save landed")
        let sub = store.didPersist.sink { persisted.fulfill() }
        defer { sub.cancel() }
        store.manualHotkey = "ctrl+option+k"
        wait(for: [persisted], timeout: 3)

        let reread = ConfigStore(configURL: url)
        XCTAssertEqual(reread.regulatedMode, true)
        XCTAssertEqual(reread.manualHotkey, "ctrl+option+k")
    }

    func test_a_save_does_not_rewrite_keys_the_ui_did_not_touch() throws {
        // An integer literal on disk stays an integer: only the changed key is written.
        try handEdit("[detection]\nmanual_hotkey = \"ctrl+option+m\"\nprompt_timeout_sec = 30\n")
        let store = ConfigStore(configURL: url)
        store.manualHotkey = "ctrl+option+k"
        try store.saveNow()
        let text = try onDisk()
        XCTAssertTrue(text.contains("prompt_timeout_sec = 30"), text)
        XCTAssertFalse(text.contains("prompt_timeout_sec = 30.0"), text)
    }

    func test_the_first_save_of_a_missing_file_seeds_every_modeled_key() throws {
        let store = ConfigStore(configURL: url)
        store.manualHotkey = "ctrl+option+k"
        try store.saveNow()
        let text = try onDisk()
        XCTAssertTrue(text.contains("regulated_mode = false"), text)
        XCTAssertTrue(text.contains("mount_path = \"/Volumes/meetings\""), text)
        XCTAssertTrue(text.contains("manual_hotkey = \"ctrl+option+k\""), text)
    }

    func test_the_same_key_changed_on_disk_and_in_the_ui_writes_the_ui_value_and_logs_only_the_key() throws {
        try handEdit(launchFile)
        let store = ConfigStore(configURL: url)
        try handEdit(launchFile.replacingOccurrences(of: "ctrl+option+m", with: "cmd+shift+secret"))

        store.manualHotkey = "ctrl+option+k"
        try store.saveNow()

        XCTAssertEqual(ConfigStore(configURL: url).manualHotkey, "ctrl+option+k")
        let conflicts = rows("config_edit_conflict")
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts.first?["category"] as? String, "daemon")
        XCTAssertEqual(conflicts.first?["key"] as? String, "detection.manual_hotkey")
        let raw = (try? String(contentsOf: logs.appendingPathComponent("events.jsonl"), encoding: .utf8)) ?? ""
        XCTAssertFalse(raw.contains("secret"), "the event names the key, never a value")
        XCTAssertFalse(raw.contains("ctrl+option+k"), "the event names the key, never a value")
    }

    func test_a_key_only_the_disk_changed_is_not_a_conflict() throws {
        try handEdit(launchFile)
        let store = ConfigStore(configURL: url)
        try handEdit(launchFile.replacingOccurrences(of: "regulated_mode = false", with: "regulated_mode = true"))
        store.manualHotkey = "ctrl+option+k"
        try store.saveNow()
        XCTAssertTrue(rows("config_edit_conflict").isEmpty)
    }

    func test_a_re_read_that_does_not_parse_writes_nothing_and_sets_parse_error() throws {
        try handEdit(launchFile)
        let store = ConfigStore(configURL: url)
        try handEdit("[modes]\nregulated_mode = false\n[detection\n")
        let before = try Data(contentsOf: url)

        store.manualHotkey = "ctrl+option+k"
        XCTAssertThrowsError(try store.saveNow()) { XCTAssertTrue($0 is ConfigParseError) }

        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertNotNil(store.parseError)
        XCTAssertTrue(store.regulatedMode, "an unparsed file reads regulated (ARCH9)")
    }

    func test_a_debounced_re_read_that_does_not_parse_writes_nothing() throws {
        try handEdit(launchFile)
        let store = ConfigStore(configURL: url)
        try handEdit("[modes]\nregulated_mode = false\n[detection\n")
        let before = try Data(contentsOf: url)
        var persisted = false
        let sub = store.didPersist.sink { persisted = true }
        defer { sub.cancel() }

        store.manualHotkey = "ctrl+option+k"
        RunLoop.main.run(until: Date().addingTimeInterval(0.9))

        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertNotNil(store.parseError)
        XCTAssertTrue(store.regulatedMode)
        XCTAssertTrue(persisted, "subscribers re-read, so the regulated glyph shows the fail-closed state")
    }

    // MARK: - An outside change reloads when nothing is pending

    func test_an_outside_change_with_no_pending_save_reloads_and_notifies() throws {
        try handEdit(launchFile)
        let store = ConfigStore(configURL: url)
        try handEdit(launchFile.replacingOccurrences(of: "regulated_mode = false", with: "regulated_mode = true"))
        var persisted = 0
        let sub = store.didPersist.sink { persisted += 1 }
        defer { sub.cancel() }

        store.reloadIfChangedOnDisk()

        XCTAssertTrue(store.regulatedMode)
        XCTAssertEqual(persisted, 1)
        // A reload is not a UI edit: it schedules no save of its own.
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        XCTAssertEqual(persisted, 1)
    }

    func test_a_reload_with_a_save_pending_leaves_the_store_alone() throws {
        try handEdit(launchFile)
        let store = ConfigStore(configURL: url)
        store.manualHotkey = "ctrl+option+k"   // arms the debounce
        try handEdit(launchFile.replacingOccurrences(of: "regulated_mode = false", with: "regulated_mode = true"))

        store.reloadIfChangedOnDisk()

        XCTAssertFalse(store.regulatedMode, "the pending save's re-read takes the outside change instead")
        XCTAssertEqual(store.manualHotkey, "ctrl+option+k")
    }

    func test_the_stores_own_save_does_not_reload_itself() throws {
        try handEdit(launchFile)
        let store = ConfigStore(configURL: url)
        store.manualHotkey = "ctrl+option+k"
        try store.saveNow()
        var persisted = 0
        let sub = store.didPersist.sink { persisted += 1 }
        defer { sub.cancel() }
        var changes = 0
        let changeSub = store.objectWillChange.sink { changes += 1 }
        defer { changeSub.cancel() }

        store.reloadIfChangedOnDisk()

        XCTAssertEqual(persisted, 0)
        XCTAssertEqual(changes, 0, "no second apply over the store's own write")
    }

    func test_an_edit_inside_its_debounce_survives_a_reopen() throws {
        // ARCH9's intent, kept: an edit still inside its debounce survives Preferences reopening.
        try handEdit("[detection]\nmanual_hotkey = \"ctrl+option+m\"\n")
        let store = ConfigStore(configURL: url)
        store.manualHotkey = "ctrl+option+k"
        store.reloadIfChangedOnDisk()
        XCTAssertEqual(store.manualHotkey, "ctrl+option+k")
    }

    func test_an_edit_whose_write_failed_survives_a_reopen_when_the_file_did_not_change() throws {
        try handEdit(launchFile)
        let store = ConfigStore(configURL: url)
        try lockDirectory()
        store.manualHotkey = "ctrl+option+k"
        XCTAssertThrowsError(try store.saveNow())
        var persisted = 0
        let sub = store.didPersist.sink { persisted += 1 }
        defer { sub.cancel() }

        store.reloadIfChangedOnDisk()

        XCTAssertEqual(store.manualHotkey, "ctrl+option+k")
        XCTAssertEqual(persisted, 0, "an unchanged file is not reloaded")
    }

    func test_an_edit_whose_write_failed_survives_an_outside_change_and_still_saves() throws {
        try handEdit(launchFile)
        let store = ConfigStore(configURL: url)
        try lockDirectory()
        store.manualHotkey = "ctrl+option+k"
        XCTAssertThrowsError(try store.saveNow())
        try writeInPlace(launchFile.replacingOccurrences(of: "regulated_mode = false", with: "regulated_mode = true"))

        store.reloadIfChangedOnDisk()

        XCTAssertEqual(store.manualHotkey, "ctrl+option+k", "a reload never reverts a control under the user")
        XCTAssertTrue(store.regulatedMode, "the outside change is adopted")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try store.saveNow()
        let reread = ConfigStore(configURL: url)
        XCTAssertEqual(reread.manualHotkey, "ctrl+option+k")
        XCTAssertTrue(reread.regulatedMode)
    }

    func test_a_key_deleted_by_hand_is_not_written_back_with_its_old_value() throws {
        try handEdit(launchFile.replacingOccurrences(of: "regulated_mode = false", with: "regulated_mode = true"))
        let store = ConfigStore(configURL: url)
        XCTAssertTrue(store.regulatedMode)
        try handEdit(launchFile.replacingOccurrences(of: "regulated_mode = false\n", with: ""))

        store.manualHotkey = "ctrl+option+k"
        try store.saveNow()

        let text = try onDisk()
        XCTAssertFalse(text.contains("regulated_mode"), text)
        XCTAssertFalse(store.regulatedMode, "a missing key reads as its default")
    }

    func test_an_integer_on_disk_and_the_same_value_in_the_ui_is_not_a_conflict() throws {
        try handEdit("[detection]\nprompt_timeout_sec = 30\n")
        let store = ConfigStore(configURL: url)
        try handEdit("[detection]\nprompt_timeout_sec = 45\n")
        store.promptTimeoutSec = 45
        try store.saveNow()
        XCTAssertTrue(rows("config_edit_conflict").isEmpty)
        XCTAssertEqual(ConfigStore(configURL: url).promptTimeoutSec, 45)
    }

    func test_a_debounced_save_waits_out_a_file_caught_between_truncate_and_write() throws {
        try handEdit(launchFile)
        let store = ConfigStore(configURL: url)
        let persisted = expectation(description: "save landed")
        let sub = store.didPersist.sink { persisted.fulfill() }
        defer { sub.cancel() }

        store.manualHotkey = "ctrl+option+k"
        try writeInPlace("")   // the editor truncated...
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))   // ...the debounce fires into the gap...
        try writeInPlace(launchFile + "\ntemplate_path = \"~/vault/tpl.md\"\n")   // ...and the write lands.
        wait(for: [persisted], timeout: 3)

        let text = try onDisk()
        XCTAssertTrue(text.contains("template_path = \"~/vault/tpl.md\""), text)
        XCTAssertEqual(ConfigStore(configURL: url).manualHotkey, "ctrl+option+k")
    }

    func test_the_debounced_saves_own_write_does_not_reload_itself() throws {
        try handEdit(launchFile)
        let store = ConfigStore(configURL: url)
        var persisted = 0
        let sub = store.didPersist.sink { persisted += 1 }
        defer { sub.cancel() }
        store.manualHotkey = "ctrl+option+k"
        spin(until: { persisted == 1 })
        XCTAssertEqual(persisted, 1)
        var changes = 0
        let changeSub = store.objectWillChange.sink { changes += 1 }
        defer { changeSub.cancel() }

        store.reloadIfChangedOnDisk()

        XCTAssertEqual(persisted, 1)
        XCTAssertEqual(changes, 0)
    }

    func test_a_save_now_that_overtakes_a_queued_debounced_write_stays_the_sync_point() throws {
        try handEdit(launchFile)
        let queue = DispatchQueue(label: "test.ux96.write")
        let store = ConfigStore(configURL: url, writeQueue: queue)
        let release = DispatchSemaphore(value: 0)
        queue.async { release.wait() }

        store.manualHotkey = "cmd+shift+a"
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))   // debounced write rendered, held
        store.manualHotkey = "cmd+shift+b"
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { release.signal() }
        try store.saveNow()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))   // the stale completion runs now
        var persisted = 0
        let sub = store.didPersist.sink { persisted += 1 }
        defer { sub.cancel() }

        store.reloadIfChangedOnDisk()

        XCTAssertEqual(persisted, 0, "the file holds saveNow's bytes, which the store already synced to")
        XCTAssertEqual(store.manualHotkey, "cmd+shift+b")
    }

    func test_a_file_broken_by_hand_while_running_reads_regulated() throws {
        try handEdit(launchFile)
        let store = ConfigStore(configURL: url)
        try handEdit("[modes]\nregulated_mode = false\n[detection\n")
        store.reloadIfChangedOnDisk()
        XCTAssertNotNil(store.parseError)
        XCTAssertTrue(store.regulatedMode)
    }

    // MARK: - The watcher, and that the app starts it

    func test_the_watcher_calls_back_after_an_atomic_replace_and_an_in_place_write() throws {
        try handEdit(launchFile)
        var calls = 0
        let first = expectation(description: "atomic replace seen")
        let watcher = FileChangeWatcher(url: url, settle: 0.05) {
            calls += 1
            if calls == 1 { first.fulfill() }
        }
        watcher.start()
        defer { watcher.stop() }

        try handEdit(launchFile + "\n# replaced\n")
        wait(for: [first], timeout: 3)
        // Let any straggling event from the replace settle before counting again.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let settled = calls

        // Re-armed on the new inode: an in-place append is seen too.
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data("# appended\n".utf8))
        try handle.close()
        spin(until: { calls > settled })
        XCTAssertGreaterThan(calls, settled)
    }

    func test_the_watcher_sees_a_file_whose_directory_did_not_exist_yet() throws {
        let nested = dir.appendingPathComponent("fresh/meeting-pipe/config.toml")
        let created = expectation(description: "file under a new directory seen")
        created.assertForOverFulfill = false
        let watcher = FileChangeWatcher(url: nested, settle: 0.05) {
            if FileManager.default.fileExists(atPath: nested.path) { created.fulfill() }
        }
        watcher.start()
        defer { watcher.stop() }
        try FileManager.default.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))   // the watch walks down to the new directory
        try launchFile.write(to: nested, atomically: true, encoding: .utf8)
        wait(for: [created], timeout: 3)
    }

    func test_a_watching_store_picks_up_a_hand_set_regulated_mode() throws {
        try handEdit(launchFile)
        let store = ConfigStore(configURL: url)
        store.startWatching()
        try handEdit(launchFile.replacingOccurrences(of: "regulated_mode = false", with: "regulated_mode = true"))
        spin(until: { store.regulatedMode })
        XCTAssertTrue(store.regulatedMode)
    }

    func test_the_watcher_sees_a_file_created_after_it_started() throws {
        let created = expectation(description: "creation seen")
        let watcher = FileChangeWatcher(url: url, settle: 0.05) { created.fulfill() }
        watcher.start()
        defer { watcher.stop() }
        try handEdit(launchFile)
        wait(for: [created], timeout: 3)
    }

    func test_the_app_starts_watching_its_long_lived_store() throws {
        // END9's lesson: a watcher nobody starts is green tests over a dead feature.
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/MeetingPipe/App.swift"),
            encoding: .utf8)
        XCTAssertTrue(source.contains("store.startWatching()"))
    }
}
