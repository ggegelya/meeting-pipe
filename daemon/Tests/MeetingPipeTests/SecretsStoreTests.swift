import XCTest
@testable import MeetingPipe

/// SecretsStore mirrors ConfigStore but for the shell-style secrets.env
/// file. Two invariants need protection:
///
///   1. Mode 0600 on every write — these are API keys; world-readable
///      would be a leak on multi-user systems.
///   2. Preserve unknown keys — the file may have entries (HF_TOKEN,
///      user-added keys, comments) the UI doesn't model. Editing
///      ANTHROPIC_API_KEY through the UI must NOT strip them.
final class SecretsStoreTests: XCTestCase {

    private func makeTempSecretsURL() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mp-secrets-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("secrets.env")
    }

    func test_loads_defaults_when_file_missing() {
        let url = (try? makeTempSecretsURL())!
        // Don't create the file.
        let store = SecretsStore(secretsURL: url)
        XCTAssertEqual(store.anthropicAPIKey, "")
        XCTAssertEqual(store.notionToken, "")
    }

    func test_round_trip_persists_changes() throws {
        let url = try makeTempSecretsURL()
        try """
        ANTHROPIC_API_KEY=sk-old
        NOTION_TOKEN=ntn-old
        HF_TOKEN=hf_x
        """.write(to: url, atomically: true, encoding: .utf8)

        let store = SecretsStore(secretsURL: url)
        XCTAssertEqual(store.anthropicAPIKey, "sk-old")
        XCTAssertEqual(store.notionToken, "ntn-old")

        store.anthropicAPIKey = "sk-new"
        store.notionToken = "ntn-new"
        try store.saveNow()

        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(raw.contains("ANTHROPIC_API_KEY=sk-new"))
        XCTAssertTrue(raw.contains("NOTION_TOKEN=ntn-new"))
        // The unknown key must survive — that's the whole point of
        // round-tripping rawLines instead of regenerating from scratch.
        XCTAssertTrue(raw.contains("HF_TOKEN=hf_x"))
    }

    func test_preserves_comments_and_blank_lines() throws {
        let url = try makeTempSecretsURL()
        try """
        # Required secrets for meeting-pipe.
        ANTHROPIC_API_KEY=

        NOTION_TOKEN=
        # Optional below.
        HF_TOKEN=
        """.write(to: url, atomically: true, encoding: .utf8)

        let store = SecretsStore(secretsURL: url)
        store.anthropicAPIKey = "sk-test"
        try store.saveNow()

        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(raw.contains("# Required secrets for meeting-pipe."))
        XCTAssertTrue(raw.contains("# Optional below."))
        XCTAssertTrue(raw.contains("HF_TOKEN="))
    }

    func test_persisted_file_is_mode_0600() throws {
        let url = try makeTempSecretsURL()
        let store = SecretsStore(secretsURL: url)
        store.anthropicAPIKey = "sk-secret"
        try store.saveNow()

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(mode & 0o777, 0o600,
                       "secrets.env must be mode 0600; got 0o\(String(mode & 0o777, radix: 8))")
    }

    func test_persisted_file_is_mode_0600_when_replacing_existing() throws {
        let url = try makeTempSecretsURL()
        // File exists with looser perms — the writer must enforce 0600
        // even on top of an existing 0644 / 0666 file (e.g. the user
        // had this in their dotfiles repo and it got copied in).
        try "ANTHROPIC_API_KEY=sk-old\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: url.path
        )

        let store = SecretsStore(secretsURL: url)
        store.anthropicAPIKey = "sk-new"
        try store.saveNow()

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(mode & 0o777, 0o600)
    }

    func test_upsert_replaces_existing_key_in_place() {
        let lines = [
            "# header",
            "ANTHROPIC_API_KEY=old",
            "NOTION_TOKEN=keep",
        ]
        let out = SecretsStore.upsert(lines: lines, key: "ANTHROPIC_API_KEY", value: "new")
        XCTAssertEqual(out, [
            "# header",
            "ANTHROPIC_API_KEY=new",
            "NOTION_TOKEN=keep",
        ])
    }

    func test_upsert_appends_when_key_absent() {
        let lines = ["NOTION_TOKEN=ntn"]
        let out = SecretsStore.upsert(lines: lines, key: "ANTHROPIC_API_KEY", value: "sk-x")
        XCTAssertEqual(out, ["NOTION_TOKEN=ntn", "ANTHROPIC_API_KEY=sk-x"])
    }

    func test_upsert_handles_spaces_around_equals() {
        let lines = ["ANTHROPIC_API_KEY = sk-old"]
        let out = SecretsStore.upsert(lines: lines, key: "ANTHROPIC_API_KEY", value: "sk-new")
        // Normalize on save: no spaces around `=`. That's the format
        // every shell sourcing tool (set -a; .) handles cleanly.
        XCTAssertEqual(out, ["ANTHROPIC_API_KEY=sk-new"])
    }
}
