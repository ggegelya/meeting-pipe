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

    // MARK: - Late-arm (armIfNeeded)

    func test_armIfNeeded_arms_a_fresh_signal() {
        let bus = AXObserverBus()
        let scheduler = ManualScheduler()
        var observed: [AXLeaveButtonSignal.State] = []
        let signal = AXLeaveButtonSignal(
            axBus: bus,
            probe: { _ in .healthy },
            scheduler: manualScheduler(scheduler)
        )
        signal.onChange = { observed.append($0) }

        XCTAssertFalse(signal.isArmed)
        signal.armIfNeeded(context: teamsContext, leaveButton: stubElement())

        XCTAssertTrue(signal.isArmed, "Late-arm subscribes the signal like start()")
        XCTAssertEqual(observed, [.healthy], "Late-arm emits the healthy baseline")
        XCTAssertEqual(bus.activeSubscriptionCount, 1)
    }

    func test_armIfNeeded_is_noop_when_already_armed() throws {
        let bus = AXObserverBus()
        let scheduler = ManualScheduler()
        var observed: [AXLeaveButtonSignal.State] = []
        let signal = AXLeaveButtonSignal(
            axBus: bus,
            probe: { _ in .healthy },
            scheduler: manualScheduler(scheduler)
        )
        signal.onChange = { observed.append($0) }

        try signal.start(context: teamsContext, leaveButton: stubElement())
        XCTAssertEqual(observed, [.healthy])

        // The recording-start late-arm racing an engage-time arm must
        // not re-subscribe or re-emit the baseline.
        signal.armIfNeeded(context: teamsContext, leaveButton: stubElement())

        XCTAssertEqual(observed, [.healthy], "Already-armed signal absorbs the late-arm")
        XCTAssertEqual(bus.activeSubscriptionCount, 1)
    }

    func test_late_armed_signal_detects_leave() {
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

        // A signal armed only via the late-arm path still flips to
        // .invalid when the Leave button is destroyed.
        signal.armIfNeeded(context: teamsContext, leaveButton: stubElement())
        probeReturn = .invalid
        scheduler.tick?()

        XCTAssertEqual(observed, [.healthy, .invalid])
    }

    // MARK: - TECH-END2 re-walk (screen-share false-invalid rescue)

    func test_rewalk_recovers_a_transiently_invalid_element() throws {
        let log = RecordingEventLog()
        let bus = AXObserverBus()
        let scheduler = ManualScheduler()
        let staleButton = AXUIElementCreateApplication(92001)
        let liveButton = AXUIElementCreateApplication(92002)
        var observed: [AXLeaveButtonSignal.State] = []
        // The cached element probes invalid (call-UI re-render staled it); the
        // fresh-walk element is healthy.
        let signal = AXLeaveButtonSignal(
            axBus: bus,
            eventLog: log,
            probe: { element in CFEqual(element, liveButton) ? .healthy : .invalid },
            scheduler: manualScheduler(scheduler)
        )
        signal.onChange = { observed.append($0) }

        try signal.start(
            context: teamsContext,
            leaveButton: staleButton,
            resolveElement: { liveButton }
        )

        // The re-walk swaps to the live control, so no false .invalid (no false end).
        XCTAssertEqual(observed, [.healthy], "Re-walk rescues the transiently-stale element")
        XCTAssertTrue(log.entries.contains { $0.action == "ax_leave_button_rearmed" })

        // A later poll reads the swapped (live) element: still healthy, no flap.
        scheduler.tick?()
        XCTAssertEqual(observed, [.healthy])
    }

    func test_rewalk_failure_still_emits_invalid() throws {
        let bus = AXObserverBus()
        let scheduler = ManualScheduler()
        var observed: [AXLeaveButtonSignal.State] = []
        // A genuine leave: neither the cached element nor the fresh walk is healthy,
        // so the signal must still report .invalid for the engine to act on.
        let signal = AXLeaveButtonSignal(
            axBus: bus,
            probe: { _ in .invalid },
            scheduler: manualScheduler(scheduler)
        )
        signal.onChange = { observed.append($0) }

        try signal.start(
            context: teamsContext,
            leaveButton: AXUIElementCreateApplication(92003),
            resolveElement: { AXUIElementCreateApplication(92004) }
        )
        XCTAssertEqual(observed, [.invalid], "No live control anywhere still emits invalid")
    }

    func test_invalid_without_resolver_emits_invalid_as_before() throws {
        // Browser path / no resolver: behaviour is unchanged.
        let bus = AXObserverBus()
        let scheduler = ManualScheduler()
        var observed: [AXLeaveButtonSignal.State] = []
        let signal = AXLeaveButtonSignal(
            axBus: bus,
            probe: { _ in .invalid },
            scheduler: manualScheduler(scheduler)
        )
        signal.onChange = { observed.append($0) }
        try signal.start(context: teamsContext, leaveButton: stubElement())
        XCTAssertEqual(observed, [.invalid])
    }

    func test_armIfNeeded_rearms_when_current_element_is_dead() throws {
        let bus = AXObserverBus()
        let scheduler = ManualScheduler()
        let deadButton = AXUIElementCreateApplication(91001)
        let liveButton = AXUIElementCreateApplication(91002)
        var observed: [AXLeaveButtonSignal.State] = []
        let signal = AXLeaveButtonSignal(
            axBus: bus,
            probe: { element in CFEqual(element, liveButton) ? .healthy : .invalid },
            scheduler: manualScheduler(scheduler)
        )
        signal.onChange = { observed.append($0) }

        // Armed on the meeting window's Leave button, which probes
        // invalid: the Teams compact-view swap destroyed it.
        try signal.start(context: teamsContext, leaveButton: deadButton)
        XCTAssertEqual(observed, [.invalid])

        // The orchestrator re-walked and found the replacement on the
        // compact panel. The re-arm must take even though the signal
        // still holds the (dead) original element.
        signal.armIfNeeded(context: teamsContext, leaveButton: liveButton)

        XCTAssertEqual(observed, [.invalid, .healthy], "Re-arm onto a live button resumes the signal")
        XCTAssertTrue(signal.isArmed)
    }
}
