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

    /// Hand-cranked clock for the fresh-walk throttle. `now: { clock.now }`
    /// lets a test fire poll ticks without real time passing, then advance past
    /// `slowPollInterval` to release the next throttled walk.
    final class MutableClock {
        var now: Date
        init(_ start: Date) { self.now = start }
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

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

    func test_sustained_invalid_logs_once_not_every_poll() throws {
        let log = RecordingEventLog()
        let bus = AXObserverBus()
        let scheduler = ManualScheduler()
        var probeReturn: AXLeaveButtonSignal.State = .healthy
        let signal = AXLeaveButtonSignal(
            axBus: bus,
            eventLog: log,
            probe: { _ in probeReturn },
            scheduler: manualScheduler(scheduler)
        )

        try signal.start(context: teamsContext, leaveButton: stubElement())
        // Element goes invalid and STAYS invalid across many health polls - the
        // leaked-poll case where a signal is never torn down. The event-log emit
        // must collapse to the single edge, not one line per 1 Hz tick (which was
        // 66% of the 57 MB event log in the wild).
        probeReturn = .invalid
        scheduler.tick?()
        scheduler.tick?()
        scheduler.tick?()
        scheduler.tick?()

        let invalidEmits = log.entries.filter {
            $0.action == "ax_leave_button_state" && $0.attributes["state"] == "invalid"
        }
        XCTAssertEqual(invalidEmits.count, 1, "A stuck-invalid element logs the invalid edge once, not on every poll")
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

    // MARK: - Self-arm (start without a button, adopt via the resolver)

    func test_self_arms_when_started_without_a_button() throws {
        let bus = AXObserverBus()
        let scheduler = ManualScheduler()
        let clock = MutableClock(Date(timeIntervalSince1970: 1000))
        let liveButton = AXUIElementCreateApplication(93001)
        var resolverReturn: AXUIElement?
        var observed: [AXLeaveButtonSignal.State] = []
        let signal = AXLeaveButtonSignal(
            axBus: bus,
            probe: { _ in .healthy },
            scheduler: manualScheduler(scheduler),
            now: { clock.now }
        )
        signal.onChange = { observed.append($0) }

        // Compact view at record-start: the walk found Mute but not Leave, so the
        // adapter starts the signal with no button and only the re-walk resolver.
        try signal.start(context: teamsContext, leaveButton: nil, resolveElement: { resolverReturn })
        XCTAssertFalse(signal.isArmed, "No button and an empty resolver: nothing to adopt yet")
        XCTAssertEqual(observed, [], "No baseline until a live Leave control appears")
        XCTAssertEqual(bus.activeSubscriptionCount, 0)

        // The Calling-controls Leave button renders a beat later. The self-arm
        // re-walk is the full-tree walk that wedged the main thread, so it is
        // throttled to the slow interval; advance past it before the adopting poll.
        resolverReturn = liveButton
        clock.advance(AXLeaveButtonSignal.defaultSlowPollInterval + 1)
        scheduler.tick?()
        XCTAssertTrue(signal.isArmed, "Self-armed once the resolver returns a live button")
        XCTAssertEqual(observed, [.healthy], "Adopting the late button emits the live baseline")
        XCTAssertEqual(bus.activeSubscriptionCount, 1)
    }

    func test_self_armed_signal_detects_leave() throws {
        let bus = AXObserverBus()
        let scheduler = ManualScheduler()
        let clock = MutableClock(Date(timeIntervalSince1970: 1000))
        let liveButton = AXUIElementCreateApplication(93002)
        var probeReturn: AXLeaveButtonSignal.State = .healthy
        var resolverReturn: AXUIElement?
        var observed: [AXLeaveButtonSignal.State] = []
        let signal = AXLeaveButtonSignal(
            axBus: bus,
            probe: { _ in probeReturn },
            scheduler: manualScheduler(scheduler),
            now: { clock.now }
        )
        signal.onChange = { observed.append($0) }

        try signal.start(context: teamsContext, leaveButton: nil, resolveElement: { resolverReturn })
        resolverReturn = liveButton
        clock.advance(AXLeaveButtonSignal.defaultSlowPollInterval + 1)
        scheduler.tick?()                      // self-arm walk adopts -> healthy baseline
        XCTAssertEqual(observed, [.healthy])

        // Call ends: the adopted Leave button is destroyed. The end must still fire.
        // The healthy->invalid edge bypasses the throttle, so no clock advance needed.
        probeReturn = .invalid
        scheduler.tick?()
        XCTAssertEqual(observed, [.healthy, .invalid], "A self-armed signal still reports the end")
    }

    func test_started_without_button_or_resolver_is_inert() throws {
        let bus = AXObserverBus()
        let scheduler = ManualScheduler()
        var observed: [AXLeaveButtonSignal.State] = []
        let signal = AXLeaveButtonSignal(
            axBus: bus,
            probe: { _ in .healthy },
            scheduler: manualScheduler(scheduler)
        )
        signal.onChange = { observed.append($0) }

        // Browser / AX-denied: no button, no resolver. The signal stays inert.
        try signal.start(context: teamsContext, leaveButton: nil)
        scheduler.tick?()
        XCTAssertFalse(signal.isArmed)
        XCTAssertEqual(observed, [], "Nothing to watch and nothing to adopt: no emissions")
        XCTAssertEqual(bus.activeSubscriptionCount, 0)
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

    // MARK: - Fresh-walk throttle (Teams "detected" hang)

    func test_selfarm_rewalk_is_throttled_to_the_slow_interval() throws {
        // The self-arm re-walk is the full-tree AX walk that wedged the main
        // thread when it ran on every 1 Hz poll. While no Leave button exists it
        // must fire at most once per slow interval, not once per tick.
        let bus = AXObserverBus()
        let scheduler = ManualScheduler()
        let clock = MutableClock(Date(timeIntervalSince1970: 1000))
        var walkCount = 0
        let signal = AXLeaveButtonSignal(
            axBus: bus,
            probe: { _ in .healthy },
            scheduler: manualScheduler(scheduler),
            now: { clock.now }
        )

        // No button ever appears: the resolver always returns nil but counts calls.
        try signal.start(context: teamsContext, leaveButton: nil, resolveElement: {
            walkCount += 1
            return nil
        })
        XCTAssertEqual(walkCount, 1, "start() ran the initial walk")

        // Four fast (1 s) polls, all inside the 5 s slow interval: no new walk.
        for _ in 0..<4 {
            clock.advance(1)
            scheduler.tick?()
        }
        XCTAssertEqual(walkCount, 1, "No new full re-walk inside the slow interval")

        // Crossing the slow interval lets exactly one more walk through.
        clock.advance(2)
        scheduler.tick?()
        XCTAssertEqual(walkCount, 2, "One walk per slow interval, not one per tick")
    }

    func test_sustained_invalid_does_not_rewalk_every_poll() throws {
        // The Teams "detected" hang: a cached Leave element stays invalid and the
        // re-walk never recovers it, so the full-tree walk ran on every 1 Hz poll
        // on the main thread. The edge walks once; sustained-invalid polls inside
        // the slow interval must NOT re-walk.
        let bus = AXObserverBus()
        let scheduler = ManualScheduler()
        let clock = MutableClock(Date(timeIntervalSince1970: 1000))
        let staleButton = AXUIElementCreateApplication(94001)
        var walkCount = 0
        var observed: [AXLeaveButtonSignal.State] = []
        let signal = AXLeaveButtonSignal(
            axBus: bus,
            probe: { _ in .invalid },          // nothing is ever healthy
            scheduler: manualScheduler(scheduler),
            now: { clock.now }
        )
        signal.onChange = { observed.append($0) }

        try signal.start(context: teamsContext, leaveButton: staleButton, resolveElement: {
            walkCount += 1
            return AXUIElementCreateApplication(94002)   // also probes invalid
        })
        XCTAssertEqual(walkCount, 1, "The invalid edge re-walks once (TECH-END2 recovery)")
        XCTAssertEqual(observed, [.invalid])

        // Sustained invalid across many fast polls inside the slow interval.
        for _ in 0..<4 {
            clock.advance(1)
            scheduler.tick?()
        }
        XCTAssertEqual(walkCount, 1, "Sustained-invalid polls do not re-walk every tick (the hang fix)")
        XCTAssertEqual(observed, [.invalid], "And do not re-emit")
    }

    func test_invalid_edge_recovers_even_after_a_recent_walk() throws {
        // A healthy->invalid edge must always run the recovery walk, even if a walk
        // happened seconds ago: a screen-share re-render staling the element must
        // not emit a false end just because the throttle window is still open.
        let bus = AXObserverBus()
        let scheduler = ManualScheduler()
        let clock = MutableClock(Date(timeIntervalSince1970: 1000))
        let firstLive = AXUIElementCreateApplication(95001)
        let secondLive = AXUIElementCreateApplication(95002)
        var resolverReturn: AXUIElement? = firstLive
        var walkCount = 0
        var observed: [AXLeaveButtonSignal.State] = []
        // Healthy iff the element is the current resolver target.
        let signal = AXLeaveButtonSignal(
            axBus: bus,
            probe: { element in
                (resolverReturn.map { CFEqual(element, $0) } ?? false) ? .healthy : .invalid
            },
            scheduler: manualScheduler(scheduler),
            now: { clock.now }
        )
        signal.onChange = { observed.append($0) }

        // Start stale: the edge walk adopts firstLive and goes healthy (walk #1, recent).
        try signal.start(
            context: teamsContext,
            leaveButton: AXUIElementCreateApplication(95000),
            resolveElement: {
                walkCount += 1
                return resolverReturn
            }
        )
        XCTAssertEqual(observed, [.healthy])
        XCTAssertEqual(walkCount, 1)

        // Only 1 s later (well inside the slow interval) the adopted element
        // re-renders: it stales to invalid and a fresh walk now resolves secondLive.
        clock.advance(1)
        resolverReturn = secondLive
        scheduler.tick?()

        XCTAssertEqual(walkCount, 2, "The invalid edge bypasses the throttle and re-walks")
        XCTAssertEqual(observed, [.healthy], "Recovery keeps it healthy: no false end despite the recent walk")
    }

    // MARK: - Production serial-queue path (off-main poll)

    func test_production_queue_mode_runs_poll_off_main() throws {
        // No scheduler injected => the production path: a private serial queue + a
        // DispatchSourceTimer. Proves the repeating timer drives a state change
        // end-to-end and that the poll emit runs off the main thread.
        let bus = AXObserverBus()
        let lock = NSLock()
        var probeState: AXLeaveButtonSignal.State = .healthy
        var states: [AXLeaveButtonSignal.State] = []
        var invalidEmitOnMain: Bool?
        let exp = expectation(description: "healthy baseline then a timer-driven invalid edge")

        let signal = AXLeaveButtonSignal(
            axBus: bus,
            probe: { _ in lock.lock(); defer { lock.unlock() }; return probeState },
            pollInterval: 0.05,
            slowPollInterval: 0.05
        )
        signal.onChange = { state in
            lock.lock()
            states.append(state)
            let count = states.count
            if state == .invalid { invalidEmitOnMain = Thread.isMainThread }
            lock.unlock()
            if count == 2 { exp.fulfill() }
        }

        try signal.start(context: teamsContext, leaveButton: stubElement())
        lock.lock(); probeState = .invalid; lock.unlock()   // a later timer tick flips it
        wait(for: [exp], timeout: 5.0)
        signal.stop()

        lock.lock(); let final = states; lock.unlock()
        XCTAssertEqual(final, [.healthy, .invalid], "real queue + timer: healthy baseline, then the invalid edge")
        XCTAssertEqual(invalidEmitOnMain, false, "the timer-driven poll emit runs off the main thread")
    }
}
