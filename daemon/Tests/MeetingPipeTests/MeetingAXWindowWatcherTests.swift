import ApplicationServices
import XCTest
@testable import MeetingPipe
@testable import MeetingPipeCore

/// Tests for `MeetingAXWindowWatcher`, the 1 Hz mute-state poller (rebuilt
/// 2026-05-29). The watcher re-resolves and *reads* the live mute button(s)
/// each tick and injects fused state into MicGate, replacing the old
/// subscribe-a-second-observer design that always failed with
/// `kAXErrorNotificationAlreadyRegistered` and silently dropped the user's
/// voice while they spoke unmuted in a backgrounded Teams window.
final class MeetingAXWindowWatcherTests: XCTestCase {

    // MARK: - Test doubles

    /// Manual scheduler so tests step the poll instead of waiting on a Timer.
    /// Records the pending one-shot action; `fire()` runs it (which re-arms).
    final class ManualScheduler {
        private(set) var pending: (() -> Void)?
        private(set) var lastDelay: TimeInterval?
        private(set) var scheduleCount: Int = 0
        private(set) var cancellations: Int = 0

        func make() -> MeetingAXWindowWatcher.Scheduler {
            return { [weak self] delay, action in
                self?.lastDelay = delay
                self?.pending = action
                self?.scheduleCount += 1
                return { [weak self] in
                    if self?.pending != nil {
                        self?.cancellations += 1
                        self?.pending = nil
                    }
                }
            }
        }

        func fire() {
            let action = pending
            pending = nil
            action?()
        }
    }

    /// Scripted resolver: returns the next state-array per poll, repeating the
    /// last entry once the script is exhausted so re-arms stay defined.
    final class ScriptedResolver {
        private let script: [[MuteLabels.State]]
        private(set) var calls: Int = 0
        init(_ script: [[MuteLabels.State]]) { self.script = script }
        func make() -> MeetingAXWindowWatcher.StateResolver {
            return { [weak self] in
                guard let self = self, !self.script.isEmpty else { return [] }
                let i = min(self.calls, self.script.count - 1)
                self.calls += 1
                return self.script[i]
            }
        }
    }

    /// Captures injected mute events.
    final class EventSink {
        var events: [AXMuteButtonProbe.Event] = []
    }

    /// Counts `onMuteCleared` calls (the blind-recovery clear).
    final class ClearCounter {
        var count = 0
    }

    /// Counts `onStaleMuteContradiction` calls (the MIC10 part-2 VAD-contradiction discredit).
    final class ContradictionCounter {
        var count = 0
    }

    // MARK: - Fixtures

    private func makeWatcher(
        resolver: @escaping MeetingAXWindowWatcher.StateResolver,
        scheduler: @escaping MeetingAXWindowWatcher.Scheduler,
        sink: EventSink,
        log: EventLog = NoopEventLog(),
        clears: ClearCounter? = nil,
        blindClearThreshold: Int = 3,
        vadActive: @escaping () -> Bool = { false },
        staleContradictions: ContradictionCounter? = nil,
        contradictionDwellSeconds: Double = VADContradictionTracker.defaultDwellSeconds,
        walkQueue: DispatchQueue? = nil
    ) -> MeetingAXWindowWatcher {
        MeetingAXWindowWatcher(
            pid: 4242,
            bundleID: "com.microsoft.teams2",
            catalogue: MuteLabels(entries: [:]),
            eventLog: log,
            onMuteEvent: { sink.events.append($0) },
            onMuteCleared: { clears?.count += 1 },
            vadActiveProvider: vadActive,
            onStaleMuteContradiction: { staleContradictions?.count += 1 },
            scheduler: scheduler,
            walkQueue: walkQueue,
            stateResolver: resolver,
            localeResolver: { "en" },
            pollInterval: 1.0,
            blindClearThreshold: blindClearThreshold,
            contradictionDwellSeconds: contradictionDwellSeconds
        )
    }

    // MARK: - Fusion (MUTED bias)

