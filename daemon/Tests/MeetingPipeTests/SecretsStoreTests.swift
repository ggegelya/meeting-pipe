import XCTest
@testable import MeetingPipe

/// SecretsStore now backs the API tokens with the macOS Keychain (SEC8, subsumes SEC1). Two things need
/// protection:
///
///   1. The published values round-trip through the injected backend, and clearing a field removes the item.
///   2. The one-time migration off the legacy plaintext secrets.env moves only the managed keys, never
///      overwrites a value already in the Keychain, and deletes the file afterward.
///
/// An in-memory `SecretsBackend` stands in for the real Keychain so the suite never shells out to `security`.
final class SecretsStoreTests: XCTestCase {

    /// Records every call so a test can say exactly what a save wrote. `unreadable` accounts read as a
    /// failed read; `failSet` accounts throw on set; `failRemove` ones throw on remove.
    private final class InMemorySecretsBackend: SecretsBackend {
        private let lock = NSLock()
        private var _store: [String: String]
        private var _sets: [String] = []
        private var _removes: [String] = []
        private var _callThreadsOnMain: [Bool] = []
        var unreadable: Set<String> = []
        var failSet: Set<String> = []
        var failRemove: Set<String> = []
        var unquotableSet: Set<String> = []
        /// Sleeps this long inside each `set`, standing in for a slow `security`.
        var setDelay: TimeInterval = 0
        var store: [String: String] { lock.lock(); defer { lock.unlock() }; return _store }
        var sets: [String] { lock.lock(); defer { lock.unlock() }; return _sets }
        var removes: [String] { lock.lock(); defer { lock.unlock() }; return _removes }
        /// Whether each backend call (set or remove) ran on the main thread.
        var callThreadsOnMain: [Bool] { lock.lock(); defer { lock.unlock() }; return _callThreadsOnMain }
        init(_ initial: [String: String] = [:]) { self._store = initial }
        func value(for account: String) -> SecretRead {
            if unreadable.contains(account) { return .unreadable(status: 36, detail: "locked") }
            return store[account].map { .found($0) } ?? .notFound
        }
        func stored(_ account: String) -> String? { store[account] }
        func set(_ value: String, for account: String) throws {
            if setDelay > 0 { Thread.sleep(forTimeInterval: setDelay) }
            lock.lock(); defer { lock.unlock() }
            _sets.append(account)
            _callThreadsOnMain.append(Thread.isMainThread)
            if unquotableSet.contains(account) { throw KeychainBackend.KeychainError.unquotable }
            if failSet.contains(account) { throw KeychainBackend.KeychainError.commandFailed("boom", status: 36) }
            _store[account] = value
        }
        func remove(_ account: String) throws {
            lock.lock(); defer { lock.unlock() }
            _removes.append(account)
            _callThreadsOnMain.append(Thread.isMainThread)
            if failRemove.contains(account) { throw KeychainBackend.KeychainError.commandFailed("boom") }
            _store.removeValue(forKey: account)
        }
    }

