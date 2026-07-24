import XCTest
@testable import MeetingPipe

final class AutomationCommandTests: XCTestCase {

    private func parse(_ s: String) -> AutomationCommand? {
        guard let url = URL(string: s) else {
            XCTFail("bad url \(s)")
            return nil
        }
        return AutomationCommand.parse(url)
    }

    func test_recording_verbs() {
        XCTAssertEqual(parse("meetingpipe://record"), .record(byo: false))
        XCTAssertEqual(parse("meetingpipe://start"), .record(byo: false))
        XCTAssertEqual(parse("meetingpipe://toggle"), .toggle)
        XCTAssertEqual(parse("meetingpipe://stop"), .stop)
        XCTAssertEqual(parse("meetingpipe://digest"), .digest)
    }

    func test_byo_variants() {
        XCTAssertEqual(parse("meetingpipe://byo"), .record(byo: true))
        XCTAssertEqual(parse("meetingpipe://record?byo=1"), .record(byo: true))
        XCTAssertEqual(parse("meetingpipe://record?byo=true"), .record(byo: true))
        XCTAssertEqual(parse("meetingpipe://record?byo"), .record(byo: true))
        XCTAssertEqual(parse("meetingpipe://record?byo=0"), .record(byo: false))
        XCTAssertEqual(parse("meetingpipe://record/byo"), .record(byo: true))
    }

    func test_open_library_scopes() {
        XCTAssertEqual(parse("meetingpipe://library"), .openLibrary(scope: nil))
        XCTAssertEqual(parse("meetingpipe://open"), .openLibrary(scope: nil))
        XCTAssertEqual(parse("meetingpipe://library?scope=ask"), .openLibrary(scope: "ask"))
        XCTAssertEqual(parse("meetingpipe://library?scope=digests"), .openLibrary(scope: "digests"))
        XCTAssertEqual(parse("meetingpipe://library?scope=facts"), .openLibrary(scope: "facts"))
        // An empty scope collapses to the default (all meetings), not "".
        XCTAssertEqual(parse("meetingpipe://library?scope="), .openLibrary(scope: nil))
    }

    // MARK: - AUTO2: open?stem=&t=

    func test_open_meeting_deeplink() {
        XCTAssertEqual(parse("meetingpipe://open?stem=20260722-140312&t=754"),
                       .openMeeting(stem: "20260722-140312", seek: 754))
        // The fraction survives: an anchor is snapped to a segment start, and
        // truncating it would land the jump on the previous row.
        XCTAssertEqual(parse("meetingpipe://open?stem=20260722-140312&t=754.32"),
                       .openMeeting(stem: "20260722-140312", seek: 754.32))
        // `library` is `open`'s synonym everywhere else, so it takes a stem too.
        XCTAssertEqual(parse("meetingpipe://library?stem=abc&t=0"),
                       .openMeeting(stem: "abc", seek: 0))
    }

    func test_open_meeting_percent_encoded_stem() {
        XCTAssertEqual(parse("meetingpipe://open?stem=20260722%20%D0%95%D0%BA%D1%81&t=1"),
                       .openMeeting(stem: "20260722 Екс", seek: 1))
        // A stem that tried to smuggle a second parameter arrives as one string.
        XCTAssertEqual(parse("meetingpipe://open?stem=a%26t%3D9"),
                       .openMeeting(stem: "a&t=9", seek: nil))
    }

    func test_open_meeting_missing_or_garbage_time_still_opens_the_meeting() {
        for url in [
            "meetingpipe://open?stem=abc",
            "meetingpipe://open?stem=abc&t=",
            "meetingpipe://open?stem=abc&t=soon",
            "meetingpipe://open?stem=abc&t=-12",
            "meetingpipe://open?stem=abc&t=nan",
            "meetingpipe://open?stem=abc&t=inf",
        ] {
            XCTAssertEqual(parse(url), .openMeeting(stem: "abc", seek: nil), "for \(url)")
        }
    }

    func test_bare_open_and_scopes_are_unchanged_by_auto2() {
        // An empty or whitespace stem is not a meeting address; it must not
        // shadow the shipped rail behaviour.
        XCTAssertEqual(parse("meetingpipe://open?stem="), .openLibrary(scope: nil))
        XCTAssertEqual(parse("meetingpipe://open?stem=%20"), .openLibrary(scope: nil))
        XCTAssertEqual(parse("meetingpipe://library?scope=facts&stem="), .openLibrary(scope: "facts"))
    }

    func test_open_meeting_verb_name_for_the_event_log() {
        XCTAssertEqual(AutomationCommand.openMeeting(stem: "abc", seek: 1).verb, "open_meeting")
    }

    // MARK: - AUTO2: where the deeplink lands

    func test_known_stem_opens_the_meeting_with_the_seek_pending() {
        XCTAssertEqual(
            TranscriptDeeplink.resolve(
                stem: "abc", seek: 754.32, knownStems: ["abc", "def"], hasLoadedOnce: true
            ),
            .openMeeting(stem: "abc", seek: 754.32)
        )
        // No time: still the meeting's transcript, just no scroll.
        XCTAssertEqual(
            TranscriptDeeplink.resolve(
                stem: "abc", seek: nil, knownStems: ["abc"], hasLoadedOnce: true
            ),
            .openMeeting(stem: "abc", seek: nil)
        )
    }

    func test_unknown_stem_opens_the_library_without_a_seek() {
        // A stale note or a renamed recording: quiet, no alert.
        XCTAssertEqual(
            TranscriptDeeplink.resolve(
                stem: "gone", seek: 12, knownStems: ["abc"], hasLoadedOnce: true
            ),
            .libraryOnly
        )
        XCTAssertEqual(
            TranscriptDeeplink.resolve(
                stem: "gone", seek: 12, knownStems: [], hasLoadedOnce: true
            ),
            .libraryOnly
        )
    }

    func test_an_unscanned_library_waits_rather_than_calling_the_stem_unknown() {
        // The usual case: the click wakes a Library that has never scanned, so
        // deciding on the empty list would send every valid link to `libraryOnly`.
        XCTAssertEqual(
            TranscriptDeeplink.resolve(
                stem: "abc", seek: 12, knownStems: [], hasLoadedOnce: false
            ),
            .wait
        )
    }

    func test_ask() {
        XCTAssertEqual(parse("meetingpipe://ask?q=what%20did%20we%20decide"),
                       .ask(question: "what did we decide"))
        XCTAssertEqual(parse("meetingpipe://ask?question=next%20steps"),
                       .ask(question: "next steps"))
        // A bare `ask` with no question is not a command (nothing to run).
        XCTAssertNil(parse("meetingpipe://ask"))
        XCTAssertNil(parse("meetingpipe://ask?q="))
    }

    func test_case_insensitive_scheme_and_verb() {
        XCTAssertEqual(parse("MeetingPipe://TOGGLE"), .toggle)
        XCTAssertEqual(parse("meetingpipe://Record"), .record(byo: false))
    }

    func test_unknown_and_foreign_schemes_are_nil() {
        XCTAssertNil(parse("meetingpipe://frobnicate"))
        XCTAssertNil(parse("meetingpipe://"))
        XCTAssertNil(parse("https://example.com/toggle"))
        XCTAssertNil(parse("otherapp://toggle"))
    }
}
