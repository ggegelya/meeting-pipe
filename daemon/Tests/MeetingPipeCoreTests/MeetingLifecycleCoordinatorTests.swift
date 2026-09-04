import ApplicationServices
import XCTest
@testable import MeetingPipeCore

final class MeetingLifecycleCoordinatorTests: XCTestCase {

    private let teamsContext = MeetingLifecycleContext(
        bundleID: "com.microsoft.teams2",
        kind: .native,
        pid: 1234,
        title: "Weekly sync"
    )

    func test_publish_emits_event_and_advances_current_verdict() {
        let log = RecordingEventLog()
        let coordinator = MeetingLifecycleCoordinator(eventLog: log)
        XCTAssertEqual(coordinator.current, .idle)

        coordinator.publish(.starting(context: teamsContext))
        XCTAssertEqual(coordinator.current, .starting(context: teamsContext))
        XCTAssertTrue(log.entries.contains { $0.action == "starting" })

        coordinator.publish(.inMeeting(context: teamsContext))
        XCTAssertEqual(coordinator.current, .inMeeting(context: teamsContext))
    }

    func test_publish_idempotent_on_repeat() {
        let log = RecordingEventLog()
        let coordinator = MeetingLifecycleCoordinator(eventLog: log)

        coordinator.publish(.inMeeting(context: teamsContext))
        coordinator.publish(.inMeeting(context: teamsContext))

        let inMeetingEvents = log.entries.filter { $0.action == "in_meeting" }
        XCTAssertEqual(inMeetingEvents.count, 1, "Duplicate verdicts must not re-emit events")
    }

    func test_ended_event_includes_leading_signal_and_confirmed_by() {
        let log = RecordingEventLog()
        let coordinator = MeetingLifecycleCoordinator(eventLog: log)
        let reason = EndingReason(
            leadingSignal: "shareable_content_window_gone",
            confirmedBy: ["process_audio_is_running_input_false"]
        )

        coordinator.publish(.ended(context: teamsContext, reason: reason))

        guard let ended = log.entries.first(where: { $0.action == "ended" }) else {
            return XCTFail("Expected ended event")
        }
        XCTAssertEqual(ended.attributes["leading_signal"], "shareable_content_window_gone")
        XCTAssertEqual(ended.attributes["bundle_id"], "com.microsoft.teams2")
        XCTAssertNotNil(ended.attributes["confirmed_by"])
    }

    func test_verdicts_stream_delivers_published_values() async {
        let coordinator = MeetingLifecycleCoordinator()
        let iterator = AsyncStreamIterator(coordinator.verdicts)

        coordinator.publish(.starting(context: teamsContext))
        coordinator.publish(.inMeeting(context: teamsContext))
        coordinator.shutdown()

        let received = await iterator.collect()
        XCTAssertEqual(received.first, .starting(context: teamsContext))
        XCTAssertTrue(received.contains(.inMeeting(context: teamsContext)))
    }

    func test_shutdown_resets_buses() throws {
        let halBackend = CoreAudioHALBusTests.RecordingBackend()
        let axBackend = AXObserverBusTests.RecordingBackend()
        let halBus = CoreAudioHALBus(backend: halBackend)
        let axBus = AXObserverBus(backend: axBackend)
        let coordinator = MeetingLifecycleCoordinator(halBus: halBus, axBus: axBus)

        _ = try halBus.subscribe(.init(
            objectID: 1, selector: 0, scope: 0, element: 0
        )) {}
        XCTAssertEqual(halBus.activeSubscriptionCount, 1)

        coordinator.shutdown()
        XCTAssertEqual(halBus.activeSubscriptionCount, 0)
        XCTAssertEqual(axBus.activeSubscriptionCount, 0)
    }

    // MARK: - Adapter integration

