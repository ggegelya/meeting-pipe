import ApplicationServices
import XCTest
@testable import MeetingPipeCore

final class AXMuteButtonProbeTests: XCTestCase {

    /// An application element, never the system-wide one: the probe's default element timeout
    /// (PERF10) set on the system-wide element would change every AX call's timeout in the process.
    /// The stubbed probes never read it.
    private func stubElement(pid: pid_t = 1) -> AXUIElement {
        AXUIElementCreateApplication(pid)
    }

    private static let catalogue: MuteLabels = {
        try! MuteLabelsLoader.loadDefault()
    }()

    private let teams2 = "com.microsoft.teams2"

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
        probe.start(pid: 1, bundleID: "com.microsoft.teams2", button: stubElement())
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
        probe.start(pid: 1, bundleID: "com.microsoft.teams2", button: stubElement())
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
        probe.start(pid: 1, bundleID: "com.microsoft.teams2", button: stubElement())
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
        probe.start(pid: 1, bundleID: "com.microsoft.teams2", button: stubElement())
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
        probe.start(pid: 1, bundleID: "com.microsoft.teams2", button: stubElement())
        XCTAssertEqual(events.first?.state, .unknown)
    }

    /// Regression: Teams 2's mute button briefly shows
    /// "Mic is not available" during call setup and then drops its
    /// title entirely before the call audio session is established.
    /// Both decode to `.unknown`. The original probe propagated those
    /// to MicGate, clearing `axMute` and dropping the gate for ~90s
    /// while the user was actually muted. Latching keeps the prior
    /// known state until a real `.muted` / `.unmuted` event lands.
    func test_transient_unknown_after_muted_preserves_state() throws {
        var label: String? = "Unmute"
        var events: [AXMuteButtonProbe.Event] = []
        let probe = makeProbe(probe: { _ in
            .init(title: label, help: nil, description: nil)
        })
        probe.onChange = { events.append($0) }
        probe.start(pid: 1, bundleID: "com.microsoft.teams2", button: stubElement())
        XCTAssertEqual(events.map(\.state), [.muted])

        // Teams flips the title to something we do not recognise:
        // the probe must NOT emit and the stored state must stay .muted.
        label = "Mic is not available"
        probe.evaluate(reason: "test_transient_label")
        XCTAssertEqual(events.map(\.state), [.muted], "transient .unknown after .muted must be latched")
        XCTAssertEqual(probe.lastEvent?.state, .muted)

        // Title goes nil briefly.
        label = nil
        probe.evaluate(reason: "test_nil_label")
        XCTAssertEqual(events.map(\.state), [.muted], "nil label is .unknown and must also be latched")
        XCTAssertEqual(probe.lastEvent?.state, .muted)

        // Teams resumes normal labels: the latch lifts.
        label = "Mute"
        probe.evaluate(reason: "test_unmute_resumes")
        XCTAssertEqual(events.map(\.state), [.muted, .unmuted])
        XCTAssertEqual(probe.lastEvent?.state, .unmuted)
    }

    /// First-ever evaluation of an unrecognised label must still emit
    /// `.unknown`: there is no prior known state to latch onto, and
    /// downstream consumers need to see `.unknown` to fall through to
    /// VAD / RMS.
    func test_initial_unknown_state_still_emits() throws {
        var events: [AXMuteButtonProbe.Event] = []
        let probe = makeProbe(probe: { _ in
            .init(title: "Mic is not available", help: nil, description: nil)
        })
        probe.onChange = { events.append($0) }
        probe.start(pid: 1, bundleID: "com.microsoft.teams2", button: stubElement())
        XCTAssertEqual(events.map(\.state), [.unknown])
    }

    // MARK: - Re-arm on a stale element (TECH-MIC6)

    func test_consecutive_unknown_reresolves_the_element() throws {
        var resolveCalls = 0
        let probe = AXMuteButtonProbe(
            app: "teams", axBus: AXObserverBus(), catalogue: Self.catalogue,
            probe: { _ in .init(title: "Mic is not available", help: nil, description: nil) },
            scheduler: { _, _ in {} }, localeResolver: { "en" }, rearmThreshold: 3
        )
        probe.start(
            pid: 1, bundleID: "com.microsoft.teams2", button: stubElement(),
            resolveElement: { resolveCalls += 1; return self.stubElement() }
        )
        // start() ran one initial evaluate -> unknown #1.
        probe.evaluate(reason: "u2") // unknown #2
        XCTAssertEqual(resolveCalls, 0, "no re-resolve before N consecutive unknowns")
        probe.evaluate(reason: "u3") // unknown #3 -> threshold -> re-resolve
        XCTAssertEqual(resolveCalls, 1)
    }

    func test_known_reading_resets_the_reresolve_streak() throws {
        var label: String? = "Mic is not available" // .unknown
        var resolveCalls = 0
        let probe = AXMuteButtonProbe(
            app: "teams", axBus: AXObserverBus(), catalogue: Self.catalogue,
            probe: { _ in .init(title: label, help: nil, description: nil) },
            scheduler: { _, _ in {} }, localeResolver: { "en" }, rearmThreshold: 3
        )
        probe.start(
            pid: 1, bundleID: "com.microsoft.teams2", button: stubElement(),
            resolveElement: { resolveCalls += 1; return self.stubElement() }
        )
        probe.evaluate(reason: "u2")    // unknown #2
        label = "Unmute"                // confident .muted -> resets the streak
        probe.evaluate(reason: "known")
        label = "Mic is not available"
        probe.evaluate(reason: "u1")    // unknown #1 again
        probe.evaluate(reason: "u2")    // unknown #2
        XCTAssertEqual(resolveCalls, 0, "a confident read resets the streak before the threshold")
    }

    func test_reresolve_preserves_the_latched_state() throws {
        var label: String? = "Unmute" // .muted
        var events: [AXMuteButtonProbe.Event] = []
        let probe = AXMuteButtonProbe(
            app: "teams", axBus: AXObserverBus(), catalogue: Self.catalogue,
            probe: { _ in .init(title: label, help: nil, description: nil) },
            scheduler: { _, _ in {} }, localeResolver: { "en" }, rearmThreshold: 2
        )
        probe.onChange = { events.append($0) }
        probe.start(
            pid: 1, bundleID: "com.microsoft.teams2", button: stubElement(),
            resolveElement: { self.stubElement() }
        )
        XCTAssertEqual(events.map(\.state), [.muted])

        label = "Mic is not available" // .unknown
        probe.evaluate(reason: "u1")   // unknown #1
        probe.evaluate(reason: "u2")   // unknown #2 -> re-resolve, latch must hold
        XCTAssertEqual(events.map(\.state), [.muted], "re-resolve must not disturb the latched verdict")
        XCTAssertEqual(probe.lastEvent?.state, .muted)
    }

    func test_stop_releases_two_ax_subscriptions() throws {
        let bus = AXObserverBus()
        let probe = makeProbe(bus: bus, probe: { _ in
            .init(title: "Unmute", help: nil, description: nil)
        })
        probe.start(pid: 1, bundleID: "com.microsoft.teams2", button: stubElement())
        XCTAssertEqual(bus.activeSubscriptionCount, 2)
        probe.stop()
        XCTAssertEqual(bus.activeSubscriptionCount, 0)
    }

    // MARK: - PERF10: the production queue

    /// No scheduler injected is the production path. The poll used to be a main-run-loop `Timer`, so
    /// every health-poll read and every re-arm walk ran on main; against a hung Teams that was three
    /// 2 s reads per tick. Both now run on the probe's own queue.
    func test_productionQueue_pollReadsAndTheRearmWalk_runOffMain() {
        let threads = ThreadLog()
        let probe = AXMuteButtonProbe(
            app: "teams", axBus: AXObserverBus(), catalogue: Self.catalogue,
            probe: { _ in
                threads.note("read")
                return .init(title: "Mic is not available")   // .unknown, so the streak re-arms
            },
            localeResolver: { "en" },
            elementTimeout: { _ in },
            pollInterval: 0.02, slowPollInterval: 0.02, rearmThreshold: 2
        )
        probe.start(pid: 1, bundleID: teams2, button: stubElement(), resolveElement: {
            threads.note("resolve")
            return self.stubElement(pid: 2)
        })

        XCTAssertTrue(threads.waitFor(timeout: 5) { $0.count("read") >= 4 && $0.count("resolve") >= 1 },
                      "the poll keeps reading and the streak re-arms")
        probe.stop()
        probe.drainForTesting()
        XCTAssertEqual(threads.onMain, [], "no read and no re-arm walk ran on the main thread")
    }

    /// `AXObserverBus` delivers the value/title notifications on main. The handler hops onto the
    /// probe's queue, so the read a notification triggers runs off main too.
    func test_productionQueue_aNotificationDrivenRead_runsOffMain() {
        let threads = ThreadLog()
        let backend = FiringAXBackend()
        let probe = AXMuteButtonProbe(
            app: "teams", axBus: AXObserverBus(backend: backend), catalogue: Self.catalogue,
            probe: { _ in threads.note("read"); return .init(title: "Unmute") },
            localeResolver: { "en" },
            elementTimeout: { _ in },
            pollInterval: 60, slowPollInterval: 60   // no poll inside the test: reads are initial + notification
        )
        probe.start(pid: 1, bundleID: teams2, button: stubElement())
        probe.drainForTesting()
        XCTAssertEqual(threads.count("read"), 1, "the initial read")
        XCTAssertEqual(backend.registrationCount, 2, "value and title notifications subscribed")

        backend.fireAll()   // the bus wraps each in DispatchQueue.main.async
        let deadline = Date().addingTimeInterval(5)
        while threads.count("read") < 3, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            probe.drainForTesting()
        }
        XCTAssertEqual(threads.count("read"), 3, "one read per delivered notification")
        probe.stop()
        probe.drainForTesting()
        XCTAssertEqual(threads.onMain, [], "the notification-driven reads ran off main")
    }

    /// A read parked inside a hung client blocks neither `start`, nor a notification delivery on
    /// main, nor `stop`; and the parked read, once it returns, delivers nothing.
    func test_aBlockedRead_blocksNeitherStartNorANotificationNorStop() {
        let gate = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        let events = EventBox()
        let backend = FiringAXBackend()
        let probe = AXMuteButtonProbe(
            app: "teams", axBus: AXObserverBus(backend: backend), catalogue: Self.catalogue,
            probe: { _ in
                entered.signal()
                _ = gate.wait(timeout: .now() + 5)
                return .init(title: "Unmute")
            },
            localeResolver: { "en" },
            elementTimeout: { _ in },
            pollInterval: 60, slowPollInterval: 60
        )
        probe.onChange = { events.append($0) }

        let began = Date()
        probe.start(pid: 1, bundleID: teams2, button: stubElement())
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success, "the initial read is parked")
        backend.fireAll()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))   // deliver the notification on main
        probe.stop()
        let elapsed = Date().timeIntervalSince(began) - 0.05

        XCTAssertLessThan(elapsed, 0.5, "start, a notification delivery and stop must not wait on the read")
        gate.signal(); gate.signal(); gate.signal()   // release the parked read before the test returns
        probe.drainForTesting()
        XCTAssertEqual(events.states, [], "no onChange once stop() has returned")
    }

    /// The same for the TECH-MIC6 re-arm walk: parked, it does not hold `stop`, and once it returns
    /// its element is not adopted into the stopped session.
    func test_aBlockedRearmWalk_doesNotBlockStop_andIsNotAdopted() {
        let gate = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        let log = RecordingEventLog()
        let events = EventBox()
        let probe = AXMuteButtonProbe(
            app: "teams", axBus: AXObserverBus(), catalogue: Self.catalogue, eventLog: log,
            probe: { _ in .init(title: "Mic is not available") },
            localeResolver: { "en" },
            elementTimeout: { _ in },
            pollInterval: 60, slowPollInterval: 60, rearmThreshold: 1
        )
        probe.onChange = { events.append($0) }

        let began = Date()
        probe.start(pid: 1, bundleID: teams2, button: stubElement(), resolveElement: {
            entered.signal()
            _ = gate.wait(timeout: .now() + 5)
            return self.stubElement(pid: 2)
        })
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success, "the re-arm walk is parked")
        probe.stop()
        XCTAssertLessThan(Date().timeIntervalSince(began), 0.5, "stop must not wait on the walk")
        gate.signal()
        probe.drainForTesting()

        XCTAssertFalse(log.entries.contains { $0.action == "ax_mute_button_rearmed" },
                       "a walk that outlived its session is not adopted")
        XCTAssertEqual(events.states, [], "and its session's reading is not delivered")
    }

    /// A read in flight when `stop` runs belongs to that meeting. Started again straight away, the
    /// probe delivers the new meeting's reading and never the old one's.
    func test_stopDuringAnInFlightRead_dropsIt_andNothingReachesTheNextStart() {
        let gate = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        let calls = Counter()
        let events = EventBox()
        let probe = AXMuteButtonProbe(
            app: "teams", axBus: AXObserverBus(), catalogue: Self.catalogue,
            probe: { _ in
                if calls.increment() == 1 {
                    entered.signal()
                    _ = gate.wait(timeout: .now() + 5)
                    return .init(title: "Unmute")   // the old meeting: .muted
                }
                return .init(title: "Mute")         // the new meeting: .unmuted
            },
            localeResolver: { "en" },
            elementTimeout: { _ in },
            pollInterval: 60, slowPollInterval: 60
        )
        probe.onChange = { events.append($0) }

        probe.start(pid: 1, bundleID: teams2, button: stubElement())
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        probe.stop()
        probe.start(pid: 2, bundleID: teams2, button: stubElement(pid: 2))
        gate.signal()
        probe.drainForTesting()

        XCTAssertEqual(events.states, [.unmuted], "only the new meeting's reading is delivered")
    }

    /// A timeout set on one element bounds that element only (PERF10 amendment, leg 3), so it goes on
    /// the cached button before its first read and on every element the re-arm resolver returns.
    func test_theElementTimeout_isSetOnTheButtonAndOnEachResolvedElement() {
        let button = stubElement(pid: 101)
        let fresh = stubElement(pid: 102)
        var order: [String] = []
        let probe = makeProbeWithTimeout(
            probe: { element in
                order.append(CFEqual(element, button) ? "read button" : "read fresh")
                return .init(title: "Mic is not available")
            },
            elementTimeout: { element in
                order.append(CFEqual(element, button) ? "timeout button" : (CFEqual(element, fresh) ? "timeout fresh" : "timeout other"))
            }
        )
        probe.start(pid: 1, bundleID: teams2, button: button, resolveElement: { fresh })
        probe.evaluate(reason: "after_rearm")

        // Threshold 1: every unknown read re-arms, so the second read re-resolves (to `fresh` again)
        // and times that element once more before any later read of it.
        XCTAssertEqual(order, ["timeout button", "read button", "timeout fresh", "read fresh", "timeout fresh"])
    }

    func test_theProductionElementTimeout_isAQuarterSecond() {
        XCTAssertEqual(AXMuteButtonProbe.defaultElementReadTimeout, 0.25)
    }

    /// `start` no longer throws, so a notification that fails to subscribe is logged and the poll
    /// still reads the button, the way `AXLeaveButtonSignal` has always treated it.
    func test_aFailedSubscribe_isLogged_andTheProbeStillReads() {
        let backend = FiringAXBackend(failing: true)
        let log = RecordingEventLog()
        var events: [AXMuteButtonProbe.Event] = []
        let probe = AXMuteButtonProbe(
            app: "teams", axBus: AXObserverBus(backend: backend), catalogue: Self.catalogue, eventLog: log,
            probe: { _ in .init(title: "Unmute") },
            scheduler: { _, _ in {} }, localeResolver: { "en" }, elementTimeout: { _ in }
        )
        probe.onChange = { events.append($0) }
        probe.start(pid: 1, bundleID: teams2, button: stubElement())

        XCTAssertEqual(log.entries.filter { $0.action == "ax_mute_button_arm_failed" }.count, 2)
        XCTAssertEqual(events.map(\.state), [.muted], "the initial read still lands")
    }

    /// The one-call read against an element that answers nothing gives the empty blob, as the three
    /// single reads did. pid 0x7FFF_FFFE has no process, so AX fails the call at once.
    func test_defaultProbe_onAnElementWithNoProcess_returnsTheEmptyBlob() {
        let blob = AXMuteButtonProbe.defaultProbe(AXUIElementCreateApplication(0x7FFF_FFFE))
        XCTAssertEqual(blob, AXMuteButtonProbe.AXTextBlob())
    }

    private func makeProbeWithTimeout(
        probe: @escaping AXMuteButtonProbe.Probe,
        elementTimeout: @escaping AXMuteButtonProbe.ElementTimeout
    ) -> AXMuteButtonProbe {
        AXMuteButtonProbe(
            app: "teams", axBus: AXObserverBus(), catalogue: Self.catalogue,
            probe: probe, scheduler: { _, _ in {} }, localeResolver: { "en" },
            elementTimeout: elementTimeout, rearmThreshold: 1
        )
    }

    // MARK: - PERF19: the backoff holds in steady state

    /// Records every interval the probe arms, so the cadence is visible.
    final class IntervalScheduler {
        var tick: (() -> Void)?
        var armed: [TimeInterval] = []
        var scheduler: AXMuteButtonProbe.Scheduler {
            return { [self] interval, action in
                armed.append(interval)
                tick = action
                return { [weak self] in self?.tick = nil }
            }
        }
    }

    /// Red against the PERF5 rule: a steady mute state with quiet value/title listeners polled
    /// at 1 Hz all meeting.
    func test_steady_state_backs_off_to_slow_and_an_unknown_read_returns_fast() {
        let scheduler = IntervalScheduler()
        var title: String? = "Mute"
        let probe = makeProbe(
            probe: { _ in .init(title: title, help: nil, description: nil) },
            scheduler: scheduler.scheduler
        )
        probe.start(pid: 1, bundleID: "com.microsoft.teams2", button: stubElement())
        XCTAssertEqual(scheduler.armed, [AXMuteButtonProbe.defaultPollInterval])

        for _ in 0..<20 { scheduler.tick?() }
        XCTAssertEqual(scheduler.armed.last, AXMuteButtonProbe.defaultSlowPollInterval)
        XCTAssertEqual(scheduler.armed.count, 2, "one back-off, then slow holds")

        title = nil   // unreadable: back to 1 Hz so the MIC6 re-resolve keeps its timing
        scheduler.tick?()
        XCTAssertEqual(scheduler.armed.last, AXMuteButtonProbe.defaultPollInterval)
    }
}

