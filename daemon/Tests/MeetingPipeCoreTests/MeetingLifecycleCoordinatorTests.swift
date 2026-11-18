import ApplicationServices
import XCTest
@testable import MeetingPipeCore
import MeetingPipeTestSupport

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
            scheduler: scheduler.schedule,
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

        // END17: a lone weak end confirms on the lone dwell, not the old 2 s debounce.
        now = Date(timeIntervalSince1970: 1 + PromotionEngine.defaultLoneDwell)
        coordinator.tick()
        flushEngine(coordinator)
        XCTAssertEqual(
            coordinator.current,
            .ended(
                context: teamsContext,
                reason: EndingReason(leadingSignal: "shareable_content_window_gone", confirmedBy: ["lone_dwell"])
            )
        )
    }

    func test_disengage_resets_engine_and_publishes_idle() throws {
        let fake = FakeAdapter()
        let scheduler = ManualScheduler()
        let coordinator = MeetingLifecycleCoordinator(
            adapters: [fake],
            scheduler: scheduler.schedule
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
            scheduler: scheduler.schedule
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
            scheduler: scheduler.schedule
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
            scheduler: scheduler.schedule
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
            scheduler: scheduler.schedule,
            clock: { now }
        )

        try coordinator.engage(context: teamsContext, handle: LifecycleAdapterHandle())
        flushEngine(coordinator)
        // PERF5: engaged but idle -> the periodic tick is not armed.
        XCTAssertFalse(scheduler.hasPending, "tick must not run before a provisional end")

        fake.emit(.init(kind: .shareableContentWindow, state: .live, timestamp: now, context: teamsContext))
        flushEngine(coordinator)
        coordinator.confirmRecording()
        flushEngine(coordinator)
        XCTAssertEqual(coordinator.current, .inMeeting(context: teamsContext))
        XCTAssertFalse(scheduler.hasPending, "tick stays disarmed through .starting / .inMeeting")

        now = Date(timeIntervalSince1970: 1)
        fake.emit(.init(kind: .shareableContentWindow, state: .ended, timestamp: now, context: teamsContext))
        flushEngine(coordinator)
        // PERF5: a provisional end arms the tick so a dwell can promote it.
        XCTAssertTrue(scheduler.hasPending, "tick arms when a provisional end is pending")

        now = Date(timeIntervalSince1970: 1 + PromotionEngine.defaultLoneDwell)
        coordinator.tick()
        flushEngine(coordinator)
        XCTAssertEqual(
            coordinator.current,
            .ended(
                context: teamsContext,
                reason: EndingReason(leadingSignal: "shareable_content_window_gone", confirmedBy: ["lone_dwell"])
            )
        )
        // PERF5: promoting to .ended disarms the tick again.
        XCTAssertFalse(scheduler.hasPending, "tick disarms once the end is confirmed")
    }

    func test_tick_disarms_when_provisional_end_reverts() throws {
        let fake = FakeAdapter()
        let scheduler = ManualScheduler()
        var now = Date(timeIntervalSince1970: 0)
        let coordinator = MeetingLifecycleCoordinator(
            adapters: [fake],
            scheduler: scheduler.schedule,
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
        XCTAssertTrue(scheduler.hasPending, "armed on the provisional end")

        // The leading signal flips back to live before the debounce: the engine
        // returns to .inMeeting (flicker-absorb) and the tick must disarm (PERF5).
        now = Date(timeIntervalSince1970: 2)
        fake.emit(.init(kind: .shareableContentWindow, state: .live, timestamp: now, context: teamsContext))
        flushEngine(coordinator)
        XCTAssertEqual(coordinator.current, .inMeeting(context: teamsContext))
        XCTAssertFalse(scheduler.hasPending, "tick disarms when the provisional end reverts")
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
            adapters: [fake], scheduler: scheduler.schedule
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
            adapters: [fake], scheduler: ManualScheduler().schedule
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
            adapters: [fake], scheduler: ManualScheduler().schedule
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

    // MARK: - END14: the veto is visible in the event log

    /// A vetoed window-gone leaves the verdict untouched, so without a row the field could not tell
    /// this path from a quiet call. One `lifecycle`/`end_vetoed` per vetoed transition.
    func test_vetoed_window_gone_emits_end_vetoed_once_END14() throws {
        let fake = FakeAdapter()
        let log = RecordingEventLog()
        let coordinator = MeetingLifecycleCoordinator(
            eventLog: log, adapters: [fake], scheduler: ManualScheduler().schedule,
            clock: { Date(timeIntervalSince1970: 0) }
        )
        try coordinator.engage(context: teamsContext, handle: LifecycleAdapterHandle())
        fake.emit(.init(
            kind: .processAudioIsRunningInput, state: .live,
            timestamp: Date(timeIntervalSince1970: 0), context: teamsContext
        ))
        flushEngine(coordinator)
        coordinator.confirmRecording()
        flushEngine(coordinator)
        fake.emit(.init(
            kind: .shareableContentWindow, state: .ended,
            timestamp: Date(timeIntervalSince1970: 1), context: teamsContext
        ))
        flushEngine(coordinator)

        XCTAssertEqual(coordinator.current, .inMeeting(context: teamsContext))
        let vetoes = log.entries.filter { $0.category == "lifecycle" && $0.action == "end_vetoed" }
        XCTAssertEqual(vetoes.count, 1)
        XCTAssertEqual(vetoes.first?.attributes["bundle_id"], teamsContext.bundleID)
        XCTAssertEqual(vetoes.first?.attributes["leading_signal"], "shareable_content_window_gone")
        XCTAssertEqual(vetoes.first?.attributes["vetoed_by"], "process_audio_is_running_input_false")
    }

    // MARK: - END27

    /// The engage tells the engine whether its adapter has a vetoer, so a window-gone that wins
    /// the first-reading race against process audio waits for it, arms the grace tick, and is
    /// logged as vetoed once process audio reads live.
    func test_a_first_window_gone_waits_for_process_audio_END27() throws {
        let fake = FakeAdapter()
        fake.publishesProcessAudio = true
        let log = RecordingEventLog()
        let scheduler = ManualScheduler()
        let now = Date(timeIntervalSince1970: 0)
        let coordinator = MeetingLifecycleCoordinator(
            eventLog: log, adapters: [fake], scheduler: scheduler.schedule, clock: { now }
        )
        try coordinator.engage(context: teamsContext, handle: LifecycleAdapterHandle())
        fake.emit(.init(kind: .axLeaveButton, state: .live, timestamp: now, context: teamsContext))
        fake.emit(.init(kind: .shareableContentWindow, state: .ended, timestamp: now, context: teamsContext))
        flushEngine(coordinator)
        XCTAssertEqual(coordinator.current, .starting(context: teamsContext))
        XCTAssertTrue(scheduler.hasPending, "the grace is a deadline, so the tick arms")
        XCTAssertFalse(coordinator.isTerminal)

        fake.emit(.init(kind: .processAudioIsRunningInput, state: .live, timestamp: now, context: teamsContext))
        flushEngine(coordinator)
        XCTAssertEqual(coordinator.current, .starting(context: teamsContext))
        XCTAssertFalse(scheduler.hasPending)
        let vetoes = log.entries.filter { $0.action == "end_vetoed" }
        XCTAssertEqual(vetoes.count, 1)
        XCTAssertEqual(vetoes.first?.attributes["vetoed_by"], "process_audio_is_running_input_false")
    }

    /// The same order on an adapter with no process audio ends at once, and the coordinator then
    /// reads as terminal until it is engaged again.
    func test_isTerminal_isAnEngagedEngineThatHasEnded_END27() throws {
        let fake = FakeAdapter()
        let now = Date(timeIntervalSince1970: 0)
        let coordinator = MeetingLifecycleCoordinator(
            adapters: [fake], scheduler: ManualScheduler().schedule, clock: { now }
        )
        XCTAssertFalse(coordinator.isTerminal, "nothing engaged is not terminal")
        try coordinator.engage(context: teamsContext, handle: LifecycleAdapterHandle())
        fake.emit(.init(kind: .axLeaveButton, state: .live, timestamp: now, context: teamsContext))
        fake.emit(.init(kind: .shareableContentWindow, state: .ended, timestamp: now, context: teamsContext))
        flushEngine(coordinator)
        XCTAssertTrue(coordinator.isTerminal)

        try coordinator.engage(context: teamsContext, handle: LifecycleAdapterHandle())
        flushEngine(coordinator)
        XCTAssertFalse(coordinator.isTerminal, "a fresh engagement starts from idle")
        fake.emit(.init(kind: .axLeaveButton, state: .live, timestamp: now, context: teamsContext))
        flushEngine(coordinator)
        XCTAssertEqual(coordinator.current, .starting(context: teamsContext), "and hears its signals again")
    }

    /// END18: a declined revert leaves the verdict alone, so the drained row is its only trace.
    func test_declined_revert_emits_end_revert_declined_END18() throws {
        let fake = FakeAdapter()
        let log = RecordingEventLog()
        let coordinator = MeetingLifecycleCoordinator(
            eventLog: log, adapters: [fake], scheduler: ManualScheduler().schedule,
            clock: { Date(timeIntervalSince1970: 0) }
        )
        try coordinator.engage(context: teamsContext, handle: LifecycleAdapterHandle())
        func emit(_ kind: PrimarySignalKind, _ state: PrimarySignalState, _ t: TimeInterval) {
            fake.emit(.init(kind: kind, state: state, timestamp: Date(timeIntervalSince1970: t), context: teamsContext))
        }
        emit(.axLeaveButton, .live, 0)
        flushEngine(coordinator)
        coordinator.confirmRecording()
        flushEngine(coordinator)
        emit(.axLeaveButton, .ended, 10)
        emit(.processAudioIsRunningInput, .ended, 14)
        emit(.axLeaveButton, .live, 18)
        flushEngine(coordinator)

        XCTAssertEqual(
            coordinator.current,
            .endingProvisional(context: teamsContext, reason: EndingReason(leadingSignal: "ax_leave_button_invalid"))
        )
        let rows = log.entries.filter { $0.category == "lifecycle" && $0.action == "end_revert_declined" }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.attributes["leading_signal"], "ax_leave_button_invalid")
        XCTAssertEqual(rows.first?.attributes["reading"], "ax_leave_button_invalid")
        XCTAssertNotNil(rows.first?.attributes["ended_classes"])
    }

    fileprivate func flushEngine(_ coordinator: MeetingLifecycleCoordinator) {
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
    var publishesProcessAudio = false
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

    /// END22: counted on main, where the coordinator calls it.
    private(set) var refreshCount = 0
    func refreshReadings() { refreshCount += 1 }

    func emit(_ event: PrimarySignalEvent) {
        sink?(event)
    }

    /// Fire through the sink captured at `start`, even after `stop()` nilled `sink`.
    func emitRetained(_ event: PrimarySignalEvent) {
        retainedSink?(event)
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

// MARK: - END22: sleep, wake and display changes

extension MeetingLifecycleCoordinatorTests {

    private final class Clocks {
        var wall = Date(timeIntervalSince1970: 0)
        var uptime: TimeInterval = 0
        func advance(_ seconds: TimeInterval) { wall = wall.addingTimeInterval(seconds); uptime += seconds }
        func sleep(_ seconds: TimeInterval) { wall = wall.addingTimeInterval(seconds); uptime += 0.25 }
    }

    private func wakeRig(displaySettle: TimeInterval = MeetingLifecycleCoordinator.defaultDisplaySettle)
        throws -> (MeetingLifecycleCoordinator, FakeAdapter, Clocks, RecordingEventLog) {
        let fake = FakeAdapter()
        let clocks = Clocks()
        let log = RecordingEventLog()
        let coordinator = MeetingLifecycleCoordinator(
            eventLog: log,
            adapters: [fake],
            scheduler: ManualScheduler().schedule,
            clock: { clocks.wall },
            uptime: { clocks.uptime },
            displaySettle: displaySettle
        )
        try coordinator.engage(context: teamsContext, handle: LifecycleAdapterHandle())
        fake.emit(.init(kind: .shareableContentWindow, state: .live, timestamp: clocks.wall, context: teamsContext))
        flushEngine(coordinator)
        coordinator.confirmRecording()
        flushEngine(coordinator)
        return (coordinator, fake, clocks, log)
    }

    private func drainMain() {
        let drained = expectation(description: "main drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
    }

    /// The race the design review caught: the first tick after a wake reaches the engine before the
    /// host's `didWake`. The coordinator measures the sleep from its own clocks, so that tick does
    /// not confirm.
    func test_the_first_tick_after_a_sleep_does_not_confirm_with_no_notification() throws {
        let (coordinator, fake, clocks, log) = try wakeRig()
        clocks.advance(1)
        fake.emit(.init(kind: .shareableContentWindow, state: .ended, timestamp: clocks.wall, context: teamsContext))
        flushEngine(coordinator)
        let holdUptime = clocks.uptime
        clocks.sleep(PromotionEngine.defaultLoneDwell + 200)
        coordinator.tick()
        flushEngine(coordinator)
        XCTAssertEqual(coordinator.current, .endingProvisional(
            context: teamsContext, reason: EndingReason(leadingSignal: "shareable_content_window_gone")
        ))
        let row = try XCTUnwrap(log.entries.first { $0.action == "lifecycle_wake_reset" })
        XCTAssertEqual(row.attributes["reason"], "clock_gap")
        XCTAssertEqual(row.attributes["phase"], "ending_provisional")
        drainMain()
        XCTAssertEqual(fake.refreshCount, 1, "the adapter is asked to re-read")

        // A fresh reading, then the lone dwell on awake time only.
        fake.emit(.init(kind: .shareableContentWindow, state: .ended, timestamp: clocks.wall, context: teamsContext))
        clocks.advance(PromotionEngine.defaultLoneDwell - (clocks.uptime - holdUptime) - 1)
        flushEngine(coordinator)
        if case .ended = coordinator.current { XCTFail("a second short of the awake lone dwell") }
        clocks.advance(2)
        flushEngine(coordinator)
        guard case .ended = coordinator.current else { return XCTFail("the awake lone dwell ran") }
    }

    func test_a_host_wake_after_the_clock_caught_it_is_not_applied_twice() throws {
        let (coordinator, _, clocks, log) = try wakeRig()
        clocks.sleep(600)
        coordinator.tick()
        flushEngine(coordinator)
        coordinator.noteWake(reason: "system_wake")
        flushEngine(coordinator)
        XCTAssertEqual(log.entries.filter { $0.action == "lifecycle_wake_reset" }.count, 1)
    }

    func test_an_unlock_with_no_sleep_only_asks_for_a_fresh_reading() throws {
        let (coordinator, fake, clocks, log) = try wakeRig()
        clocks.advance(30)
        coordinator.noteWake(reason: "unlock")
        flushEngine(coordinator)
        let row = try XCTUnwrap(log.entries.first { $0.action == "lifecycle_wake_reset" })
        XCTAssertEqual(row.attributes["reason"], "unlock")
        XCTAssertEqual(row.attributes["asleep_sec"], "0.0")
        drainMain()
        XCTAssertEqual(fake.refreshCount, 1)
    }

    func test_a_window_gone_inside_the_display_settle_opens_no_hold_and_a_return_supersedes_it() throws {
        let (coordinator, fake, clocks, log) = try wakeRig(displaySettle: 0.3)
        coordinator.noteDisplayChange()
        flushEngine(coordinator)
        fake.emit(.init(kind: .shareableContentWindow, state: .ended, timestamp: clocks.wall, context: teamsContext))
        flushEngine(coordinator)
        XCTAssertEqual(coordinator.current, .inMeeting(context: teamsContext), "held back, not ingested")
        fake.emit(.init(kind: .shareableContentWindow, state: .live, timestamp: clocks.wall, context: teamsContext))
        flushEngine(coordinator)
        let settled = expectation(description: "past the settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        flushEngine(coordinator)
        XCTAssertEqual(coordinator.current, .inMeeting(context: teamsContext))
        XCTAssertEqual(log.entries.filter { $0.action == "display_change_window_deferred" }.map { $0.attributes["outcome"] }, ["superseded"])
    }

    func test_a_window_still_gone_at_the_settles_end_is_ingested_then() throws {
        let (coordinator, fake, clocks, log) = try wakeRig(displaySettle: 0.3)
        coordinator.noteDisplayChange()
        flushEngine(coordinator)
        fake.emit(.init(kind: .shareableContentWindow, state: .ended, timestamp: clocks.wall, context: teamsContext))
        flushEngine(coordinator)
        let settled = expectation(description: "past the settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        flushEngine(coordinator)
        XCTAssertEqual(coordinator.current, .endingProvisional(
            context: teamsContext, reason: EndingReason(leadingSignal: "shareable_content_window_gone")
        ))
        XCTAssertEqual(log.entries.filter { $0.action == "display_change_window_deferred" }.map { $0.attributes["outcome"] }, ["ingested"])
    }

    func test_a_deferred_window_gone_dies_with_its_engagement() throws {
        let (coordinator, fake, clocks, log) = try wakeRig(displaySettle: 0.3)
        coordinator.noteDisplayChange()
        flushEngine(coordinator)
        fake.emit(.init(kind: .shareableContentWindow, state: .ended, timestamp: clocks.wall, context: teamsContext))
        flushEngine(coordinator)
        coordinator.disengage()
        let settled = expectation(description: "past the settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        flushEngine(coordinator)
        XCTAssertEqual(coordinator.current, .idle)
        // The next engagement's first window reading does not find the old one waiting.
        try coordinator.engage(context: teamsContext, handle: LifecycleAdapterHandle())
        fake.emit(.init(kind: .shareableContentWindow, state: .live, timestamp: clocks.wall, context: teamsContext))
        flushEngine(coordinator)
        XCTAssertTrue(log.entries.filter { $0.action == "display_change_window_deferred" }.isEmpty)
    }
}
