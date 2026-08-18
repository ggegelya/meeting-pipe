import XCTest
@testable import MeetingPipe

/// Audit `MeetingSourceScanner.isActiveMeetingWindow` against a title fixture.
/// Each entry pins a (bundle_id, state, expected outcome) triple to one or more
/// literal AX titles, and carries `seeded` to say where the titles came from.
///
/// **What the fixture is today, stated plainly (CI6): guesses.** This docstring
/// used to call the file "the ground truth from running apps", and every one of
/// its rows is `seeded: true`, meaning a title somebody wrote down as plausible
/// rather than one read off a running Teams or Zoom window. That is the same
/// class of writing-from-a-plausible-string that produced CAL3's 3%
/// `meeting_title` coverage, and a fence built on it pins the recognizer against
/// the author's model of Teams, not against Teams. So a real title change that
/// the guesses happen to model still leaves all 21 rows green while
/// end-detection degrades. `test_fixture_is_backed_by_real_captures` is what
/// says so out loud, and VALOWN1 is what fixes it.
///
/// It complements the unit-test matrix in `WindowRecognizerTests`: those assert
/// the recognizer's logical contract, and this file is meant to be the empirical
/// half. Once VALOWN1's captures land, a Teams / Zoom UI update that changes a
/// title shape turns one or more rows here red, which is what makes a silent
/// regression (a mid-call stop noticed weeks later) arrive as a test failure on
/// the next CI run instead.
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

    /// The pre-registered floor for this fence: **at least one row captured from
    /// a running app** (CI6). Below it the fixture pins guesses, so the rows
    /// above are green about the author's model of Teams rather than about
    /// Teams, and the P1.1 acceptance criterion is not met.
    ///
    /// This used to be `test_fixture_capture_progress_is_logged`, and it said so
    /// in its own body: "Not an assertion: this test always passes." Its only
    /// check was `total >= 1`, which the sibling's `XCTAssertFalse(entries
    /// .isEmpty)` already guarantees, so the one test whose job was to tell a
    /// reader the fence is unbacked could not fail even in principle.
    ///
    /// **It skips rather than fails, and that is the deliberate half.** Raising
    /// the real capture is VALOWN1, which is owner-gated at P4 and needs five
    /// real Teams meetings across as many weeks as they take, so a hard
    /// `XCTAssertGreaterThan(captured, 0)` would leave `swift test` red on `main`
    /// for every session until then. A suite that is red for a known reason
    /// trains everyone to read red as noise, and the next session cannot tell
    /// its own regression from this one; that costs more than this fence is
    /// worth. A skip is XCTest's word for "not verified", it is counted in the
    /// run summary rather than buried in output the way the old `print` was, and
    /// the floor below goes live by itself the moment a captured row lands.
    func test_fixture_is_backed_by_real_captures() throws {
        let fixture = try loadFixture()
        let total = fixture.entries.count
        let captured = fixture.entries.filter { !$0.seeded }.count
        print("[fixture] window_titles.json: \(captured)/\(total) captured, \(total - captured) still seeded")

        guard captured >= Self.capturedRowFloor else {
            throw XCTSkip(
                "window_titles.json holds \(total) seeded guesses and \(captured) rows captured "
                    + "from a running app, so the fixture fence above pins this repo's model of a "
                    + "Teams title rather than a Teams title. Unblocked by VALOWN1: run "
                    + "`daemon/scripts/cal3-teams-title-probe.swift` across five real meetings and "
                    + "paste the emitted rows in with seeded: false. Skipped rather than failed on "
                    + "purpose (CI6): that capture is owner-gated, and a suite left red until it "
                    + "happens teaches every session to ignore red."
            )
        }
        XCTAssertGreaterThanOrEqual(
            captured, Self.capturedRowFloor,
            "the fixture lost its captured rows; a real title is evidence and is never deleted "
                + "to make a row green (CI6)"
        )
    }

    /// One captured row. Deliberately the smallest number that means "somebody
    /// pointed this at a running app", not a coverage target: VALOWN1 decides how
    /// many rows the probe emits, and this floor only has to separate "backed by
    /// a measurement" from "backed by nothing".
    private static let capturedRowFloor = 1
}
