import ApplicationServices
import XCTest
@testable import MeetingPipeCore

final class AXMuteButtonProbeTests: XCTestCase {

    private func stubElement() -> AXUIElement {
        AXUIElementCreateSystemWide()
    }

    private static let catalogue: MuteLabels = {
        try! MuteLabelsLoader.loadDefault()
    }()

    private func makeProbe(
        app: String = "teams",
        bus: AXObserverBus = AXObserverBus(),
        probe: @escaping AXMuteButtonProbe.Probe,
        scheduler: @escaping AXMuteButtonProbe.Scheduler = { _, _ in {} },
        locale: String = "en"
    ) -> AXMuteButtonProbe {
        AXMuteButtonProbe(
            app: app,
            axBus: bus,
            catalogue: Self.catalogue,
            probe: probe,
            scheduler: scheduler,
            localeResolver: { locale }
        )
    }

    func test_initial_evaluation_emits_event_with_recognised_state() throws {
        var events: [AXMuteButtonProbe.Event] = []
        let probe = makeProbe(probe: { _ in
            .init(title: "Unmute", help: nil, description: nil)
        })
        probe.onChange = { events.append($0) }
        try probe.start(pid: 1, bundleID: "com.microsoft.teams2", button: stubElement())
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].state, .muted)
        XCTAssertEqual(events[0].label, "Unmute")
        XCTAssertEqual(events[0].locale, "en")
    }

    func test_repeat_evaluation_does_not_re_emit() throws {
        var events: [AXMuteButtonProbe.Event] = []
        let probe = makeProbe(probe: { _ in
            .init(title: "Mute", help: nil, description: nil)
        })
        probe.onChange = { events.append($0) }
        try probe.start(pid: 1, bundleID: "com.microsoft.teams2", button: stubElement())
        probe.evaluate(reason: "test")
        XCTAssertEqual(events.count, 1)
    }

    func test_label_transition_emits_new_event() throws {
        var label = "Unmute"
        var events: [AXMuteButtonProbe.Event] = []
        let probe = makeProbe(probe: { _ in
            .init(title: label, help: nil, description: nil)
        })
        probe.onChange = { events.append($0) }
        try probe.start(pid: 1, bundleID: "com.microsoft.teams2", button: stubElement())
        label = "Mute"
        probe.evaluate(reason: "test")
        XCTAssertEqual(events.map(\.state), [.muted, .unmuted])
    }

    func test_german_locale_uses_de_labels() throws {
        var events: [AXMuteButtonProbe.Event] = []
        let probe = makeProbe(
            probe: { _ in .init(title: "Stummschaltung aufheben", help: nil, description: nil) },
            locale: "de"
        )
        probe.onChange = { events.append($0) }
        try probe.start(pid: 1, bundleID: "com.microsoft.teams2", button: stubElement())
        XCTAssertEqual(events.first?.state, .muted)
        XCTAssertEqual(events.first?.locale, "de")
    }

    func test_unknown_locale_emits_unknown_state() throws {
        var events: [AXMuteButtonProbe.Event] = []
        let probe = makeProbe(
            probe: { _ in .init(title: "Couper le son", help: nil, description: nil) },
            locale: "fr"
        )
        probe.onChange = { events.append($0) }
        try probe.start(pid: 1, bundleID: "com.microsoft.teams2", button: stubElement())
        XCTAssertEqual(events.first?.state, .unknown)
    }

    func test_stop_releases_two_ax_subscriptions() throws {
        let bus = AXObserverBus()
        let probe = makeProbe(bus: bus, probe: { _ in
            .init(title: "Unmute", help: nil, description: nil)
        })
        try probe.start(pid: 1, bundleID: "com.microsoft.teams2", button: stubElement())
        XCTAssertEqual(bus.activeSubscriptionCount, 2)
        probe.stop()
        XCTAssertEqual(bus.activeSubscriptionCount, 0)
    }
}

final class MicGateAdapterTests: XCTestCase {

    private static let catalogue: MuteLabels = {
        try! MuteLabelsLoader.loadDefault()
    }()

    private let teamsContext = MeetingLifecycleContext(
        bundleID: "com.microsoft.teams2", kind: .native, pid: 1234
    )

    func test_teams_adapter_routes_teams_bundle_ids() {
        let adapter = TeamsMuteAdapter(axBus: AXObserverBus(), catalogue: Self.catalogue)
        XCTAssertEqual(adapter.app, "teams")
        XCTAssertTrue(adapter.bundleIDs.contains("com.microsoft.teams2"))
    }

    func test_zoom_adapter_routes_zoom_bundle_id() {
        let adapter = ZoomMuteAdapter(axBus: AXObserverBus(), catalogue: Self.catalogue)
        XCTAssertEqual(adapter.app, "zoom")
        XCTAssertEqual(adapter.bundleIDs, ["us.zoom.xos"])
    }

    func test_slack_adapter_routes_slack_bundle_id() {
        let adapter = SlackMuteAdapter(axBus: AXObserverBus(), catalogue: Self.catalogue)
        XCTAssertEqual(adapter.app, "slack")
        XCTAssertEqual(adapter.bundleIDs, ["com.tinyspeck.slackmacgap"])
    }

    func test_adapter_start_does_nothing_without_mute_button_handle() throws {
        let bus = AXObserverBus()
        let adapter = TeamsMuteAdapter(axBus: bus, catalogue: Self.catalogue)
        try adapter.start(
            context: teamsContext,
            handle: MicGateAdapterHandle(muteButton: nil),
            sink: { _ in }
        )
        XCTAssertEqual(bus.activeSubscriptionCount, 0)
    }
}