// MARK: - PERF10 fakes (every field lock-guarded: the probe's queue writes them)

/// Which labelled calls ran on the main thread.
private final class ThreadLog {
    private let lock = NSLock()
    private var entries: [(label: String, onMain: Bool)] = []

    func note(_ label: String) {
        let onMain = Thread.isMainThread
        lock.withLock { entries.append((label, onMain)) }
    }

    func count(_ label: String) -> Int {
        lock.withLock { entries.filter { $0.label == label }.count }
    }

    var onMain: [String] { lock.withLock { entries.filter(\.onMain).map(\.label) } }

    func waitFor(timeout: TimeInterval, _ condition: (ThreadLog) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition(self) { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return condition(self)
    }
}

private final class EventBox {
    private let lock = NSLock()
    private var events: [AXMuteButtonProbe.Event] = []
    func append(_ event: AXMuteButtonProbe.Event) { lock.withLock { events.append(event) } }
    var states: [MuteLabels.State] { lock.withLock { events.map(\.state) } }
}

private final class Counter {
    private let lock = NSLock()
    private var value = 0
    func increment() -> Int { lock.withLock { value += 1; return value } }
}

/// Records each registered handler so a test can deliver the notification, or refuses every one.
private final class FiringAXBackend: AXObserverBus.Backend {
    private let lock = NSLock()
    private var handlers: [() -> Void] = []
    private let failing: Bool

