import ApplicationServices
import XCTest
@testable import MeetingPipeCore

final class LifecycleAdapterTests: XCTestCase {

    private let teamsContext = MeetingLifecycleContext(
        bundleID: "com.microsoft.teams2", kind: .native, pid: 1234
    )

    private let zoomContext = MeetingLifecycleContext(
        bundleID: "us.zoom.xos", kind: .native, pid: 5678
    )

    private let webexContext = MeetingLifecycleContext(
        bundleID: "com.cisco.spark", kind: .native, pid: 9012
    )

    private let chromeContext = MeetingLifecycleContext(
        bundleID: "com.google.Chrome", kind: .browser, pid: 3456
    )

    func test_teams_adapter_advertises_teams_bundle_ids() {
        let adapter = TeamsLifecycleAdapter(
            halBus: CoreAudioHALBus(), axBus: AXObserverBus()
        )
        XCTAssertEqual(adapter.kind, .native)
        XCTAssertTrue(adapter.bundleIDs.contains("com.microsoft.teams2"))
        XCTAssertTrue(adapter.bundleIDs.contains("com.microsoft.teams"))
    }

    func test_zoom_adapter_advertises_zoom_bundle_id() {
        let adapter = ZoomLifecycleAdapter(
            halBus: CoreAudioHALBus(), axBus: AXObserverBus()
        )
        XCTAssertEqual(adapter.kind, .native)
        XCTAssertEqual(adapter.bundleIDs, ["us.zoom.xos"])
    }

    func test_webex_adapter_covers_legacy_and_unified_bundles() {
        let adapter = WebexLifecycleAdapter(axBus: AXObserverBus())
        XCTAssertEqual(adapter.kind, .native)
        XCTAssertTrue(adapter.bundleIDs.contains("com.cisco.webexmeetingsapp"))
        XCTAssertTrue(adapter.bundleIDs.contains("com.cisco.spark"))
    }

    func test_browser_adapter_advertises_browser_kind() {
        let adapter = BrowserMeetingLifecycleAdapter()
        XCTAssertEqual(adapter.kind, .browser)
        XCTAssertTrue(adapter.bundleIDs.contains("com.google.Chrome"))
        XCTAssertTrue(adapter.bundleIDs.contains("com.apple.Safari"))
    }

    func test_teams_title_pattern_recognises_localised_meeting_token() {
        XCTAssertTrue(MeetingTitlePatterns.teams("Microsoft Teams Meeting | Standup"))
        XCTAssertTrue(MeetingTitlePatterns.teams("Besprechung in Microsoft Teams"))
        XCTAssertFalse(MeetingTitlePatterns.teams("Chat | Acme"))
    }

    func test_teams_title_pattern_matches_subject_titled_meeting_window() {
        // New-Teams meeting windows are "<subject> | Microsoft Teams" with no literal "meeting" token (the 8m47s false-stop regression).
        XCTAssertTrue(MeetingTitlePatterns.teams("Architecture priorities - Weekly sync | Microsoft Teams"))
    }

    func test_zoom_title_pattern_matches_zoom_meeting_strings() {
        XCTAssertTrue(MeetingTitlePatterns.zoom("Zoom Meeting"))
        XCTAssertTrue(MeetingTitlePatterns.zoom("Zoom - Standup"))
        XCTAssertFalse(MeetingTitlePatterns.zoom("Slack | Standup"))
    }

    func test_google_meet_pattern_requires_meet_substring() {
        XCTAssertTrue(MeetingTitlePatterns.googleMeet("Meet - abc-defg-hij"))
        XCTAssertFalse(MeetingTitlePatterns.googleMeet("Acme Inc - Mail"))
    }

    func test_browser_adapter_default_matchers_recognise_known_meeting_titles() {
        let matchers = BrowserMeetingLifecycleAdapter.defaultTitleMatchers
        let meet = "Meet - abc-defg-hij"
        let teams = "Microsoft Teams Meeting | Standup"
        let huddle = "Huddle - #engineering"
        let chat = "Slack - #general"

        XCTAssertTrue(matchers.contains { $0(meet) })
        XCTAssertTrue(matchers.contains { $0(teams) })
        XCTAssertTrue(matchers.contains { $0(huddle) })
        XCTAssertFalse(matchers.contains { $0(chat) })
    }

    func test_adapter_routing_picks_correct_adapter_per_bundle() {
        let teams = TeamsLifecycleAdapter(halBus: CoreAudioHALBus(), axBus: AXObserverBus())
        let zoom = ZoomLifecycleAdapter(halBus: CoreAudioHALBus(), axBus: AXObserverBus())
        let webex = WebexLifecycleAdapter(axBus: AXObserverBus())
        let browser = BrowserMeetingLifecycleAdapter()
        let adapters: [LifecycleAdapter] = [teams, zoom, webex, browser]

        XCTAssertTrue(adapters.first(where: {
            $0.kind == teamsContext.kind && $0.bundleIDs.contains(teamsContext.bundleID)
        }) === teams)
        XCTAssertTrue(adapters.first(where: {
            $0.kind == zoomContext.kind && $0.bundleIDs.contains(zoomContext.bundleID)
        }) === zoom)
        XCTAssertTrue(adapters.first(where: {
            $0.kind == webexContext.kind && $0.bundleIDs.contains(webexContext.bundleID)
        }) === webex)
        XCTAssertTrue(adapters.first(where: {
            $0.kind == chromeContext.kind && $0.bundleIDs.contains(chromeContext.bundleID)
        }) === browser)
    }
}
