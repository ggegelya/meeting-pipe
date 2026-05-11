import XCTest
@testable import MeetingPipe

/// Unit tests for `Detector.anyTitleMatchesFragment`, the pure matcher
/// behind the browser tab-strip probe (TECH-C3). The full probe pulls
/// titles from `AXUIElement` and can't be tested without a real browser,
/// but the substring-matching layer is pure and worth locking in so a
/// future change can't silently regress the "switching tabs must not
/// end the recording" guarantee.
final class BrowserTabProbeTests: XCTestCase {

    private let meetFragments = ["meet.google.com", "teams.live.com", "teams.microsoft.com", "webex.com"]

    // MARK: - Tab still present (matches)

    func test_meeting_tab_focused_matches() {
        let titles = ["Standup - meet.google.com/abc-defg-hij"]
        XCTAssertTrue(Detector.anyTitleMatchesFragment(titles, fragments: meetFragments))
    }

    func test_meeting_tab_unfocused_still_matches() {
        // The whole point of TECH-C3: even if the focused tab is GitHub,
        // the Meet tab is still alive in the tab strip, so the meeting
        // is still on.
        let titles = [
            "PR #1234 · github.com",        // focused
            "Inbox (12) · gmail.com",
            "Standup - meet.google.com/xyz", // background, still open
        ]
        XCTAssertTrue(Detector.anyTitleMatchesFragment(titles, fragments: meetFragments))
    }

    // MARK: - Tab gone (no match)

    func test_no_meeting_tab_does_not_match() {
        // User closed the Meet tab. Only unrelated tabs remain.
        let titles = [
            "PR #1234 · github.com",
            "Inbox (12) · gmail.com",
            "Hacker News",
        ]
        XCTAssertFalse(Detector.anyTitleMatchesFragment(titles, fragments: meetFragments))
    }

    func test_empty_titles_does_not_match() {
        XCTAssertFalse(Detector.anyTitleMatchesFragment([], fragments: meetFragments))
    }

    // MARK: - Case + substring semantics

    func test_match_is_case_insensitive() {
        let titles = ["MEET.GOOGLE.COM/standup"]
        XCTAssertTrue(Detector.anyTitleMatchesFragment(titles, fragments: meetFragments))
    }

    func test_match_uses_substring_not_equality() {
        let titles = ["pre meet.google.com/x post"]
        XCTAssertTrue(Detector.anyTitleMatchesFragment(titles, fragments: meetFragments))
    }

    // MARK: - False-positive defence

    func test_unrelated_text_with_word_meet_does_not_match_fragment() {
        // Fragments are URL hostnames, so the bare word "meet" shouldn't
        // satisfy them — only the full domain does.
        let titles = ["Notes about today's meet with Alice"]
        XCTAssertFalse(Detector.anyTitleMatchesFragment(titles, fragments: meetFragments))
    }

    func test_empty_fragments_never_matches() {
        // Degenerate input — no fragments configured. The matcher must
        // not flip to "everything matches" on an empty `contains` array.
        XCTAssertFalse(
            Detector.anyTitleMatchesFragment(["meet.google.com/x"], fragments: [])
        )
    }
}
