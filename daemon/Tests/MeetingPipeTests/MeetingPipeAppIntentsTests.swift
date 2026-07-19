import XCTest
@testable import MeetingPipe

/// The drift fence for AUTO1's native App Intents.
///
/// `MeetingPipeAppIntents.swift` is deliberately dependency-free (install.sh
/// compiles it standalone to emit App Intents metadata), so it builds its
/// `meetingpipe://` URLs from string literals instead of reusing
/// `AutomationCommand`. That buys the standalone compile at the cost of two
/// copies of the verb vocabulary. These tests are what stops the copies from
/// diverging: every URL an intent would open is parsed back through the real
/// router's parser and asserted to be the command that intent claims to run.
/// A renamed verb, a dropped query key, or a typo fails here rather than
/// shipping an action that silently does nothing.
final class MeetingPipeAppIntentsTests: XCTestCase {

    private func command(_ url: URL?) -> AutomationCommand? {
        guard let url else {
            XCTFail("intent produced no URL")
            return nil
        }
        return AutomationCommand.parse(url)
    }

    func test_toggle_intent_routes_to_toggle() {
        XCTAssertEqual(command(ToggleRecordingIntent.url), .toggle)
    }

    func test_stop_intent_routes_to_stop() {
        XCTAssertEqual(command(StopRecordingIntent.url), .stop)
    }

    func test_digest_intent_routes_to_digest() {
        XCTAssertEqual(command(GenerateDigestIntent.url), .digest)
    }

    func test_start_intent_carries_the_byo_flag() {
        XCTAssertEqual(command(StartRecordingIntent.url(byo: false)), .record(byo: false))
        XCTAssertEqual(command(StartRecordingIntent.url(byo: true)), .record(byo: true))
    }

    func test_open_library_intent_maps_every_rail() {
        XCTAssertEqual(command(OpenLibraryIntent.url(rail: .allMeetings)), .openLibrary(scope: nil))
        XCTAssertEqual(command(OpenLibraryIntent.url(rail: .ask)), .openLibrary(scope: "ask"))
        XCTAssertEqual(command(OpenLibraryIntent.url(rail: .digests)), .openLibrary(scope: "digests"))
        XCTAssertEqual(command(OpenLibraryIntent.url(rail: .facts)), .openLibrary(scope: "facts"))
    }

    /// Every rail token the enum can emit has to be one the router recognises,
    /// so adding a case without teaching `Coordinator+Automation` fails here.
    func test_every_rail_token_is_a_scope_the_router_accepts() {
        for rail in [LibraryRailAppEnum.allMeetings, .ask, .digests, .facts] {
            XCTAssertEqual(command(OpenLibraryIntent.url(rail: rail)),
                           .openLibrary(scope: rail.scopeToken),
                           "rail \(rail.rawValue) did not round-trip")
        }
    }

    func test_ask_intent_percent_encodes_the_question() {
        XCTAssertEqual(command(AskLibraryIntent.url(question: "what did we decide?")),
                       .ask(question: "what did we decide?"))
        XCTAssertEqual(command(AskLibraryIntent.url(question: "next steps & owners")),
                       .ask(question: "next steps & owners"))
    }

    /// A blank question is not a command the router accepts (`meetingpipe://ask`
    /// with no `q` parses to nil), so the intent must not build a URL at all.
    func test_ask_intent_refuses_a_blank_question() {
        XCTAssertNil(AskLibraryIntent.url(question: ""))
        XCTAssertNil(AskLibraryIntent.url(question: "   \n "))
    }
}
