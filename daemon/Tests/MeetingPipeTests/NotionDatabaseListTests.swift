import XCTest
@testable import MeetingPipe

// `@MainActor` because `NotionDatabaseList.parse` is main-actor isolated
// (it lives next to UI-driven Notion picker state). Swift 6's strict
// concurrency surfaces this when Xcode 26+ compiles the tests; the
// declared annotation matches the runtime isolation that's been true
// since the class was introduced.
@MainActor
final class NotionDatabaseListTests: XCTestCase {

    private func payload(_ raw: String) -> Data {
        raw.data(using: .utf8)!
    }

    func test_parses_id_and_title_from_search_response() {
        let json = #"""
        {
          "results": [
            {
              "object": "database",
              "id": "abc123def456",
              "title": [{"plain_text": "Client work"}]
            },
            {
              "object": "database",
              "id": "ffe987bca321",
              "title": [{"plain_text": "Personal "}, {"plain_text": "Meetings"}]
            }
          ]
        }
        """#
        let entries = NotionDatabaseList.parse(jsonData: payload(json))
        XCTAssertEqual(entries.count, 2)
        // Sorted by title.
        XCTAssertEqual(entries[0].title, "Client work")
        XCTAssertEqual(entries[0].id, "abc123def456")
        XCTAssertEqual(entries[1].title, "Personal Meetings")
        XCTAssertEqual(entries[1].id, "ffe987bca321")
    }

    func test_handles_missing_title_with_placeholder() {
        let json = #"""
        {
          "results": [
            {"object": "database", "id": "no-title-id"}
          ]
        }
        """#
        let entries = NotionDatabaseList.parse(jsonData: payload(json))
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].title, "(untitled)")
    }

    func test_skips_entries_without_id() {
        let json = #"""
        {
          "results": [
            {"object": "database", "id": "", "title": [{"plain_text": "Empty id"}]},
            {"object": "database", "title": [{"plain_text": "Missing id"}]},
            {"object": "database", "id": "real-id", "title": [{"plain_text": "Has id"}]}
          ]
        }
        """#
        let entries = NotionDatabaseList.parse(jsonData: payload(json))
        XCTAssertEqual(entries.map(\.id), ["real-id"])
    }

    func test_malformed_response_returns_empty() {
        XCTAssertEqual(NotionDatabaseList.parse(jsonData: payload("not json")), [])
        XCTAssertEqual(NotionDatabaseList.parse(jsonData: payload("{}")), [])
        XCTAssertEqual(NotionDatabaseList.parse(jsonData: payload(#"{"results": "not an array"}"#)), [])
    }

    // TECH-SEC4: under regulated mode the daemon must not POST to api.notion.com.
    // refresh() short-circuits to a .failed state and never touches the network.
    func test_refresh_is_blocked_under_regulated_mode() {
        let tmpCache = FileManager.default.temporaryDirectory
            .appendingPathComponent("notion-databases-test-\(UUID().uuidString).json")
        let list = NotionDatabaseList(cacheURL: tmpCache, isRegulated: { true })

        list.refresh()

        guard case let .failed(message) = list.state else {
            return XCTFail("expected .failed under regulated mode, got \(list.state)")
        }
        XCTAssertTrue(message.lowercased().contains("regulated"),
                      "the blocked message should explain the regulated-mode gate")
        XCTAssertTrue(list.entries.isEmpty, "no databases should be fetched under regulated mode")
    }
}
