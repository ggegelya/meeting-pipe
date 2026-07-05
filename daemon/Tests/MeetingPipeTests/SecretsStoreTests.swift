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

    private final class InMemorySecretsBackend: SecretsBackend {
        private(set) var store: [String: String]
        init(_ initial: [String: String] = [:]) { self.store = initial }
        func value(for account: String) -> String? { store[account] }
        func set(_ value: String, for account: String) throws { store[account] = value }
        func remove(_ account: String) { store.removeValue(forKey: account) }
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
        XCTAssertEqual(backend.value(for: "ANTHROPIC_API_KEY"), "sk-new")
        XCTAssertEqual(backend.value(for: "NOTION_TOKEN"), "ntn-new")
    }

    func test_clearing_a_value_removes_the_item() throws {
        // Blanking a field in Preferences should delete the Keychain item, not store an empty string.
        let backend = InMemorySecretsBackend(["ANTHROPIC_API_KEY": "sk-old", "NOTION_TOKEN": "ntn-keep"])
        let store = SecretsStore(backend: backend)
        store.anthropicAPIKey = ""
        try store.saveNow()
        XCTAssertNil(backend.value(for: "ANTHROPIC_API_KEY"))
        XCTAssertEqual(backend.value(for: "NOTION_TOKEN"), "ntn-keep")
    }

    func test_whitespace_only_value_is_treated_as_absent() throws {
        let backend = InMemorySecretsBackend(["ANTHROPIC_API_KEY": "sk-old"])
        let store = SecretsStore(backend: backend)
        store.anthropicAPIKey = "   "
        try store.saveNow()
        XCTAssertNil(backend.value(for: "ANTHROPIC_API_KEY"))
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

        XCTAssertEqual(backend.value(for: "ANTHROPIC_API_KEY"), "sk-a")
        XCTAssertEqual(backend.value(for: "NOTION_TOKEN"), "ntn-b")
        XCTAssertEqual(backend.value(for: "HF_TOKEN"), "hf-c")
        // Only the managed keys move; a user-added key is not silently absorbed.
        XCTAssertNil(backend.value(for: "UNMANAGED"))
        // The plaintext file is gone once migrated.
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func test_migration_does_not_overwrite_existing_keychain_value() throws {
        let url = try makeTempSecretsURL()
        try "ANTHROPIC_API_KEY=sk-from-file\n".write(to: url, atomically: true, encoding: .utf8)
        let backend = InMemorySecretsBackend(["ANTHROPIC_API_KEY": "sk-already-in-keychain"])

        _ = SecretsStore.migrateEnvFileIfPresent(at: url, backend: backend)

        XCTAssertEqual(backend.value(for: "ANTHROPIC_API_KEY"), "sk-already-in-keychain")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func test_migration_skips_empty_values() throws {
        let url = try makeTempSecretsURL()
        try "ANTHROPIC_API_KEY=\nNOTION_TOKEN=ntn-real\n".write(to: url, atomically: true, encoding: .utf8)
        let backend = InMemorySecretsBackend()

        _ = SecretsStore.migrateEnvFileIfPresent(at: url, backend: backend)

        XCTAssertNil(backend.value(for: "ANTHROPIC_API_KEY"))
        XCTAssertEqual(backend.value(for: "NOTION_TOKEN"), "ntn-real")
    }

    func test_migration_missing_file_is_noop() throws {
        let url = try makeTempSecretsURL()  // never created
        let backend = InMemorySecretsBackend()
        XCTAssertFalse(SecretsStore.migrateEnvFileIfPresent(at: url, backend: backend))
        XCTAssertNil(backend.value(for: "ANTHROPIC_API_KEY"))
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