    private func makeTempSecretsURL() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mp-secrets-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("secrets.env")
    }

    // MARK: - Store round-trip

    func test_defaults_empty_when_backend_empty() {
        let store = SecretsStore(backend: InMemorySecretsBackend())
        XCTAssertEqual(store.anthropicAPIKey, "")
        XCTAssertEqual(store.notionToken, "")
    }

    func test_loads_values_from_backend() {
        let backend = InMemorySecretsBackend(["ANTHROPIC_API_KEY": "sk-x", "NOTION_TOKEN": "ntn-y"])
        let store = SecretsStore(backend: backend)
        XCTAssertEqual(store.anthropicAPIKey, "sk-x")
        XCTAssertEqual(store.notionToken, "ntn-y")
    }

    func test_save_writes_through_to_backend() throws {
        let backend = InMemorySecretsBackend()
        let store = SecretsStore(backend: backend)
        store.anthropicAPIKey = "sk-new"
        store.notionToken = "ntn-new"
        try store.saveNow()
        XCTAssertEqual(backend.stored("ANTHROPIC_API_KEY"), "sk-new")
        XCTAssertEqual(backend.stored("NOTION_TOKEN"), "ntn-new")
    }

    /// OBS5: a landed save names the account and whether it holds a value, never the value.
    func test_secret_saved_names_the_account_and_never_the_secret() throws {
        let logs = FileManager.default.temporaryDirectory.appendingPathComponent("obs5-secret-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        setenv("MEETINGPIPE_LOGS_DIR", logs.path, 1)
        defer { unsetenv("MEETINGPIPE_LOGS_DIR"); try? FileManager.default.removeItem(at: logs) }
        let store = SecretsStore(backend: InMemorySecretsBackend())
        store.anthropicAPIKey = "sk-placeholder-secret"
        try store.saveNow()
        let raw = try String(contentsOf: logs.appendingPathComponent("events.jsonl"), encoding: .utf8)
        let row = try XCTUnwrap(raw.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }.first { $0["action"] as? String == "secret_saved" })
        XCTAssertEqual(row["account"] as? String, "ANTHROPIC_API_KEY")
        XCTAssertEqual(row["set"] as? Bool, true)
        XCTAssertFalse(raw.contains("sk-placeholder-secret"))
    }

    func test_openai_key_round_trips() throws {
        // PROV1: the openai backend's key is a first-class managed secret.
        let backend = InMemorySecretsBackend(["OPENAI_API_KEY": "sk-openai-loaded"])
        let store = SecretsStore(backend: backend)
        XCTAssertEqual(store.openaiAPIKey, "sk-openai-loaded")
        store.openaiAPIKey = "sk-openai-new"
        try store.saveNow()
        XCTAssertEqual(backend.stored("OPENAI_API_KEY"), "sk-openai-new")
        store.openaiAPIKey = ""
        try store.saveNow()
        XCTAssertNil(backend.stored("OPENAI_API_KEY"))
    }

    func test_clearing_a_value_removes_the_item() throws {
        // Blanking a field in Preferences should delete the Keychain item, not store an empty string.
        let backend = InMemorySecretsBackend(["ANTHROPIC_API_KEY": "sk-old", "NOTION_TOKEN": "ntn-keep"])
        let store = SecretsStore(backend: backend)
        store.anthropicAPIKey = ""
        try store.saveNow()
        XCTAssertNil(backend.stored("ANTHROPIC_API_KEY"))
        XCTAssertEqual(backend.stored("NOTION_TOKEN"), "ntn-keep")
    }

    func test_whitespace_only_value_is_treated_as_absent() throws {
        let backend = InMemorySecretsBackend(["ANTHROPIC_API_KEY": "sk-old"])
        let store = SecretsStore(backend: backend)
        store.anthropicAPIKey = "   "
        try store.saveNow()
        XCTAssertNil(backend.stored("ANTHROPIC_API_KEY"))
    }

    // MARK: - Legacy secrets.env migration (SEC8)

    func test_migration_moves_managed_keys_and_deletes_file() throws {
        let url = try makeTempSecretsURL()
        try """
        ANTHROPIC_API_KEY=sk-a
        NOTION_TOKEN=ntn-b
        HF_TOKEN=hf-c
        # a comment
        UNMANAGED=whatever
        """.write(to: url, atomically: true, encoding: .utf8)

        let backend = InMemorySecretsBackend()
        XCTAssertTrue(SecretsStore.migrateEnvFileIfPresent(at: url, backend: backend))

        XCTAssertEqual(backend.stored("ANTHROPIC_API_KEY"), "sk-a")
        XCTAssertEqual(backend.stored("NOTION_TOKEN"), "ntn-b")
        XCTAssertEqual(backend.stored("HF_TOKEN"), "hf-c")
        // Only the managed keys move; a user-added key is not silently absorbed.
        XCTAssertNil(backend.stored("UNMANAGED"))
        // The plaintext file is gone once migrated.
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func test_migration_does_not_overwrite_existing_keychain_value() throws {
        let url = try makeTempSecretsURL()
        try "ANTHROPIC_API_KEY=sk-from-file\n".write(to: url, atomically: true, encoding: .utf8)
        let backend = InMemorySecretsBackend(["ANTHROPIC_API_KEY": "sk-already-in-keychain"])

        _ = SecretsStore.migrateEnvFileIfPresent(at: url, backend: backend)

        XCTAssertEqual(backend.stored("ANTHROPIC_API_KEY"), "sk-already-in-keychain")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func test_migration_skips_empty_values() throws {
        let url = try makeTempSecretsURL()
        try "ANTHROPIC_API_KEY=\nNOTION_TOKEN=ntn-real\n".write(to: url, atomically: true, encoding: .utf8)
        let backend = InMemorySecretsBackend()

        _ = SecretsStore.migrateEnvFileIfPresent(at: url, backend: backend)

        XCTAssertNil(backend.stored("ANTHROPIC_API_KEY"))
        XCTAssertEqual(backend.stored("NOTION_TOKEN"), "ntn-real")
    }

    func test_migration_missing_file_is_noop() throws {
        let url = try makeTempSecretsURL()  // never created
        let backend = InMemorySecretsBackend()
        XCTAssertFalse(SecretsStore.migrateEnvFileIfPresent(at: url, backend: backend))
        XCTAssertNil(backend.stored("ANTHROPIC_API_KEY"))
    }

    // MARK: - Changed-only writes (SEC23)

    func test_editing_one_field_sets_only_that_account() throws {
        let backend = InMemorySecretsBackend([
            "ANTHROPIC_API_KEY": "sk-a", "NOTION_TOKEN": "ntn-b", "OPENAI_API_KEY": "sk-o",
        ])
        let store = SecretsStore(backend: backend)
        store.notionToken = "ntn-new"
        try store.saveNow()
        XCTAssertEqual(backend.sets, ["NOTION_TOKEN"])
        XCTAssertTrue(backend.removes.isEmpty)
    }

    func test_clearing_a_field_removes_only_that_account() throws {
        let backend = InMemorySecretsBackend(["ANTHROPIC_API_KEY": "sk-a", "NOTION_TOKEN": "ntn-b"])
        let store = SecretsStore(backend: backend)
        store.anthropicAPIKey = ""
        try store.saveNow()
        XCTAssertEqual(backend.removes, ["ANTHROPIC_API_KEY"])
        XCTAssertTrue(backend.sets.isEmpty)
    }

    func test_an_edit_that_trims_to_the_stored_value_writes_nothing() throws {
        let backend = InMemorySecretsBackend(["NOTION_TOKEN": "ntn-b"])
        let store = SecretsStore(backend: backend)
        store.notionToken = "  ntn-b \n"
        try store.saveNow()
        XCTAssertTrue(backend.sets.isEmpty)
        XCTAssertTrue(backend.removes.isEmpty)
    }

    func test_an_empty_account_that_stays_empty_is_not_removed() throws {
        let backend = InMemorySecretsBackend()
        let store = SecretsStore(backend: backend)
        store.notionToken = "ntn-x"
        try store.saveNow()
        XCTAssertEqual(backend.sets, ["NOTION_TOKEN"])
        XCTAssertTrue(backend.removes.isEmpty)
    }

    func test_a_second_save_with_no_edit_writes_nothing() throws {
        let backend = InMemorySecretsBackend()
        let store = SecretsStore(backend: backend)
        store.notionToken = "ntn-x"
        try store.saveNow()
        try store.saveNow()
        XCTAssertEqual(backend.sets, ["NOTION_TOKEN"])
    }

    func test_a_failed_set_is_retried_by_the_next_save() throws {
        let backend = InMemorySecretsBackend()
        backend.failSet = ["NOTION_TOKEN"]
        let store = SecretsStore(backend: backend)
        store.notionToken = "ntn-x"
        XCTAssertThrowsError(try store.saveNow())
        backend.failSet = []
        try store.saveNow()
        XCTAssertEqual(backend.stored("NOTION_TOKEN"), "ntn-x")
    }

    func test_one_account_failing_does_not_stop_the_others() throws {
        let backend = InMemorySecretsBackend()
        backend.failSet = ["ANTHROPIC_API_KEY"]
        let store = SecretsStore(backend: backend)
        store.anthropicAPIKey = "sk-a"
        store.notionToken = "ntn-b"
        XCTAssertThrowsError(try store.saveNow())
        XCTAssertEqual(backend.stored("NOTION_TOKEN"), "ntn-b")
        XCTAssertNil(backend.stored("ANTHROPIC_API_KEY"))
    }

    func test_a_failed_remove_is_thrown_and_retried() throws {
        let backend = InMemorySecretsBackend(["NOTION_TOKEN": "ntn-b"])
        backend.failRemove = ["NOTION_TOKEN"]
        let store = SecretsStore(backend: backend)
        store.notionToken = ""
        XCTAssertThrowsError(try store.saveNow())
        XCTAssertEqual(backend.stored("NOTION_TOKEN"), "ntn-b")
        backend.failRemove = []
        try store.saveNow()
        XCTAssertNil(backend.stored("NOTION_TOKEN"))
    }

    // MARK: - Unreadable reads (SEC23)

    func test_an_unreadable_account_is_never_set_or_removed_by_a_save_that_edits_another_field() throws {
        let backend = InMemorySecretsBackend(["ANTHROPIC_API_KEY": "sk-a", "NOTION_TOKEN": "ntn-b"])
        backend.unreadable = ["ANTHROPIC_API_KEY"]
        let store = SecretsStore(backend: backend)
        XCTAssertEqual(store.anthropicAPIKey, "")
        store.notionToken = "ntn-new"
        try store.saveNow()
        XCTAssertEqual(backend.sets, ["NOTION_TOKEN"])
        XCTAssertTrue(backend.removes.isEmpty)
        XCTAssertEqual(backend.stored("ANTHROPIC_API_KEY"), "sk-a")
    }

    func test_an_unreadable_account_is_not_removed_even_when_its_field_is_touched_empty() throws {
        let backend = InMemorySecretsBackend(["ANTHROPIC_API_KEY": "sk-a"])
        backend.unreadable = ["ANTHROPIC_API_KEY"]
        let store = SecretsStore(backend: backend)
        store.anthropicAPIKey = ""
        try store.saveNow()
        XCTAssertTrue(backend.removes.isEmpty)
        XCTAssertTrue(backend.sets.isEmpty)
    }

    func test_typing_then_deleting_inside_the_debounce_never_removes_an_unreadable_account() throws {
        let locked = InMemorySecretsBackend(["ANTHROPIC_API_KEY": "sk-a"])
        locked.unreadable = ["ANTHROPIC_API_KEY"]
        let lockedStore = SecretsStore(backend: locked)
        lockedStore.anthropicAPIKey = "x"
        lockedStore.anthropicAPIKey = ""
        try lockedStore.saveNow()
        XCTAssertTrue(locked.sets.isEmpty)
        XCTAssertTrue(locked.removes.isEmpty)
        XCTAssertEqual(locked.stored("ANTHROPIC_API_KEY"), "sk-a")
    }

    func test_typing_into_an_unreadable_field_writes_it() throws {
        let backend = InMemorySecretsBackend(["ANTHROPIC_API_KEY": "sk-a"])
        backend.unreadable = ["ANTHROPIC_API_KEY"]
        let store = SecretsStore(backend: backend)
        store.anthropicAPIKey = "sk-typed"
        try store.saveNow()
        XCTAssertEqual(backend.stored("ANTHROPIC_API_KEY"), "sk-typed")
    }

    // MARK: - Persisted tokens (SEC23)

    func test_persisted_tokens_follow_what_was_written_not_what_was_typed() throws {
        let backend = InMemorySecretsBackend(["NOTION_TOKEN": "ntn-b"])
        let store = SecretsStore(backend: backend)
        XCTAssertEqual(store.persistedTokens, ["NOTION_TOKEN": "ntn-b"])
        store.anthropicAPIKey = "sk-typed"
        XCTAssertNil(store.persistedTokens["ANTHROPIC_API_KEY"])
        try store.saveNow()
        XCTAssertEqual(store.persistedTokens["ANTHROPIC_API_KEY"], "sk-typed")
        store.notionToken = ""
        try store.saveNow()
        XCTAssertNil(store.persistedTokens["NOTION_TOKEN"])
    }

    // MARK: - Migration failure handling (SEC23)

    func test_migration_keeps_the_file_when_a_set_fails() throws {
        let url = try makeTempSecretsURL()
        try "ANTHROPIC_API_KEY=sk-a\nNOTION_TOKEN=ntn-b\n".write(to: url, atomically: true, encoding: .utf8)
        let backend = InMemorySecretsBackend()
        backend.failSet = ["NOTION_TOKEN"]
        XCTAssertFalse(SecretsStore.migrateEnvFileIfPresent(at: url, backend: backend))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(backend.stored("ANTHROPIC_API_KEY"), "sk-a")
        // The next launch retries and finishes the job.
        backend.failSet = []
        XCTAssertTrue(SecretsStore.migrateEnvFileIfPresent(at: url, backend: backend))
        XCTAssertEqual(backend.stored("NOTION_TOKEN"), "ntn-b")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func test_migration_does_not_treat_an_unreadable_key_as_absent() throws {
        let url = try makeTempSecretsURL()
        try "ANTHROPIC_API_KEY=sk-from-file\n".write(to: url, atomically: true, encoding: .utf8)
        let backend = InMemorySecretsBackend(["ANTHROPIC_API_KEY": "sk-existing"])
        backend.unreadable = ["ANTHROPIC_API_KEY"]
        XCTAssertFalse(SecretsStore.migrateEnvFileIfPresent(at: url, backend: backend))
        XCTAssertTrue(backend.sets.isEmpty)
        XCTAssertEqual(backend.stored("ANTHROPIC_API_KEY"), "sk-existing")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func test_migration_moves_openai_key() throws {
        let url = try makeTempSecretsURL()
        try "OPENAI_API_KEY=sk-oai\n".write(to: url, atomically: true, encoding: .utf8)
        let backend = InMemorySecretsBackend()
        XCTAssertTrue(SecretsStore.migrateEnvFileIfPresent(at: url, backend: backend))
        XCTAssertEqual(backend.stored("OPENAI_API_KEY"), "sk-oai")
    }

    // MARK: - Off-main saves and save state (CONC8)

    private func spin(until done: () -> Bool, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while !done() && Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }

    func test_a_slow_keychain_write_does_not_block_the_main_run_loop() {
        let backend = InMemorySecretsBackend()
        backend.setDelay = 0.5
        let store = SecretsStore(backend: backend)
        var persisted = false
        var persistedOnMain = false
        let cancellable = store.didPersist.sink { persistedOnMain = Thread.isMainThread; persisted = true }
        store.notionToken = "ntn-slow"
        // `saving` is set on main when the debounce fires, so the 500 ms `set` is now in flight.
        spin(until: { store.saveStates["NOTION_TOKEN"] == .saving })
        XCTAssertEqual(store.saveStates["NOTION_TOKEN"], .saving)
        var mainRan = false
        let posted = Date()
        DispatchQueue.main.async { mainRan = true }
        spin(until: { mainRan }, timeout: 1)
        XCTAssertTrue(mainRan)
        XCTAssertLessThan(Date().timeIntervalSince(posted), 0.1, "main was blocked behind the Keychain write")
        spin(until: { persisted })
        XCTAssertTrue(persisted)
        XCTAssertTrue(persistedOnMain)
        XCTAssertEqual(backend.callThreadsOnMain, [false], "every backend call must run off main")
        cancellable.cancel()
    }

    func test_the_save_state_goes_saving_then_saved_and_then_clears() {
        let backend = InMemorySecretsBackend()
        backend.setDelay = 0.3
        let store = SecretsStore(backend: backend)
        store.notionToken = "ntn-x"
        XCTAssertNil(store.saveStates["NOTION_TOKEN"], "nothing is saving before the debounce fires")
        spin(until: { store.saveStates["NOTION_TOKEN"] == .saving })
        XCTAssertEqual(store.saveStates["NOTION_TOKEN"], .saving)
        XCTAssertNil(store.saveStates["ANTHROPIC_API_KEY"], "an account nobody edited stays quiet")
        spin(until: { store.saveStates["NOTION_TOKEN"] == .saved })
        XCTAssertEqual(store.saveStates["NOTION_TOKEN"], .saved)
        spin(until: { store.saveStates["NOTION_TOKEN"] == nil }, timeout: 4)
        XCTAssertNil(store.saveStates["NOTION_TOKEN"])
    }

    func test_a_failed_save_goes_saving_then_failed_without_didPersist_or_the_secret() {
        let backend = InMemorySecretsBackend()
        backend.failSet = ["NOTION_TOKEN"]
        let store = SecretsStore(backend: backend)
        var persisted = false
        let cancellable = store.didPersist.sink { persisted = true }
        store.notionToken = "ntn-SECRETVALUE"
        spin(until: { if case .failed = store.saveStates["NOTION_TOKEN"] { return true } else { return false } })
        guard case .failed(let message)? = store.saveStates["NOTION_TOKEN"] else { return XCTFail("expected failed, got \(String(describing: store.saveStates["NOTION_TOKEN"]))") }
        XCTAssertFalse(message.contains("SECRETVALUE"))
        XCTAssertFalse(persisted)
        XCTAssertEqual(store.saveErrors["NOTION_TOKEN"], message)
        cancellable.cancel()
    }

    func test_typing_a_character_and_deleting_it_spawns_nothing() {
        let backend = InMemorySecretsBackend(["NOTION_TOKEN": "ntn-b"])
        let store = SecretsStore(backend: backend)
        store.notionToken = "ntn-bX"
        store.notionToken = "ntn-b"
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.8))
        XCTAssertTrue(backend.sets.isEmpty)
        XCTAssertTrue(store.saveStates.isEmpty)
    }

    // MARK: - parse

    func test_parse_strips_quotes_and_skips_comments_and_blanks() {
        let pairs = SecretsStore.parse("""
        # header
        ANTHROPIC_API_KEY="sk-quoted"

        NOTION_TOKEN=ntn-bare
        """)
        let dict = Dictionary(pairs.map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(dict["ANTHROPIC_API_KEY"], "sk-quoted")
        XCTAssertEqual(dict["NOTION_TOKEN"], "ntn-bare")
        XCTAssertNil(dict["# header"])
    }

    func test_parse_keeps_equals_signs_in_value() {
        let pairs = SecretsStore.parse("WEIRD_KEY=foo=bar=baz\n")
        XCTAssertEqual(pairs.first?.key, "WEIRD_KEY")
        XCTAssertEqual(pairs.first?.value, "foo=bar=baz")
    }
}

// MARK: - UX91: a failed Keychain save is published, named by account, never by value

extension SecretsStoreTests {
    func test_a_failed_keychain_save_names_the_account_and_never_the_value() throws {
        let logs = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mp-ux91-secrets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        setenv("MEETINGPIPE_LOGS_DIR", logs.path, 1)
        defer {
            unsetenv("MEETINGPIPE_LOGS_DIR")
            try? FileManager.default.removeItem(at: logs)
        }
        let backend = InMemorySecretsBackend()
        backend.failSet = ["NOTION_TOKEN"]
        let store = SecretsStore(backend: backend)

        store.notionToken = "ntn-very-secret"
        XCTAssertThrowsError(try store.saveNow())

        let failure = try XCTUnwrap(store.saveError)
        XCTAssertEqual(failure.store, .keychain)
        XCTAssertTrue(failure.reason.contains("NOTION_TOKEN"), failure.reason)
        XCTAssertFalse(failure.reason.contains("ntn-very-secret"))
        XCTAssertFalse(failure.reason.contains("boom"), "the security stderr never reaches the banner")

        let raw = (try? String(contentsOf: logs.appendingPathComponent("events.jsonl"), encoding: .utf8)) ?? ""
        let events = raw.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }.filter { $0["action"] as? String == "config_save_failed" }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?["store"] as? String, "keychain")
        XCTAssertEqual(events.first?["account"] as? String, "NOTION_TOKEN")
        XCTAssertEqual(events.first?["status"] as? Int, 36)
        let daemonLog = (try? String(contentsOf: logs.appendingPathComponent("daemon.log"), encoding: .utf8)) ?? ""
        XCTAssertTrue(daemonLog.contains("Keychain save of NOTION_TOKEN failed (security status 36)"), daemonLog)
        XCTAssertFalse(daemonLog.contains("ntn-very-secret"))
        XCTAssertFalse(raw.contains("ntn-very-secret"))
        XCTAssertFalse(raw.contains("boom"))

        backend.failSet = []
        try store.saveNow()
        XCTAssertNil(store.saveError)
    }

    func test_several_failed_accounts_and_an_unstorable_token_read_as_such() throws {
        let backend = InMemorySecretsBackend()
        backend.failSet = ["NOTION_TOKEN", "OPENAI_API_KEY"]
        let store = SecretsStore(backend: backend)
        store.notionToken = "ntn-x"
        store.openaiAPIKey = "sk-y"
        XCTAssertThrowsError(try store.saveNow())
        XCTAssertEqual(store.saveError?.reason, "the Keychain refused to store NOTION_TOKEN and 1 more")

        let other = InMemorySecretsBackend()
        other.unquotableSet = ["ANTHROPIC_API_KEY"]
        let pasted = SecretsStore(backend: other)
        pasted.anthropicAPIKey = "sk-bad"
        XCTAssertThrowsError(try pasted.saveNow())
        XCTAssertEqual(pasted.saveError?.reason,
                       "ANTHROPIC_API_KEY has a character the Keychain cannot store, so paste it again")
    }
}
