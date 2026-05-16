import XCTest
@testable import MeetingPipeCore

final class MeetingLifecycleVerdictTests: XCTestCase {

    private let teamsContext = MeetingLifecycleContext(
        bundleID: "com.microsoft.teams2",
        kind: .native,
        pid: 1234,
        title: "Weekly sync"
    )

    func test_idle_equals_idle() {
        XCTAssertEqual(MeetingLifecycleVerdict.idle, .idle)
    }

    func test_in_meeting_equality_keyed_on_context() {
        XCTAssertEqual(
            MeetingLifecycleVerdict.inMeeting(context: teamsContext),
            .inMeeting(context: teamsContext)
        )
        let other = MeetingLifecycleContext(
            bundleID: "us.zoom.xos", kind: .native, pid: 1234
        )
        XCTAssertNotEqual(
            MeetingLifecycleVerdict.inMeeting(context: teamsContext),
            .inMeeting(context: other)
        )
    }

    func test_ended_equality_keyed_on_reason() {
        let r1 = EndingReason(
            leadingSignal: "shareable_content_window_gone",
            confirmedBy: ["process_audio_is_running_input_false"]
        )
        let r2 = EndingReason(
            leadingSignal: "shareable_content_window_gone",
            confirmedBy: []
        )
        XCTAssertNotEqual(
            MeetingLifecycleVerdict.ended(context: teamsContext, reason: r1),
            .ended(context: teamsContext, reason: r2)
        )
    }

    func test_cross_case_inequality() {
        let reason = EndingReason(leadingSignal: "shareable_content_window_gone")
        XCTAssertNotEqual(
            MeetingLifecycleVerdict.endingProvisional(context: teamsContext, reason: reason),
            .ended(context: teamsContext, reason: reason)
        )
        XCTAssertNotEqual(MeetingLifecycleVerdict.idle, .inMeeting(context: teamsContext))
    }
}
