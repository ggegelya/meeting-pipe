import ApplicationServices
import XCTest
@testable import MeetingPipeCore

final class WindowTitleSignalTests: XCTestCase {

    private let teamsContext = MeetingLifecycleContext(
        bundleID: "com.microsoft.teams2",
        kind: .native,
        pid: 1234
    )

    private func stubElement() -> AXUIElement {
        AXUIElementCreateSystemWide()
    }

    func test_initial_title_emits_baseline() throws {
        let bus = AXObserverBus()
        var observed: [String] = []
        let signal = WindowTitleSignal(axBus: bus, probe: { _ in "Standup | Meeting" })
        signal.onChange = { observed.append($0) }
        try signal.start(context: teamsContext, window: stubElement())
        XCTAssertEqual(observed, ["Standup | Meeting"])
    }

    func test_repeat_title_does_not_emit() throws {
        let bus = AXObserverBus()
        var observed: [String] = []
        let signal = WindowTitleSignal(axBus: bus, probe: { _ in "Standup" })
        signal.onChange = { observed.append($0) }
        try signal.start(context: teamsContext, window: stubElement())
        signal.evaluate(reason: "test")
        XCTAssertEqual(observed, ["Standup"])
    }

    func test_title_transition_emits_new_value() throws {
        let bus = AXObserverBus()
        var current: String? = "Standup | Meeting"
        var observed: [String] = []
        let signal = WindowTitleSignal(axBus: bus, probe: { _ in current })
        signal.onChange = { observed.append($0) }
        try signal.start(context: teamsContext, window: stubElement())
        current = "Microsoft Teams"
        signal.evaluate(reason: "test")
        XCTAssertEqual(observed, ["Standup | Meeting", "Microsoft Teams"])
    }

    func test_nil_title_does_not_re_emit_last_known() throws {
        let bus = AXObserverBus()
        var current: String? = "Standup"
        var observed: [String] = []
        let signal = WindowTitleSignal(axBus: bus, probe: { _ in current })
        signal.onChange = { observed.append($0) }
        try signal.start(context: teamsContext, window: stubElement())
        current = nil
        signal.evaluate(reason: "test")
        XCTAssertEqual(observed, ["Standup"], "Title disappearing must not surface a spurious change")
    }

    func test_stop_releases_bus_subscription() throws {
        let bus = AXObserverBus()
        let signal = WindowTitleSignal(axBus: bus, probe: { _ in "Standup" })
        try signal.start(context: teamsContext, window: stubElement())
        XCTAssertEqual(bus.activeSubscriptionCount, 1)
        signal.stop()
        XCTAssertEqual(bus.activeSubscriptionCount, 0)
        XCTAssertNil(signal.lastTitle)
    }
}
