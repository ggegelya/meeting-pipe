import XCTest
@testable import MeetingPipeCore

final class ShareableContentSignalTests: XCTestCase {

    typealias Summary = ShareableContentSignal.ShareableWindowSummary

    private let teamsContext = MeetingLifecycleContext(
        bundleID: "com.microsoft.teams2",
        kind: .native,
        pid: 1234
    )

    private func manualScheduler(_ store: ManualScheduler) -> ShareableContentSignal.Scheduler {
        return { interval, action in
            store.lastInterval = interval
            store.tick = action
            return { store.tick = nil }
        }
    }

    final class ManualScheduler {
        var tick: (() -> Void)?
        var lastInterval: TimeInterval = 0
    }

    func test_window_present_when_bundle_matches() {
        let scheduler = ManualScheduler()
        var observed: [Bool] = []
        let signal = ShareableContentSignal(
            probe: {
                [Summary(bundleIdentifier: "com.microsoft.teams2", title: "Standup | Meeting")]
            },
            scheduler: manualScheduler(scheduler)
        )
        signal.onChange = { observed.append($0) }

        signal.start(context: teamsContext)
        XCTAssertEqual(observed, [true])
        XCTAssertEqual(signal.lastValue, true)
    }

    func test_window_absent_when_bundle_does_not_match() {
        let scheduler = ManualScheduler()
        var observed: [Bool] = []
        let signal = ShareableContentSignal(
            probe: {
                [Summary(bundleIdentifier: "us.zoom.xos", title: "Zoom")]
            },
            scheduler: manualScheduler(scheduler)
        )
        signal.onChange = { observed.append($0) }

        signal.start(context: teamsContext)
        XCTAssertEqual(observed, [false])
    }

    func test_title_match_filters_chat_threads() {
        let scheduler = ManualScheduler()
        var observed: [Bool] = []
        let signal = ShareableContentSignal(
            probe: {
                [Summary(bundleIdentifier: "com.microsoft.teams2", title: "Chat - Acme")]
            },
            scheduler: manualScheduler(scheduler)
        )
        signal.onChange = { observed.append($0) }

        signal.start(context: teamsContext, titleMatch: { title in
            (title ?? "").lowercased().contains("meeting")
        })
        XCTAssertEqual(observed, [false])
    }

    func test_present_transitions_to_absent_when_window_closes() {
        let scheduler = ManualScheduler()
        var windows: [Summary] = [
            Summary(bundleIdentifier: "com.microsoft.teams2", title: "Standup")
        ]
        var observed: [Bool] = []
        let signal = ShareableContentSignal(
            probe: { windows },
            scheduler: manualScheduler(scheduler)
        )
        signal.onChange = { observed.append($0) }

        signal.start(context: teamsContext)
        windows = []
        scheduler.tick?()
        XCTAssertEqual(observed, [true, false])
    }

    /// PERF19: one rate. The present-window poll was 0.5 s for sub-second window-gone reaction;
    /// END17 holds a recording-time window-gone for a 60 s pair or 720 s lone dwell, so half a
    /// second bought nothing, and the absent-window 1 s is the floor END14's revert relies on.
    func test_cadence_is_one_second_whether_or_not_the_window_is_present() {
        let scheduler = ManualScheduler()
        var windows: [Summary] = []
        let signal = ShareableContentSignal(
            probe: { windows },
            scheduler: manualScheduler(scheduler)
        )

        signal.start(context: teamsContext)
        XCTAssertEqual(scheduler.lastInterval, 1.0, "absent window")

        windows = [Summary(bundleIdentifier: "com.microsoft.teams2", title: "Standup")]
        scheduler.tick?()
        XCTAssertEqual(scheduler.lastInterval, 1.0, "present window: no 2 Hz tier any more")

        windows = []
        scheduler.tick?()
        XCTAssertEqual(scheduler.lastInterval, 1.0)
    }

