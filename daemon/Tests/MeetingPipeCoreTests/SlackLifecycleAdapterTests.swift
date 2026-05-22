import XCTest
@testable import MeetingPipeCore

final class SlackLifecycleAdapterTests: XCTestCase {

    func test_advertises_native_slack_bundle_id() {
        let adapter = NativeLifecycleAdapter(config: .slack, axBus: AXObserverBus())
        XCTAssertEqual(adapter.kind, .native)
        XCTAssertEqual(adapter.bundleIDs, ["com.tinyspeck.slackmacgap"])
    }

    func test_huddle_title_pattern_recognises_huddle_window() {
        XCTAssertTrue(MeetingTitlePatterns.slackHuddle("Huddle | #engineering"))
        XCTAssertTrue(MeetingTitlePatterns.slackHuddle("In huddle - daily-sync"))
        XCTAssertFalse(MeetingTitlePatterns.slackHuddle("#general - Slack"))
    }

    func test_browser_adapter_includes_huddle_matcher() {
        let matchers = BrowserMeetingLifecycleAdapter.defaultTitleMatchers
        XCTAssertTrue(matchers.contains { $0("Huddle | #standup") })
    }
}
