import XCTest
@testable import MeetingPipe

/// Audit `MeetingSourceScanner.isActiveMeetingWindow` against an empirical title
/// fixture. Each entry pins a (bundle_id, state, expected outcome)
/// triple to one or more literal AX titles captured from the real app.
///
/// This complements the unit-test matrix in `WindowRecognizerTests`:
/// the unit tests assert the recognizer's logical contract, this
/// fixture file is the ground truth from running apps.
///
/// When a Teams / Zoom UI update changes a window title shape, the
/// expected failure mode is one or more rows here turning red. That
/// turns "silent regression manifesting as a mid-call stop weeks later"
/// into "test failure on the dev's next CI run".
final class WindowRecognizerFixtureTests: XCTestCase {

    private struct Entry: Decodable {
        let bundleID: String
        let state: String
        let expected: String
        let seeded: Bool
        let titles: [String]

        enum CodingKeys: String, CodingKey {
            case bundleID = "bundle_id"
            case state, expected, seeded, titles
        }
    }

    private struct Fixture: Decodable {
        let entries: [Entry]
    }

    private func loadFixture() throws -> Fixture {
        guard let url = Bundle.module.url(forResource: "window_titles", withExtension: "json") else {
            throw XCTSkip("window_titles.json fixture not bundled")
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Fixture.self, from: data)
    }

    func test_recognizer_matches_fixture() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.entries.isEmpty, "fixture must contain at least one entry")

        for entry in fixture.entries {
            // Native kind for all current entries; the fixture format
            // can grow a `kind` column when browser captures land.
            let recognized = entry.titles.contains { title in
                MeetingSourceScanner.isActiveMeetingWindow(
                    bundleID: entry.bundleID, kind: .native, title: title)
            }
            let expected = (entry.expected == "recognize")
            XCTAssertEqual(
                recognized, expected,
                "fixture row mismatch: bundle=\(entry.bundleID) state=\(entry.state) "
                    + "expected=\(entry.expected) actual=\(recognized ? "recognize" : "reject") "
                    + "titles=\(entry.titles) seeded=\(entry.seeded)"
            )
        }
    }

    /// Surface the seeded-vs-captured ratio so a reader of test output
    /// can tell at a glance whether the fixture has been replaced with
    /// real captures yet (the P1.1 acceptance criterion).
    func test_fixture_capture_progress_is_logged() throws {
        let fixture = try loadFixture()
        let total = fixture.entries.count
        let captured = fixture.entries.filter { !$0.seeded }.count
        let seededOnly = total - captured
        // Not an assertion: this test always passes. It exists so the
        // progress shows up in test output.
        print("[fixture] window_titles.json: \(captured)/\(total) captured, \(seededOnly) still seeded")
        XCTAssertGreaterThanOrEqual(total, 1)
    }
}