    /// The two-tier mechanism still works for an injected pair, so a later split is a constant change.
    func test_cadence_switches_between_injected_active_and_idle() {
        let scheduler = ManualScheduler()
        var windows: [Summary] = []
        let signal = ShareableContentSignal(
            probe: { windows },
            scheduler: manualScheduler(scheduler),
            activeInterval: 0.5,
            idleInterval: 1.0
        )

        signal.start(context: teamsContext)
        XCTAssertEqual(scheduler.lastInterval, 1.0)
        windows = [Summary(bundleIdentifier: "com.microsoft.teams2", title: "Standup")]
        scheduler.tick?()
        XCTAssertEqual(scheduler.lastInterval, 0.5)
    }

    func test_nil_probe_logs_unavailable_without_flapping() {
        let log = RecordingEventLog()
        let scheduler = ManualScheduler()
        var observed: [Bool] = []
        var probeReturn: [Summary]? = [Summary(bundleIdentifier: "com.microsoft.teams2", title: "Meeting")]
        let signal = ShareableContentSignal(
            eventLog: log,
            probe: { probeReturn },
            scheduler: manualScheduler(scheduler)
        )
        signal.onChange = { observed.append($0) }

        signal.start(context: teamsContext)
        probeReturn = nil
        scheduler.tick?()

        XCTAssertEqual(observed, [true])
        XCTAssertTrue(log.entries.contains { $0.action == "shareable_content_unavailable" })
    }

    func test_no_match_logs_candidate_titles_for_diagnosis() {
        let log = RecordingEventLog()
        let scheduler = ManualScheduler()
        let signal = ShareableContentSignal(
            eventLog: log,
            probe: {
                [Summary(bundleIdentifier: "com.microsoft.teams2", title: "Chat - Acme")]
            },
            scheduler: manualScheduler(scheduler)
        )

        signal.start(context: teamsContext, titleMatch: { title in
            (title ?? "").lowercased().contains("meeting")
        })

        XCTAssertTrue(
            log.entries.contains { $0.action == "shareable_content_no_match" },
            "A bundle-owned window that fails the title match is logged for diagnosis"
        )
    }

    // MARK: - PERF15: the production start never waits on the probe

    /// A probe that parks on `gate` the first time it is called and answers at once after that, so
    /// the production poll timer cannot keep the shared poll queue blocked once the test is done.
    final class GatedProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var blocked = false
        let gate = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        let exited = DispatchSemaphore(value: 0)