    init(failing: Bool = false) { self.failing = failing }

    func register(
        pid: pid_t,
        element: AXUIElement,
        notification: String,
        handler: @escaping () -> Void
    ) throws -> () -> Void {
        if failing { throw AXObserverBus.BusError.backendFailed(.failure) }
        lock.withLock { handlers.append(handler) }
        return {}
    }

    var registrationCount: Int { lock.withLock { handlers.count } }

    func fireAll() {
        for handler in lock.withLock({ handlers }) { handler() }
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
        let adapter = NativeMuteAdapter(config: .teams, axBus: AXObserverBus(), catalogue: Self.catalogue)
        XCTAssertEqual(adapter.app, "teams")
        XCTAssertTrue(adapter.bundleIDs.contains("com.microsoft.teams2"))
    }

    func test_zoom_adapter_routes_zoom_bundle_id() {
        let adapter = NativeMuteAdapter(config: .zoom, axBus: AXObserverBus(), catalogue: Self.catalogue)
        XCTAssertEqual(adapter.app, "zoom")
        XCTAssertEqual(adapter.bundleIDs, ["us.zoom.xos"])
    }

    func test_slack_adapter_routes_slack_bundle_id() {
        let adapter = NativeMuteAdapter(config: .slack, axBus: AXObserverBus(), catalogue: Self.catalogue)
        XCTAssertEqual(adapter.app, "slack")
        XCTAssertEqual(adapter.bundleIDs, ["com.tinyspeck.slackmacgap"])
    }

    func test_adapter_start_does_nothing_without_mute_button_handle() throws {
        let bus = AXObserverBus()
        let adapter = NativeMuteAdapter(config: .teams, axBus: bus, catalogue: Self.catalogue)
        try adapter.start(
            context: teamsContext,
            handle: MicGateAdapterHandle(muteButton: nil),
            sink: { _ in }
        )
        XCTAssertEqual(bus.activeSubscriptionCount, 0)
    }
}
