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

    /// What a row's `expected` token asks this suite to do with it (HYG6).
    ///
    /// `unknown` exists because the CAL3 probe cannot compute the right answer:
    /// it deliberately carries no Teams title pattern and never calls
    /// `isActiveMeetingWindow`, so any verdict it emitted would be asserted
    /// without having been measured. It used to emit a hardcoded `recognize`,
    /// and this suite hard-asserts what it is given, so the first real Teams
    /// title the recognizer rejects would have turned weeks of owner capture
    /// into a red suite on an unrelated commit. That reject is the outcome CAL3
    /// exists on the possibility of, so it has to arrive as a finding, not as a
    /// broken build. An unclassified row is reported instead, and a human
    /// promotes it to `recognize` or `reject` after reading what the recognizer
    /// actually returned.
    enum RowExpectation: Equatable {
        case recognize
        case reject
        case unclassified
        case malformed(String)

        init(token: String) {
            switch token {
            case "recognize": self = .recognize
            case "reject": self = .reject
            case "unknown": self = .unclassified
            default: self = .malformed(token)
            }
        }
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
            let actual = recognized ? "recognize" : "reject"
            let context =
                "bundle=\(entry.bundleID) state=\(entry.state) "
                + "titles=\(entry.titles) seeded=\(entry.seeded)"

            let expectation = RowExpectation(token: entry.expected)
            switch expectation {
            case .recognize, .reject:
                XCTAssertEqual(
                    recognized, expectation == .recognize,
                    "fixture row mismatch: expected=\(entry.expected) actual=\(actual) \(context)"
                )
            case .unclassified:
                // Reported, never asserted. Read this line, decide, and rewrite
                // the row's `expected` by hand. A `reject` on a real captured
                // title is a DET-band finding about `isActiveMeetingWindow`,
                // not a bad capture; never edit a captured title to go green.
                print("[fixture] UNCLASSIFIED recognizer=\(actual) \(context)")
            case .malformed(let token):
                // A typo must not read as `reject` and quietly pass.
                XCTFail(
                    "fixture row has an unreadable `expected` value \"\(token)\": \(context); "
                        + "use recognize, reject, or unknown"
                )
            }
        }
    }

    /// Pin the rule itself, since the fixture holds no `unknown` row today and a
    /// suite that only exercises the seeded rows would pass with the branch gone.
    func test_row_expectation_reads_every_token() {
        XCTAssertEqual(RowExpectation(token: "recognize"), .recognize)
        XCTAssertEqual(RowExpectation(token: "reject"), .reject)
        XCTAssertEqual(RowExpectation(token: "unknown"), .unclassified)
        XCTAssertEqual(RowExpectation(token: "Recognize"), .malformed("Recognize"))
        XCTAssertEqual(RowExpectation(token: ""), .malformed(""))
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