        func probe() -> [Summary]? {
            let first: Bool = lock.withLock { defer { blocked = true }; return !blocked }
            if first {
                entered.signal()
                _ = gate.wait(timeout: .now() + 3)
                exited.signal()
            }
            return [Summary(bundleIdentifier: "com.microsoft.teams2", title: "Standup | Meeting")]
        }
    }

    /// Red against `main` (measured 2026-10-26: `start` took the whole 3 s gate): the initial
    /// evaluate ran inline, so every engage waited on ScreenCaptureKit on the main thread, up to
    /// `probeTimeout` against a hung SCK. `defaultProbe`'s doc called it off main; it was not.
    func test_start_withTheProductionScheduler_returnsWhileTheInitialProbeIsBlocked() {
        let gated = GatedProbe()
        let present = expectation(description: "the initial reading lands once the probe returns")
        let signal = ShareableContentSignal(probe: { gated.probe() })
        signal.onChange = { value in if value { present.fulfill() } }

        let began = Date()
        signal.start(context: teamsContext)
        let elapsed = Date().timeIntervalSince(began)

        XCTAssertLessThan(elapsed, 0.5, "start must not wait on the probe")
        XCTAssertEqual(gated.entered.wait(timeout: .now() + 2), .success, "the probe runs, off the caller")
        gated.gate.signal()
        wait(for: [present], timeout: 5)
        signal.stop()
    }

    /// The initial evaluate is asynchronous now, so a stop can land while its probe is still
    /// blocked. The reading that probe returns belongs to a session that no longer exists.
    func test_stop_whileTheInitialProbeIsBlocked_dropsItsReading() {
        let gated = GatedProbe()
        let lock = NSLock()
        var emitted: [Bool] = []
        let signal = ShareableContentSignal(probe: { gated.probe() })
        signal.onChange = { value in lock.withLock { emitted.append(value) } }

        signal.start(context: teamsContext)
        XCTAssertEqual(gated.entered.wait(timeout: .now() + 2), .success)
        signal.stop()
        gated.gate.signal()
        XCTAssertEqual(gated.exited.wait(timeout: .now() + 2), .success)
        Thread.sleep(forTimeInterval: 0.2)  // the rest of that evaluate is microseconds of bookkeeping

        XCTAssertEqual(lock.withLock { emitted }, [], "nothing emits for a stopped session")
        XCTAssertNil(signal.lastValue)
    }

    // MARK: - PERF19: unavailable once per outage, and a nil first probe still arms

    func test_consecutive_nil_polls_log_unavailable_once_per_outage() {
        let log = RecordingEventLog()
        let scheduler = ManualScheduler()
        var probeReturn: [Summary]? = nil
        let signal = ShareableContentSignal(
            eventLog: log,
            probe: { probeReturn },
            scheduler: manualScheduler(scheduler)
        )
        let unavailable = { log.entries.filter { $0.action == "shareable_content_unavailable" }.count }

        signal.start(context: teamsContext)   // nil #1
        scheduler.tick?()                     // nil #2
        scheduler.tick?()                     // nil #3
        XCTAssertEqual(unavailable(), 1, "one row per outage, not one per poll")

        probeReturn = [Summary(bundleIdentifier: "com.microsoft.teams2", title: "Standup")]
        scheduler.tick?()
        probeReturn = nil
        scheduler.tick?()
        XCTAssertEqual(unavailable(), 2, "a success ends the outage, so the next nil logs again")
    }

    /// Red against main: `evaluate` returned on a nil probe before `adjustCadence`, the only arm, so a
    /// nil reading at engage left the signal without a timer for the whole session.
    func test_nil_initial_probe_still_arms_and_a_later_success_reports_present() {
        let scheduler = ManualScheduler()
        var observed: [Bool] = []
        var probeReturn: [Summary]? = nil
        let signal = ShareableContentSignal(
            probe: { probeReturn },
            scheduler: manualScheduler(scheduler)
        )
        signal.onChange = { observed.append($0) }

        signal.start(context: teamsContext)
        XCTAssertNotNil(scheduler.tick, "a nil first probe arms the poll")
        XCTAssertEqual(scheduler.lastInterval, ShareableContentSignal.idlePollInterval)
        XCTAssertNil(signal.lastValue)

        probeReturn = [Summary(bundleIdentifier: "com.microsoft.teams2", title: "Standup")]
        scheduler.tick?()
        XCTAssertEqual(observed, [true])
        XCTAssertEqual(signal.lastValue, true)
    }

    // MARK: - PERF19: at most one ScreenCaptureKit request in flight

    /// A fetch that never answers on its own: the test holds every completion and decides when.
    final class HeldFetch {
        private let lock = NSLock()
        private var completions: [([Summary]?) -> Void] = []
        var requests: Int { lock.withLock { completions.count } }

        var fetch: ShareableContentSignal.Fetch {
            return { [self] completion in lock.withLock { completions.append(completion) } }
        }

        func complete(_ index: Int, with summaries: [Summary]?) {
            let completion = lock.withLock { completions[index] }
            completion(summaries)
        }
    }

    private let window = Summary(bundleIdentifier: "com.microsoft.teams2", title: "Standup")

    func test_a_poll_while_a_request_is_held_returns_nil_without_a_second_request() {
        let held = HeldFetch()
        let probe = ShareableContentSignal.makeProbe(fetch: held.fetch, preflight: { true }, timeout: 0.05)

        XCTAssertNil(probe(), "the held request times out")
        XCTAssertEqual(held.requests, 1)

        let began = Date()
        XCTAssertNil(probe(), "still in flight")
        XCTAssertLessThan(Date().timeIntervalSince(began), 0.04, "returns at once, without waiting the timeout")
        XCTAssertEqual(held.requests, 1, "no second request while the first is outstanding")
    }

    func test_a_completion_after_the_waiter_timed_out_clears_the_flag() {
        let held = HeldFetch()
        let probe = ShareableContentSignal.makeProbe(fetch: held.fetch, preflight: { true }, timeout: 0.05)

        XCTAssertNil(probe())
        held.complete(0, with: [window])   // SCK answers late; nobody is waiting for it now
        XCTAssertNil(probe(), "the next request is issued, and held too")
        XCTAssertEqual(held.requests, 2, "exactly one new request")
        XCTAssertNil(probe())
        XCTAssertEqual(held.requests, 2)
    }

    /// Not in the spec (see `RequestGate.defaultAbandonAfter`): a callback SCK never makes must not
    /// disable the process-wide gate for good, and the abandoned request's late answer must not
    /// clear the flag of the one issued after it.
    func test_an_unanswered_request_is_given_up_after_abandonAfter() {
        let held = HeldFetch()
        var clock = Date(timeIntervalSince1970: 0)
        let probe = ShareableContentSignal.makeProbe(
            fetch: held.fetch, preflight: { true }, timeout: 0.01, abandonAfter: 30, now: { clock }
        )

        XCTAssertNil(probe())
        clock = clock.addingTimeInterval(29)
        XCTAssertNil(probe())
        XCTAssertEqual(held.requests, 1, "still within abandonAfter")

        clock = clock.addingTimeInterval(1)
        XCTAssertNil(probe())
        XCTAssertEqual(held.requests, 2, "the first request is given up on")

        held.complete(0, with: [window])   // the abandoned one answers at last
        XCTAssertNil(probe())
        XCTAssertEqual(held.requests, 2, "and does not clear the second one's flag")

        held.complete(1, with: [window])
        XCTAssertNil(probe())
        XCTAssertEqual(held.requests, 3)
    }

    func test_a_prompt_completion_returns_its_summaries() {
        let window = self.window
        let probe = ShareableContentSignal.makeProbe(
            fetch: { completion in DispatchQueue.global().async { completion([window]) } },
            preflight: { true },
            timeout: 2
        )
        XCTAssertEqual(probe(), [window])
        XCTAssertEqual(probe(), [window], "the flag cleared, so the next poll fetches again")
    }

    func test_a_failed_preflight_never_fetches() {
        let held = HeldFetch()
        let probe = ShareableContentSignal.makeProbe(fetch: held.fetch, preflight: { false }, timeout: 0.05)
        XCTAssertNil(probe())
        XCTAssertEqual(held.requests, 0)
    }

    // MARK: - END24: identity, not vocabulary

    private let teams2 = "com.microsoft.teams2"
    /// Held for the test's duration: the signal's tick closure captures it weakly.
    private var retained: [ShareableContentSignal] = []

    /// A started identity-mode signal over a mutable window list, with Teams' production predicates.
    private func identitySignal(
        _ windows: LockedBox<[Summary]>,
        log: RecordingEventLog = RecordingEventLog(),
        observed: LockedBox<[Bool]>
    ) -> (ShareableContentSignal, ManualScheduler) {
        let scheduler = ManualScheduler()
        let signal = ShareableContentSignal(
            eventLog: log,
            probe: { windows.get() },
            scheduler: manualScheduler(scheduler)
        )
        signal.onChange = { value in observed.mutate { $0.append(value) } }
        retained.append(signal)
        signal.start(
            context: teamsContext,
            lockRank: NativeLifecycleConfig.teams.windowLockRank,
            titleMatch: NativeLifecycleConfig.teams.titleMatch
        )
        return (signal, scheduler)
    }

    func test_a_tokenless_call_window_present_at_engage_stays_present() {
        // The 2026-10-08 shape: a bare topic with no "meeting" token, which the old end-side
        // vocabulary rejected on every poll.
        let windows = LockedBox([Summary(bundleIdentifier: teams2, title: "Weekly sync", windowID: 41, pid: 7)])
        let observed = LockedBox<[Bool]>([])
        let (_, scheduler) = identitySignal(windows, observed: observed)
        scheduler.tick?()
        windows.set([Summary(bundleIdentifier: teams2, title: "Weekly sync (2 people)", windowID: 41, pid: 7)])
        scheduler.tick?()
        XCTAssertEqual(observed.get(), [true], "the locked call window must read present whatever its title becomes")
    }

    func test_the_locked_window_removed_reads_gone_even_as_a_chat_window_appears() {
        let windows = LockedBox([
            Summary(bundleIdentifier: teams2, title: "Weekly sync", windowID: 41, pid: 7),
            Summary(bundleIdentifier: teams2, title: "Chat | Acme", windowID: 12, pid: 7)
        ])
        let observed = LockedBox<[Bool]>([])
        let log = RecordingEventLog()
        let (_, scheduler) = identitySignal(windows, log: log, observed: observed)
        // The call window closes and a popped-out chat (also a bare segment) appears in the same poll.
        windows.set([
            Summary(bundleIdentifier: teams2, title: "Chat | Acme", windowID: 12, pid: 7),
            Summary(bundleIdentifier: teams2, title: "Jane Doe", windowID: 99, pid: 7)
        ])
        scheduler.tick?()
        XCTAssertEqual(observed.get(), [true, false])
        let locked = log.entries.first { $0.action == "shareable_content_window_locked" }
        XCTAssertEqual(locked?.attributes["count"], "1", "the main window's Chat | shape must not be locked beside a call window")
        let gone = log.entries.last { $0.action == "shareable_content_window_present" }
        XCTAssertEqual(gone?.attributes["appeared_matching"], "1")
        XCTAssertEqual(gone?.attributes["locked_windows"], "1")
    }

    func test_a_window_opened_after_the_lock_never_reads_present_for_the_call() {
        let windows = LockedBox([Summary(bundleIdentifier: teams2, title: "Weekly sync", windowID: 41, pid: 7)])
        let observed = LockedBox<[Bool]>([])
        let (_, scheduler) = identitySignal(windows, observed: observed)
        windows.set([])
        scheduler.tick?()
        windows.set([Summary(bundleIdentifier: teams2, title: "Weekly sync", windowID: 42, pid: 7)])
        scheduler.tick?()
        XCTAssertEqual(observed.get(), [true, false], "no re-lock: a returning reading would revert a real end")
    }

    func test_an_off_screen_call_window_reads_gone_then_present_when_it_returns() {
        // `onScreenWindowsOnly`: a minimised or other-Space call window drops out of the list. Kept
        // visible on purpose (the spec's "do not fix"), and the same id coming back reads present.
        let call = Summary(bundleIdentifier: teams2, title: "Weekly sync", windowID: 41, pid: 7)
        let windows = LockedBox([call])
        let observed = LockedBox<[Bool]>([])
        let (_, scheduler) = identitySignal(windows, observed: observed)
        windows.set([])
        scheduler.tick?()
        windows.set([call])
        scheduler.tick?()
        XCTAssertEqual(observed.get(), [true, false, true])
    }

    func test_windows_without_an_id_never_lock_and_keep_the_title_rule() {
        let windows = LockedBox([Summary(bundleIdentifier: teams2, title: "Weekly sync")])
        let observed = LockedBox<[Bool]>([])
        let log = RecordingEventLog()
        let (_, scheduler) = identitySignal(windows, log: log, observed: observed)
        windows.set([Summary(bundleIdentifier: teams2, title: "Calendar")])
        scheduler.tick?()
        XCTAssertEqual(observed.get(), [true, false])
        XCTAssertFalse(log.entries.contains { $0.action == "shareable_content_window_locked" })
    }

    func test_only_a_chat_pipe_window_is_locked_when_no_bare_segment_exists() {
        let windows = LockedBox([Summary(bundleIdentifier: teams2, title: "Chat | Acme", windowID: 12, pid: 7)])
        let observed = LockedBox<[Bool]>([])
        let log = RecordingEventLog()
        _ = identitySignal(windows, log: log, observed: observed)
        let locked = log.entries.first { $0.action == "shareable_content_window_locked" }
        XCTAssertEqual(locked?.attributes["rank"], "2")
        XCTAssertEqual(observed.get(), [true])
    }

    func test_stop_clears_the_lock() {
        let windows = LockedBox([Summary(bundleIdentifier: teams2, title: "Weekly sync", windowID: 41, pid: 7)])
        let observed = LockedBox<[Bool]>([])
        let (signal, _) = identitySignal(windows, observed: observed)
        signal.stop()
        windows.set([Summary(bundleIdentifier: teams2, title: "Standup", windowID: 50, pid: 7)])
        signal.start(
            context: teamsContext,
            lockRank: NativeLifecycleConfig.teams.windowLockRank,
            titleMatch: NativeLifecycleConfig.teams.titleMatch
        )
        XCTAssertEqual(observed.get(), [true, true], "the new session locked its own window rather than reading the old lock as gone")
    }

    func test_an_older_suffix_call_window_is_locked_before_the_main_window() {
        let windows = LockedBox([
            Summary(bundleIdentifier: teams2, title: "Chat | Acme", windowID: 12, pid: 7),
            Summary(bundleIdentifier: teams2, title: "Standup | Microsoft Teams", windowID: 41, pid: 7)
        ])
        let observed = LockedBox<[Bool]>([])
        let log = RecordingEventLog()
        let (_, scheduler) = identitySignal(windows, log: log, observed: observed)
        windows.set([Summary(bundleIdentifier: teams2, title: "Chat | Acme", windowID: 12, pid: 7)])
        scheduler.tick?()
        XCTAssertEqual(observed.get(), [true, false], "the main window was locked beside the call window")
        XCTAssertEqual(log.entries.first { $0.action == "shareable_content_window_locked" }?.attributes["rank"], "1")
    }

    /// Era A through the engine: the same tokenless call window, read by the old end-side vocabulary
    /// and by identity. The old reading leads an end (vetoed by live process audio, or held without
    /// it); identity leads none, so nothing depends on the veto.
    func test_era_a_window_reading_leads_no_end_under_identity() {
        let oldVocabulary: ShareableContentSignal.TitleMatch = { title in
            let lowered = (title ?? "").lowercased()
            return ["meeting", "microsoft teams"].contains { lowered.contains($0) }
        }
        for identity in [false, true] {
            for processAudioLive in [false, true] {
                let call = Summary(bundleIdentifier: teams2, title: "Weekly sync", windowID: 41, pid: 7)
                let scheduler = ManualScheduler()
                let signal = ShareableContentSignal(probe: { [call] }, scheduler: manualScheduler(scheduler))
                retained.append(signal)
                let readings = LockedBox<[Bool]>([])
                signal.onChange = { value in readings.mutate { $0.append(value) } }
                if identity {
                    signal.start(context: teamsContext, lockRank: NativeLifecycleConfig.teams.windowLockRank,
                                 titleMatch: NativeLifecycleConfig.teams.titleMatch)
                } else {
                    signal.start(context: teamsContext, titleMatch: oldVocabulary)
                }

                let engine = PromotionEngine()
                let start = Date()
                let opener: PrimarySignalKind = processAudioLive ? .processAudioIsRunningInput : .axLeaveButton
                _ = engine.ingest(PrimarySignalEvent(kind: opener, state: .live, timestamp: start, context: teamsContext))
                _ = engine.confirmRecording()
                var last: PromotionEngine.Decision?
                for value in readings.get() {
                    last = engine.ingest(PrimarySignalEvent(
                        kind: .shareableContentWindow, state: value ? .live : .ended,
                        timestamp: start.addingTimeInterval(1), context: teamsContext
                    )) ?? last
                }
                let led = engine.takeVeto() != nil || {
                    if case .endingProvisional = last?.verdict { return true }
                    return false
                }()
                let label = "identity=\(identity) processAudioLive=\(processAudioLive) readings=\(readings.get())"
                XCTAssertEqual(led, !identity, label)
            }
        }
    }
}
