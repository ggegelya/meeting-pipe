import XCTest
@testable import MeetingPipe

final class StateTests: XCTestCase {

    func testIdleAcceptsPrompts() {
        XCTAssertTrue(AppState.idle.isAcceptingPrompts)
    }

    func testNonIdleStatesRejectPrompts() {
        let src = AppSource(bundleID: "us.zoom.xos", displayName: "Zoom")
        let url = URL(fileURLWithPath: "/tmp/x.wav")

        XCTAssertFalse(AppState.prompting(source: src).isAcceptingPrompts)
        XCTAssertFalse(AppState.suppressed(source: src).isAcceptingPrompts)
        XCTAssertFalse(AppState.recording(file: url, source: src, summaryMode: .auto).isAcceptingPrompts)
        XCTAssertFalse(AppState.stopping(file: url, source: src, summaryMode: .auto).isAcceptingPrompts)
    }

    func testAppSourceEquality() {
        let a = AppSource(bundleID: "us.zoom.xos", displayName: "Zoom")
        let b = AppSource(bundleID: "us.zoom.xos", displayName: "Zoom")
        let c = AppSource(bundleID: "com.microsoft.teams2", displayName: "Teams")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testAppSourceHashable() {
        let a = AppSource(bundleID: "us.zoom.xos", displayName: "Zoom")
        let b = AppSource(bundleID: "us.zoom.xos", displayName: "Zoom")
        var set: Set<AppSource> = []
        set.insert(a)
        set.insert(b)
        XCTAssertEqual(set.count, 1)
    }
}