    func test_fuse_single_button_uses_its_state() {
        XCTAssertEqual(MeetingAXWindowWatcher.fuse([.unmuted]), .unmuted)
        XCTAssertEqual(MeetingAXWindowWatcher.fuse([.muted]), .muted)
    }

    func test_fuse_disagreement_biases_to_muted() {
        XCTAssertEqual(MeetingAXWindowWatcher.fuse([.muted, .unmuted]), .muted)
        XCTAssertEqual(MeetingAXWindowWatcher.fuse([.unmuted, .muted]), .muted)
    }

    func test_fuse_all_unmuted_is_unmuted() {
        XCTAssertEqual(MeetingAXWindowWatcher.fuse([.unmuted, .unmuted]), .unmuted)
    }

    func test_fuse_ignores_unknown_buttons() {
        // Unknown readings don't count against agreement.
        XCTAssertEqual(MeetingAXWindowWatcher.fuse([.unknown, .unmuted]), .unmuted)
        XCTAssertEqual(MeetingAXWindowWatcher.fuse([.unknown, .muted]), .muted)
    }

    func test_fuse_no_confident_signal_is_nil() {
        XCTAssertNil(MeetingAXWindowWatcher.fuse([]))
        XCTAssertNil(MeetingAXWindowWatcher.fuse([.unknown]))
        XCTAssertNil(MeetingAXWindowWatcher.fuse([.unknown, .unknown]))
    }

    // MARK: - Poll loop

    func test_first_poll_emits_when_button_read_unmuted() {
        let resolver = ScriptedResolver([[.unmuted]])
        let scheduler = ManualScheduler()
        let sink = EventSink()
        let log = RecordingEventLog()
        let watcher = makeWatcher(resolver: resolver.make(), scheduler: scheduler.make(), sink: sink, log: log)

        watcher.start()

        XCTAssertEqual(sink.events.map(\.state), [.unmuted])
        XCTAssertEqual(scheduler.lastDelay, 1.0)
        XCTAssertNotNil(scheduler.pending) // re-armed
        XCTAssertTrue(log.entries.contains { $0.action == "mute_state_polled" })
    }

    func test_unchanged_state_is_not_re_emitted() {
        let resolver = ScriptedResolver([[.muted]]) // repeats .muted forever
        let scheduler = ManualScheduler()
        let sink = EventSink()
        let watcher = makeWatcher(resolver: resolver.make(), scheduler: scheduler.make(), sink: sink)

        watcher.start()
        XCTAssertEqual(sink.events.map(\.state), [.muted])

        scheduler.fire() // polls again, same state
        scheduler.fire()
        XCTAssertEqual(sink.events.map(\.state), [.muted], "duplicate states must not re-emit")
    }

    func test_transition_muted_to_unmuted_emits_the_unmute() {
        // The regression: start muted, user unmutes mid-meeting. The poll must
        // detect the unmute within one tick and inject .unmuted.
        let resolver = ScriptedResolver([[.muted], [.muted], [.unmuted]])
        let scheduler = ManualScheduler()
        let sink = EventSink()
        let watcher = makeWatcher(resolver: resolver.make(), scheduler: scheduler.make(), sink: sink)

        watcher.start()       // .muted
        scheduler.fire()      // .muted (no emit)
        scheduler.fire()      // .unmuted

        XCTAssertEqual(sink.events.map(\.state), [.muted, .unmuted])
    }

    func test_all_unknown_does_not_emit_but_keeps_polling() {
        let resolver = ScriptedResolver([[.unknown]])
        let scheduler = ManualScheduler()
        let sink = EventSink()
        let watcher = makeWatcher(resolver: resolver.make(), scheduler: scheduler.make(), sink: sink)

        watcher.start()

        XCTAssertTrue(sink.events.isEmpty, "an all-unknown read must not clobber MicGate")
        XCTAssertNotNil(scheduler.pending, "poll keeps running so a later confident read is caught")
    }

