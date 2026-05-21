import ApplicationServices
import XCTest
@testable import MeetingPipeCore

final class AXLeaveButtonSignalTests: XCTestCase {

    private let teamsContext = MeetingLifecycleContext(
        bundleID: "com.microsoft.teams2",
        kind: .native,
        pid: 1234
    )

    private func stubElement() -> AXUIElement {
        AXUIElementCreateSystemWide()
    }

    private func manualScheduler(_ store: ManualScheduler) -> AXLeaveButtonSignal.Scheduler {
        return { _, action in
            store.tick = action
            return { store.tick = nil }
        }
    }

    final class ManualScheduler { var tick: (() -> Void)? }

    func test_initial_healthy_state_emits_live_baseline() throws {
        let log = RecordingEventLog()
        let bus = AXObserverBus()
        let scheduler = ManualScheduler()
        var observed: [AXLeaveButtonSignal.State] = []
        let signal = AXLeaveButtonSignal(
            axBus: bus,
            eventLog: log,
            probe: { _ in .healthy },
            scheduler: manualScheduler(scheduler)
        )
        signal.onChange = { observed.append($0) }

        try signal.start(context: teamsContext, leaveButton: stubElement())
        XCTAssertEqual(observed, [.healthy], "Healthy baseline emits so PromotionEngine can promote to .inMeeting")
        XCTAssertEqual(signal.lastState, .healthy)
    }

    func test_invalid_transition_emits_once() throws {
        let bus = AXObserverBus()
        let scheduler = ManualScheduler()
        var probeReturn: AXLeaveButtonSignal.State = .healthy
        var observed: [AXLeaveButtonSignal.State] = []
        let signal = AXLeaveButtonSignal(
            axBus: bus,
            probe: { _ in probeReturn },
            scheduler: manualScheduler(scheduler)
        )
        signal.onChange = { observed.append($0) }

        try signal.start(context: teamsContext, leaveButton: stubElement())
        probeReturn = .invalid
        scheduler.tick?()
        scheduler.tick?()

        XCTAssertEqual(observed, [.healthy, .invalid], "Healthy baseline, then the invalid edge fires exactly once")
    }

    func test_health_poll_catches_dropped_destruction_notification() throws {
        let log = RecordingEventLog()
        let bus = AXObserverBus()
        let scheduler = ManualScheduler()
        var probeReturn: AXLeaveButtonSignal.State = .healthy
        var observed: [AXLeaveButtonSignal.State] = []
        let signal = AXLeaveButtonSignal(
            axBus: bus,
            eventLog: log,
            probe: { _ in probeReturn },
            scheduler: manualScheduler(scheduler)
        )
        signal.onChange = { observed.append($0) }

        try signal.start(context: teamsContext, leaveButton: stubElement())
        probeReturn = .invalid
        scheduler.tick?()

        XCTAssertEqual(observed, [.healthy, .invalid])
        XCTAssertTrue(log.entries.contains { entry in
            entry.action == "ax_leave_button_state" && entry.attributes["reason"] == "health_poll"
        })
    }

    func test_stop_releases_bus_subscription() throws {
        let bus = AXObserverBus()
        let scheduler = ManualScheduler()
        let signal = AXLeaveButtonSignal(
            axBus: bus,
            probe: { _ in .healthy },
            scheduler: manualScheduler(scheduler)
        )

        try signal.start(context: teamsContext, leaveButton: stubElement())
        XCTAssertEqual(bus.activeSubscriptionCount, 1)

        signal.stop()
        XCTAssertEqual(bus.activeSubscriptionCount, 0)
        XCTAssertNil(signal.lastState)
    }
}
