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
