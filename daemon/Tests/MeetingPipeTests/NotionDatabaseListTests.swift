import XCTest
@testable import MeetingPipe

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
}