    func test_engage_routes_signals_through_engine_to_verdict_stream() throws {
        let fake = FakeAdapter()
        let scheduler = ManualScheduler()
        let log = RecordingEventLog()
        var now = Date(timeIntervalSince1970: 0)
        let coordinator = MeetingLifecycleCoordinator(
            eventLog: log,
            adapters: [fake],
            scheduler: scheduler.scheduler(),
            clock: { now }
        )

        try coordinator.engage(
            context: teamsContext,
            handle: LifecycleAdapterHandle()
        )

        fake.emit(.init(
            kind: .shareableContentWindow,
            state: .live,
            timestamp: now,
            context: teamsContext
        ))
        flushEngine(coordinator)
        XCTAssertEqual(coordinator.current, .starting(context: teamsContext))

        coordinator.confirmRecording()
        flushEngine(coordinator)
        XCTAssertEqual(coordinator.current, .inMeeting(context: teamsContext))

        now = Date(timeIntervalSince1970: 1)
        fake.emit(.init(
            kind: .shareableContentWindow,
            state: .ended,
            timestamp: now,
            context: teamsContext
        ))
        flushEngine(coordinator)
        XCTAssertEqual(
            coordinator.current,
            .endingProvisional(
                context: teamsContext,
                reason: EndingReason(leadingSignal: "shareable_content_window_gone")
            )
        )

        now = Date(timeIntervalSince1970: 4)
        coordinator.tick()
        flushEngine(coordinator)
        XCTAssertEqual(
            coordinator.current,
            .ended(
                context: teamsContext,
                reason: EndingReason(leadingSignal: "shareable_content_window_gone")
            )
        )
    }

    func test_disengage_resets_engine_and_publishes_idle() throws {
        let fake = FakeAdapter()
        let scheduler = ManualScheduler()
        let coordinator = MeetingLifecycleCoordinator(
            adapters: [fake],
            scheduler: scheduler.scheduler()
        )

        try coordinator.engage(
            context: teamsContext,
            handle: LifecycleAdapterHandle()
        )
        fake.emit(.init(
            kind: .shareableContentWindow,
            state: .live,
            timestamp: Date(timeIntervalSince1970: 0),
            context: teamsContext
        ))
        flushEngine(coordinator)
        XCTAssertEqual(coordinator.current, .starting(context: teamsContext))

        coordinator.disengage()
        XCTAssertTrue(fake.didStop)
        // disengage now routes the engine reset + idle publish through engineQueue
        // (AUD-29), so .idle lands once that block drains rather than inline.
        flushEngine(coordinator)
        XCTAssertEqual(coordinator.current, .idle)
    }

    func test_event_after_disengage_is_dropped_by_generation_guard() throws {
        let fake = FakeAdapter()
        let scheduler = ManualScheduler()
        let coordinator = MeetingLifecycleCoordinator(
            adapters: [fake],
            scheduler: scheduler.scheduler()
        )

        try coordinator.engage(
            context: teamsContext,
            handle: LifecycleAdapterHandle()
        )
        coordinator.disengage()
        flushEngine(coordinator)
        XCTAssertEqual(coordinator.current, .idle)

        // A zombie event from the adapter just stopped (it captured the prior
        // generation) must not resurrect the freshly reset engine (AUD-29).
        fake.emitRetained(.init(
            kind: .shareableContentWindow,
            state: .live,
            timestamp: Date(timeIntervalSince1970: 0),
            context: teamsContext
        ))
        flushEngine(coordinator)
        XCTAssertEqual(
            coordinator.current, .idle,
            "A post-disengage event is dropped by the generation guard, not promoted to .starting"
        )
    }

    func test_engage_without_matching_adapter_logs_and_no_ops() throws {
        let log = RecordingEventLog()
        let scheduler = ManualScheduler()
        let coordinator = MeetingLifecycleCoordinator(
            eventLog: log,
            adapters: [FakeAdapter(bundleIDs: ["other.bundle"])],
            scheduler: scheduler.scheduler()
        )

        try coordinator.engage(
            context: teamsContext,
            handle: LifecycleAdapterHandle()
        )
        XCTAssertTrue(log.entries.contains { $0.action == "no_adapter_for_context" })
    }

    func test_armLeaveButton_forwards_to_active_adapter() throws {
        let fake = FakeAdapter()
        let scheduler = ManualScheduler()
        let coordinator = MeetingLifecycleCoordinator(
            adapters: [fake],
            scheduler: scheduler.scheduler()
        )

        // No adapter engaged yet: the late-arm is absorbed, not crashed.
        coordinator.armLeaveButton(AXUIElementCreateSystemWide())
        XCTAssertEqual(fake.armedLeaveButtons.count, 0)

        try coordinator.engage(
            context: teamsContext,
            handle: LifecycleAdapterHandle()
        )
        coordinator.armLeaveButton(AXUIElementCreateSystemWide())
        XCTAssertEqual(
            fake.armedLeaveButtons.count, 1,
            "Recording-start late-arm forwards to the engaged adapter"
        )
    }