    func test_start_polls_immediately_then_rearms() {
        let resolver = ScriptedResolver([[.muted]])
        let scheduler = ManualScheduler()
        let sink = EventSink()
        let watcher = makeWatcher(resolver: resolver.make(), scheduler: scheduler.make(), sink: sink)

        watcher.start()
        XCTAssertEqual(scheduler.scheduleCount, 1)
        XCTAssertEqual(resolver.calls, 1)

        scheduler.fire()
        XCTAssertEqual(scheduler.scheduleCount, 2)
        XCTAssertEqual(resolver.calls, 2)
    }

    func test_stop_cancels_the_poll() {
        let resolver = ScriptedResolver([[.muted]])
        let scheduler = ManualScheduler()
        let sink = EventSink()
        let watcher = makeWatcher(resolver: resolver.make(), scheduler: scheduler.make(), sink: sink)

        watcher.start()
        XCTAssertNotNil(scheduler.pending)

        watcher.stop()
        XCTAssertEqual(scheduler.cancellations, 1)
        XCTAssertNil(scheduler.pending)
    }

    func test_disagreeing_buttons_emit_muted() {
        // Backgrounded-stale (muted) + live (unmuted) found together -> MUTED wins.
        let resolver = ScriptedResolver([[.muted, .unmuted]])
        let scheduler = ManualScheduler()
        let sink = EventSink()
        let watcher = makeWatcher(resolver: resolver.make(), scheduler: scheduler.make(), sink: sink)

        watcher.start()
        XCTAssertEqual(sink.events.map(\.state), [.muted])
    }

    // MARK: - Blind recovery (S1: Teams compact/mini window)

    func test_blind_polls_after_muted_clear_the_stale_mute() {
        // Start muted, then the live control becomes unreadable (mini window):
        // every later poll is blind. After blindClearThreshold blind polls the
        // latched .muted is cleared so MicGate stops zeroing the mic.
        let resolver = ScriptedResolver([[.muted], []]) // muted once, then blind forever
        let scheduler = ManualScheduler()
        let sink = EventSink()
        let clears = ClearCounter()
        let log = RecordingEventLog()
        let watcher = makeWatcher(
            resolver: resolver.make(), scheduler: scheduler.make(),
            sink: sink, log: log, clears: clears, blindClearThreshold: 3
        )

        watcher.start()       // poll 1: .muted (latched)
        scheduler.fire()      // poll 2: blind #1
        scheduler.fire()      // poll 3: blind #2
        XCTAssertEqual(clears.count, 0, "not yet at the threshold")
        scheduler.fire()      // poll 4: blind #3 -> clear
        XCTAssertEqual(clears.count, 1)
        XCTAssertTrue(log.entries.contains { $0.action == "mute_state_cleared_blind" })

        // Further blind polls must not re-clear.
        scheduler.fire()
        XCTAssertEqual(clears.count, 1)
    }

    func test_confident_readings_never_clear() {
        let resolver = ScriptedResolver([[.muted]]) // always a confident muted read
        let scheduler = ManualScheduler()
        let sink = EventSink()
        let clears = ClearCounter()
        let watcher = makeWatcher(
            resolver: resolver.make(), scheduler: scheduler.make(),
            sink: sink, clears: clears, blindClearThreshold: 3
        )

        watcher.start()
        for _ in 0..<5 { scheduler.fire() }
        XCTAssertEqual(clears.count, 0, "a readable mute is a real mute; never clear it")
    }

    func test_blind_from_start_still_clears_the_latch() {
        // TECH-MIC6: the live control is never matchable in this UI build, so the
        // watcher never gets a confident read. The old rescue was gated on the
        // watcher's own `lastEmitted == .muted` and so was structurally
        // unreachable here (it fired 0 times in 19 days) precisely when a stale
        // `.muted` from the primary probe needed clearing. Decoupled, a blind
        // streak from the start still clears.
        let resolver = ScriptedResolver([[]]) // blind on every poll
        let scheduler = ManualScheduler()
        let sink = EventSink()
        let clears = ClearCounter()
        let watcher = makeWatcher(
            resolver: resolver.make(), scheduler: scheduler.make(),
            sink: sink, clears: clears, blindClearThreshold: 3
        )

        watcher.start()       // blind #1
        scheduler.fire()      // blind #2
        XCTAssertEqual(clears.count, 0, "not yet at the threshold")
        scheduler.fire()      // blind #3 -> clear
        XCTAssertEqual(clears.count, 1)
        // Idempotent: a sustained blind streak clears once, not every poll.
        scheduler.fire()
        XCTAssertEqual(clears.count, 1)
    }

