import XCTest
@testable import MeetingPipe

/// UX10: pins the `AppSource` <-> notification `userInfo` bridge that lets the
/// timeout-skip "Start recording" action rebuild the source after the in-memory
/// prompt state is gone. The notification wiring itself (post + delegate routing)
/// needs a live `Coordinator` and is verified by build + review; this pins the
/// pure round-trip, including the `nil` guard that stops a malformed payload from
/// starting an anonymous recording.
final class AppSourceTests: XCTestCase {

    func test_userInfo_roundTrips_native_source() {
        let source = AppSource(
            bundleID: "com.microsoft.teams2",
            displayName: "Microsoft Teams",
            kind: .native,
            meetingTitle: "Weekly sync"
        )
        let restored = AppSource(notificationUserInfo: source.notificationUserInfo)
        XCTAssertEqual(restored, source)
        XCTAssertEqual(restored?.meetingTitle, "Weekly sync")
        XCTAssertEqual(restored?.kind, .native)
    }

    func test_userInfo_roundTrips_browser_source() {
        let source = AppSource(
            bundleID: "com.google.Chrome",
            displayName: "Google Chrome",
            kind: .browser
        )
        let restored = AppSource(notificationUserInfo: source.notificationUserInfo)
        XCTAssertEqual(restored, source)
        XCTAssertEqual(restored?.kind, .browser)
        // Equatable excludes meetingTitle; assert the absent title survives too.
        XCTAssertNil(restored?.meetingTitle)
    }

    func test_userInfo_omits_absent_title() {
        let source = AppSource(bundleID: "us.zoom.xos", displayName: "Zoom")
        XCTAssertNil(source.notificationUserInfo["meeting_title"])
    }

    func test_init_returns_nil_without_identity_keys() {
        XCTAssertNil(AppSource(notificationUserInfo: [:]))
        XCTAssertNil(AppSource(notificationUserInfo: ["bundle_id": "us.zoom.xos"]))
        XCTAssertNil(AppSource(notificationUserInfo: ["display_name": "Zoom"]))
    }
}