    // MARK: - PERF5: tick gating

    func test_tick_is_armed_only_while_ending_provisional() throws {
        let fake = FakeAdapter()
        let scheduler = ManualScheduler()
        var now = Date(timeIntervalSince1970: 0)
        let coordinator = MeetingLifecycleCoordinator(
            adapters: [fake],
            scheduler: scheduler.scheduler(),
            clock: { now }
        )

        try coordinator.engage(context: teamsContext, handle: LifecycleAdapterHandle())
        flushEngine(coordinator)
        // PERF5: engaged but idle -> the periodic tick is not armed.
        XCTAssertNil(scheduler.tick, "tick must not run before a provisional end")

        fake.emit(.init(kind: .shareableContentWindow, state: .live, timestamp: now, context: teamsContext))
        flushEngine(coordinator)
        coordinator.confirmRecording()
        flushEngine(coordinator)
        XCTAssertEqual(coordinator.current, .inMeeting(context: teamsContext))
        XCTAssertNil(scheduler.tick, "tick stays disarmed through .starting / .inMeeting")

        now = Date(timeIntervalSince1970: 1)
        fake.emit(.init(kind: .shareableContentWindow, state: .ended, timestamp: now, context: teamsContext))
        flushEngine(coordinator)
        // PERF5: a provisional end arms the tick so the debounce can promote it.
        XCTAssertNotNil(scheduler.tick, "tick arms when a provisional end is pending")

        now = Date(timeIntervalSince1970: 4)
        coordinator.tick()
        flushEngine(coordinator)
        XCTAssertEqual(
            coordinator.current,
            .ended(context: teamsContext, reason: EndingReason(leadingSignal: "shareable_content_window_gone"))
        )
        // PERF5: promoting to .ended disarms the tick again.
        XCTAssertNil(scheduler.tick, "tick disarms once the end is confirmed")
    }

    func test_tick_disarms_when_provisional_end_reverts() throws {
        let fake = FakeAdapter()
        let scheduler = ManualScheduler()
        var now = Date(timeIntervalSince1970: 0)
        let coordinator = MeetingLifecycleCoordinator(
            adapters: [fake],
            scheduler: scheduler.scheduler(),
            clock: { now }
        )
        try coordinator.engage(context: teamsContext, handle: LifecycleAdapterHandle())
        fake.emit(.init(kind: .shareableContentWindow, state: .live, timestamp: now, context: teamsContext))
        flushEngine(coordinator)
        coordinator.confirmRecording()
        flushEngine(coordinator)

        now = Date(timeIntervalSince1970: 1)
        fake.emit(.init(kind: .shareableContentWindow, state: .ended, timestamp: now, context: teamsContext))
        flushEngine(coordinator)
        XCTAssertNotNil(scheduler.tick, "armed on the provisional end")

        // The leading signal flips back to live before the debounce: the engine
        // returns to .inMeeting (flicker-absorb) and the tick must disarm (PERF5).
        now = Date(timeIntervalSince1970: 2)
        fake.emit(.init(kind: .shareableContentWindow, state: .live, timestamp: now, context: teamsContext))
        flushEngine(coordinator)
        XCTAssertEqual(coordinator.current, .inMeeting(context: teamsContext))
        XCTAssertNil(scheduler.tick, "tick disarms when the provisional end reverts")
    }

    // MARK: - END11: engagement is observable, and a dropped arm is loud

    /// END11 acceptance bar 2. `armLeaveButton` was `activeAdapter?.armLeaveButton(element)`, so an
    /// explicit start resolved the Leave button, handed it to nobody, and left no trace. Red
    /// against `main`, where this path emitted nothing at all.
    func test_armLeaveButton_withNoAdapter_isLoudRatherThanSilent() {
        let log = RecordingEventLog()
        let coordinator = MeetingLifecycleCoordinator(eventLog: log)
        XCTAssertFalse(coordinator.isEngaged, "nothing engaged yet")

        coordinator.armLeaveButton(AXUIElementCreateApplication(1234))

        let dropped = log.entries.filter { $0.action == "arm_leave_button_dropped" }
        XCTAssertEqual(dropped.count, 1, "a dropped arm has to leave something to grep for")
        XCTAssertEqual(dropped.first?.attributes["reason"], "no_active_adapter")
    }