    func test_clear_is_idempotent_after_an_unmuted_read() {
        // A latched `.unmuted` going blind clears too (decoupled from
        // lastEmitted), but `clearAxMute` is idempotent so it is a harmless no-op
        // when nothing muted is latched. Fires once per blind streak.
        let resolver = ScriptedResolver([[.unmuted], []])
        let scheduler = ManualScheduler()
        let sink = EventSink()
        let clears = ClearCounter()
        let watcher = makeWatcher(
            resolver: resolver.make(), scheduler: scheduler.make(),
            sink: sink, clears: clears, blindClearThreshold: 3
        )

        watcher.start()                 // .unmuted (confident)
        for _ in 0..<5 { scheduler.fire() } // blind thereafter
        XCTAssertEqual(clears.count, 1, "cleared once after the blind threshold")
    }

    func test_confident_reading_resets_the_blind_streak() {
        // muted, blind, blind, muted(confident) resets the streak; it then takes
        // a fresh full streak of blind polls to clear.
        let resolver = ScriptedResolver([[.muted], [], [], [.muted], []])
        let scheduler = ManualScheduler()
        let sink = EventSink()
        let clears = ClearCounter()
        let watcher = makeWatcher(
            resolver: resolver.make(), scheduler: scheduler.make(),
            sink: sink, clears: clears, blindClearThreshold: 3
        )

        watcher.start()       // .muted
        scheduler.fire()      // blind #1
        scheduler.fire()      // blind #2
        scheduler.fire()      // .muted confident -> streak reset
        XCTAssertEqual(clears.count, 0)
        scheduler.fire()      // blind #1
        scheduler.fire()      // blind #2
        scheduler.fire()      // blind #3 -> clear
        XCTAssertEqual(clears.count, 1)
    }

    // MARK: - MIC10 part 2: VAD-contradiction staleness

    func test_vad_contradiction_discredits_and_suppresses_a_stale_muted_read() {
        // The AX read stays confidently `.muted`, but VAD reports voice: a stale read. With a 0 s
        // dwell the contradiction fires on the first poll; the `.muted` is held back (never
        // injected) so MicGate falls through to the live voice.
        let resolver = ScriptedResolver([[.muted]])
        let scheduler = ManualScheduler()
        let sink = EventSink()
        let stale = ContradictionCounter()
        let watcher = makeWatcher(
            resolver: resolver.make(), scheduler: scheduler.make(), sink: sink,
            vadActive: { true }, staleContradictions: stale, contradictionDwellSeconds: 0
        )

        watcher.start()

        XCTAssertEqual(stale.count, 1, "the stale read was discredited")
        XCTAssertTrue(sink.events.isEmpty, "the stale .muted was suppressed, not injected")
    }

    func test_no_contradiction_when_vad_is_quiet() {
        // A genuine mute (no voice) must inject `.muted` and never discredit.
        let resolver = ScriptedResolver([[.muted]])
        let scheduler = ManualScheduler()
        let sink = EventSink()
        let stale = ContradictionCounter()
        let watcher = makeWatcher(
            resolver: resolver.make(), scheduler: scheduler.make(), sink: sink,
            vadActive: { false }, staleContradictions: stale, contradictionDwellSeconds: 0
        )

        watcher.start()

        XCTAssertEqual(stale.count, 0)
        XCTAssertEqual(sink.events.map(\.state), [.muted])
    }

