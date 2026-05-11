import XCTest
@testable import MeetingPipe

/// The relative-path helper underpins the `obsidian://open` URL the
/// detail header builds. Hard to drive via the SwiftUI view but trivial
/// to cover at the helper level.
final class MeetingDetailViewTests: XCTestCase {

    func test_relativePath_strips_vault_prefix() {
        let vault = URL(fileURLWithPath: "/Users/me/Vault")
        let note = URL(fileURLWithPath: "/Users/me/Vault/Meetings/2026/note.md")
        XCTAssertEqual(
            PublishURLs.relativePath(of: note, from: vault),
            "Meetings/2026/note.md"
        )
    }

    func test_relativePath_returns_nil_for_unrelated_paths() {
        let vault = URL(fileURLWithPath: "/Users/me/Vault")
        let note = URL(fileURLWithPath: "/tmp/other.md")
        XCTAssertNil(PublishURLs.relativePath(of: note, from: vault))
    }

    func test_relativePath_returns_nil_when_file_equals_base() {
        let vault = URL(fileURLWithPath: "/Users/me/Vault")
        XCTAssertNil(PublishURLs.relativePath(of: vault, from: vault))
    }

    func test_relativePath_handles_trailing_slashes() {
        // Both forms standardize to the same path components.
        let vault = URL(fileURLWithPath: "/Users/me/Vault/")
        let note = URL(fileURLWithPath: "/Users/me/Vault/Meetings/n.md")
        XCTAssertEqual(
            PublishURLs.relativePath(of: note, from: vault),
            "Meetings/n.md"
        )
    }
}
