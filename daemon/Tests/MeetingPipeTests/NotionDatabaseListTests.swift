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

    /// SEC23: the token comes from the injected source (the live `SecretsStore`), not the process environment.
    func test_refresh_without_a_token_asks_for_one_and_never_reads_the_process_environment() {
        setenv("NOTION_TOKEN", "from-the-environment", 1)
        defer { unsetenv("NOTION_TOKEN") }
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("notion-\(UUID().uuidString).json")
        let list = NotionDatabaseList(cacheURL: cache, isRegulated: { false }, tokenSource: { [:] })
        list.refresh()
        XCTAssertEqual(list.state, .failed("Set NOTION_TOKEN in Preferences -> Integrations first."))
    }

    /// HYG15: a 404 from `/v1/databases/{id}` is the named "not found or not shared" case, not an
    /// `NSError` whose code a caller would have to know was the status.
    func test_verify_database_404_throws_database_not_found() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NotFoundProtocol.self]
        let session = URLSession(configuration: config)
        do {
            try await NotionDatabaseList.verifyDatabase(token: "t", databaseId: "abc", session: session)
            XCTFail("a 404 must throw")
        } catch {
            XCTAssertEqual(error as? NotionDatabaseList.NotionError, .databaseNotFound)
        }
    }

    private final class NotFoundProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{}".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }
}