    func test_genuine_mute_relatches_once_the_voice_stops() {
        // The scope guard: a muted side-conversation trips the contradiction, but the moment the
        // voice stops the read is honoured again (re-latched), so privacy is only briefly affected.
        var vad = true
        let resolver = ScriptedResolver([[.muted]])   // always reads muted
        let scheduler = ManualScheduler()
        let sink = EventSink()
        let stale = ContradictionCounter()
        let watcher = makeWatcher(
            resolver: resolver.make(), scheduler: scheduler.make(), sink: sink,
            vadActive: { vad }, staleContradictions: stale, contradictionDwellSeconds: 0
        )

        watcher.start()                       // poll 1: contradiction fires, .muted suppressed
        XCTAssertEqual(stale.count, 1)
        XCTAssertTrue(sink.events.isEmpty)

        vad = false                           // the side-talk stops
        scheduler.fire()                      // poll 2: contradiction clears -> .muted re-latches
        XCTAssertEqual(sink.events.map(\.state), [.muted], "the genuine mute is honoured again")
        XCTAssertEqual(stale.count, 1, "no new discredit")
    }

    // MARK: - MIC16: the AX walk runs off the main thread

    func test_slow_walk_runs_off_the_caller_and_does_not_block() {
        // Production wires a real `walkQueue`. A deliberately slow resolver (a wedged
        // meeting client) must run on that queue, not the caller: poll() returns while the
        // walk is still parked, so a force-stop hotkey on the main thread is never delayed.
        let entered = DispatchSemaphore(value: 0)   // signalled once the walk begins
        let release = DispatchSemaphore(value: 0)   // held until the test lets the walk finish
        let resolver: MeetingAXWindowWatcher.StateResolver = {
            entered.signal()
            release.wait()
            return [.unmuted]
        }
        let walkQueue = DispatchQueue(label: "test.mic16.ax-walk")
        let scheduler = ManualScheduler()
        let sink = EventSink()
        let watcher = makeWatcher(
            resolver: resolver, scheduler: scheduler.make(), sink: sink, walkQueue: walkQueue
        )

        watcher.start()  // dispatches the walk to walkQueue; must return without blocking

        // The walk is now parked in release.wait() on its own queue; the caller got control
        // back and nothing has been consumed or re-armed yet.
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success, "the walk ran on the queue")
        XCTAssertTrue(sink.events.isEmpty, "poll() returned before the walk finished; caller not blocked")
        XCTAssertNil(scheduler.pending, "no re-arm until the reading is delivered on main")

        // Let the walk finish; it hops the reading back to main. Pump main until it lands.
        release.signal()
        let delivered = expectation(description: "reading delivered on main")
        func pump() {
            if sink.events.isEmpty {
                DispatchQueue.main.async(execute: pump)
            } else {
                delivered.fulfill()
            }
        }
        DispatchQueue.main.async(execute: pump)
        wait(for: [delivered], timeout: 2)

        XCTAssertEqual(sink.events.map(\.state), [.unmuted], "the unmute was consumed on main")
        XCTAssertNotNil(scheduler.pending, "the next tick re-armed after delivery")
    }

    func test_stop_during_an_in_flight_walk_drops_the_late_delivery() {
        // If the recording stops while an AX walk is still parked on the queue, its delivery
        // must be dropped (the generation guard) rather than re-arming a stopped poll.
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let resolver: MeetingAXWindowWatcher.StateResolver = {
            entered.signal()
            release.wait()
            return [.muted]
        }
        let walkQueue = DispatchQueue(label: "test.mic16.ax-walk.stop")
        let scheduler = ManualScheduler()
        let sink = EventSink()
        let watcher = makeWatcher(
            resolver: resolver, scheduler: scheduler.make(), sink: sink, walkQueue: walkQueue
        )

        watcher.start()
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)

        watcher.stop()      // bumps the generation; the in-flight walk is now stale
        release.signal()    // let the walk finish and try to deliver on main
        walkQueue.sync {}   // barrier: the walk closure (and its main-queue hop) is enqueued

        let settled = expectation(description: "main drained past the dropped delivery")
        DispatchQueue.main.async { settled.fulfill() }
        wait(for: [settled], timeout: 2)

        XCTAssertTrue(sink.events.isEmpty, "a walk delivered after stop() must not emit")
        XCTAssertNil(scheduler.pending, "a stopped watcher must not re-arm")
    }
}