    /// The accessor the explicit-start guard reads. Without it the caller cannot tell an engaged
    /// session from a cold one, and `engage()` opens with `disengage()`.
    func test_isEngaged_tracksTheAdapterLifetime() throws {
        let fake = FakeAdapter()
        let coordinator = MeetingLifecycleCoordinator(adapters: [fake])
        XCTAssertFalse(coordinator.isEngaged)

        try coordinator.engage(context: teamsContext, handle: LifecycleAdapterHandle())
        XCTAssertTrue(coordinator.isEngaged, "an engaged adapter is what armLeaveButton needs")

        coordinator.disengage()
        XCTAssertFalse(coordinator.isEngaged)
    }

    /// Why the explicit-start path guards on `isEngaged` instead of just calling `engage`: engaging
    /// again tears the live adapter down and resets the engine, which mid-meeting would throw away
    /// a healthy session's state.
    func test_engagingTwice_resetsTheEngine_whichIsWhyTheGuardExists() throws {
        let fake = FakeAdapter()
        let now = Date(timeIntervalSince1970: 0)
        let coordinator = MeetingLifecycleCoordinator(adapters: [fake], clock: { now })
        try coordinator.engage(context: teamsContext, handle: LifecycleAdapterHandle())
        fake.emit(.init(kind: .shareableContentWindow, state: .live, timestamp: now, context: teamsContext))
        flushEngine(coordinator)
        coordinator.confirmRecording()
        flushEngine(coordinator)
        XCTAssertEqual(coordinator.current, .inMeeting(context: teamsContext))

        try coordinator.engage(context: teamsContext, handle: LifecycleAdapterHandle())
        flushEngine(coordinator)
        XCTAssertEqual(
            coordinator.current, .idle,
            "re-engaging resets a live meeting to idle, so an explicit start must not do it blindly"
        )
    }

    // MARK: - END13: the cross-class liveness reading

    /// The reading the teardown hold's veto is built on. Three answers, and the third is the one
    /// that matters: until the signal says something there is nothing to veto with.
    func test_liveCallSignal_tracks_process_audio_and_starts_unknown() throws {
        let fake = FakeAdapter()
        let scheduler = ManualScheduler()
        let coordinator = MeetingLifecycleCoordinator(
            adapters: [fake], scheduler: scheduler.scheduler()
        )
        XCTAssertEqual(coordinator.liveCallSignal, .unknown, "no adapter engaged is no opinion")

        try coordinator.engage(context: teamsContext, handle: LifecycleAdapterHandle())
        XCTAssertEqual(
            coordinator.liveCallSignal, .unknown,
            "the DET8 shape: an unresolved probe emits nothing, so engaging alone says nothing"
        )

        fake.emit(.init(
            kind: .processAudioIsRunningInput,
            state: .live,
            timestamp: Date(timeIntervalSince1970: 0),
            context: teamsContext
        ))
        XCTAssertEqual(coordinator.liveCallSignal, .callIsUp)

        fake.emit(.init(
            kind: .processAudioIsRunningInput,
            state: .ended,
            timestamp: Date(timeIntervalSince1970: 1),
            context: teamsContext
        ))
        XCTAssertEqual(coordinator.liveCallSignal, .callIsDown, "a real end must not keep vetoing")
    }

    /// Only the cross-class signal writes it. The lead this veto exists to override is
    /// `ax_leave_button_invalid`, and `shareableContentWindow` shares its evidence class, so
    /// neither may ever be read as independent corroboration that the call is up.
    func test_liveCallSignal_ignores_the_signals_in_the_leading_class() throws {
        let fake = FakeAdapter()
        let coordinator = MeetingLifecycleCoordinator(
            adapters: [fake], scheduler: ManualScheduler().scheduler()
        )
        try coordinator.engage(context: teamsContext, handle: LifecycleAdapterHandle())

        for kind in [PrimarySignalKind.shareableContentWindow, .axLeaveButton] {
            fake.emit(.init(
                kind: kind, state: .live, timestamp: Date(timeIntervalSince1970: 0), context: teamsContext
            ))
            XCTAssertEqual(
                coordinator.liveCallSignal, .unknown,
                "\(kind.rawValue) is the leading signal's own class, not an independent reading"
            )
        }
    }

