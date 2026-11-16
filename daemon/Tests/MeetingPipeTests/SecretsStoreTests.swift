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
        private(set) var store: [String: String]
        var unreadable: Set<String> = []
        var failSet: Set<String> = []
        var failRemove: Set<String> = []
        private(set) var sets: [String] = []
        private(set) var removes: [String] = []
        init(_ initial: [String: String] = [:]) { self.store = initial }
        func value(for account: String) -> SecretRead {
            if unreadable.contains(account) { return .unreadable(status: 36, detail: "locked") }
            return store[account].map { .found($0) } ?? .notFound
        }
        func stored(_ account: String) -> String? { store[account] }
        func set(_ value: String, for account: String) throws {
            sets.append(account)
            if failSet.contains(account) { throw KeychainBackend.KeychainError.commandFailed("boom") }
            store[account] = value
        }
        func remove(_ account: String) throws {
            removes.append(account)
            if failRemove.contains(account) { throw KeychainBackend.KeychainError.commandFailed("boom") }
            store.removeValue(forKey: account)
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
