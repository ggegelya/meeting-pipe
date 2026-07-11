import XCTest
@testable import MeetingPipe

/// FEAT3-MANAGE: the read-only roster.json reader behind the Preferences ▸ Pipeline
/// People list. Pinned so it stays in step with the Python `RosterStore` shape
/// (`{schema_version, people:[{name, samples, centroids}]}`).
final class RosterProfileTests: XCTestCase {

    private func writeRoster(_ json: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("roster-\(UUID().uuidString).json")
        try? Data(json.utf8).write(to: url)
        return url
    }

    func test_reads_people_with_sample_counts_sorted_case_insensitively() {
        let url = writeRoster(#"{"schema_version":1,"people":[{"name":"Bohdan","samples":[[0.1],[0.2]],"centroids":[[0.1]]},{"name":"alice","samples":[[0.1],[0.2],[0.3],[0.4]],"centroids":[[0.1]]}]}"#)
        defer { try? FileManager.default.removeItem(at: url) }
        let people = RosterProfile.people(at: url)
        XCTAssertEqual(people.map(\.name), ["alice", "Bohdan"])
        XCTAssertEqual(people.first?.sampleCount, 4)
        XCTAssertEqual(people.last?.sampleCount, 2)
    }

    func test_missing_file_is_empty() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("absent-\(UUID().uuidString).json")
        XCTAssertEqual(RosterProfile.people(at: url), [])
    }

    func test_malformed_json_is_empty() {
        let url = writeRoster("not json at all")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(RosterProfile.people(at: url), [])
    }

    func test_entry_without_samples_reads_zero() {
        let url = writeRoster(#"{"schema_version":1,"people":[{"name":"Cara","centroids":[[0.1]]}]}"#)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(RosterProfile.people(at: url), [RosterProfile.Person(name: "Cara", sampleCount: 0)])
    }

    func test_nameless_and_empty_name_entries_are_dropped() {
        let url = writeRoster(#"{"schema_version":1,"people":[{"samples":[[0.1]]},{"name":"","samples":[]},{"name":"Dan","samples":[[0.1]]}]}"#)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(RosterProfile.people(at: url).map(\.name), ["Dan"])
    }
}