    /// The reading belongs to the session that produced it. A veto carried into the next meeting
    /// would hold that meeting's end open on evidence from the previous call.
    func test_liveCallSignal_clears_on_disengage_and_drops_a_zombie_event() throws {
        let fake = FakeAdapter()
        let coordinator = MeetingLifecycleCoordinator(
            adapters: [fake], scheduler: ManualScheduler().scheduler()
        )
        try coordinator.engage(context: teamsContext, handle: LifecycleAdapterHandle())
        fake.emit(.init(
            kind: .processAudioIsRunningInput,
            state: .live,
            timestamp: Date(timeIntervalSince1970: 0),
            context: teamsContext
        ))
        XCTAssertEqual(coordinator.liveCallSignal, .callIsUp)

        coordinator.disengage()
        XCTAssertEqual(coordinator.liveCallSignal, .unknown)

        // The AUD-29 shape: an in-flight event from the adapter just stopped carries the prior
        // generation and must not write a veto for whatever engages next.
        fake.emitRetained(.init(
            kind: .processAudioIsRunningInput,
            state: .live,
            timestamp: Date(timeIntervalSince1970: 1),
            context: teamsContext
        ))
        XCTAssertEqual(coordinator.liveCallSignal, .unknown)
    }

    private func flushEngine(_ coordinator: MeetingLifecycleCoordinator) {
        let expectation = expectation(description: "engine drain")
        coordinator.tick()
        DispatchQueue.main.async { expectation.fulfill() }
        wait(for: [expectation], timeout: 1.0)
        // Two flushes: first ensures engine ingestion is processed; the
        // second wraps the tick we just scheduled.
        let second = self.expectation(description: "engine drain 2")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { second.fulfill() }
        wait(for: [second], timeout: 1.0)
    }
}

private final class FakeAdapter: LifecycleAdapter {
    let bundleIDs: Set<String>
    let kind: MeetingLifecycleContext.Kind
    private(set) var didStop = false
    private(set) var armedLeaveButtons: [AXUIElement] = []
    private var sink: ((PrimarySignalEvent) -> Void)?
    /// Held across `stop()` (unlike `sink`) so a test can fire a zombie event the way a
    /// real signal might after teardown, to exercise the generation guard (AUD-29).
    private var retainedSink: ((PrimarySignalEvent) -> Void)?

    init(
        bundleIDs: Set<String> = ["com.microsoft.teams2"],
        kind: MeetingLifecycleContext.Kind = .native
    ) {
        self.bundleIDs = bundleIDs
        self.kind = kind
    }

    func start(
        context: MeetingLifecycleContext,
        handle: LifecycleAdapterHandle,
        sink: @escaping (PrimarySignalEvent) -> Void
    ) throws {
        self.sink = sink
        self.retainedSink = sink
        didStop = false
    }

    func stop() {
        sink = nil
        didStop = true
    }

    func armLeaveButton(_ element: AXUIElement) {
        armedLeaveButtons.append(element)
    }

    func emit(_ event: PrimarySignalEvent) {
        sink?(event)
    }

    /// Fire through the sink captured at `start`, even after `stop()` nilled `sink`.
    func emitRetained(_ event: PrimarySignalEvent) {
        retainedSink?(event)
    }
}

private final class ManualScheduler {
    var tick: (() -> Void)?
    func scheduler() -> MeetingLifecycleCoordinator.Scheduler {
        return { _, action in
            self.tick = action
            return { self.tick = nil }
        }
    }
}

/// Drains the cold `AsyncStream` returned by the coordinator into a
/// flat array. Used because the verdict stream finishes when the
/// coordinator shuts down, so a one-shot collect is the cleanest
/// shape for assertions.
private actor AsyncStreamIterator {
    private let stream: AsyncStream<MeetingLifecycleVerdict>

    init(_ stream: AsyncStream<MeetingLifecycleVerdict>) {
        self.stream = stream
    }

    func collect() async -> [MeetingLifecycleVerdict] {
        var out: [MeetingLifecycleVerdict] = []
        for await verdict in stream { out.append(verdict) }
        return out
    }
}
