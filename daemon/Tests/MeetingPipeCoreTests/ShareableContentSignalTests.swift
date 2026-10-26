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

        signal.start(context: teamsContext) { title in
            (title ?? "").lowercased().contains("meeting")
        }
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

    func test_cadence_switches_between_active_and_idle() {
        let scheduler = ManualScheduler()
        var windows: [Summary] = []
        let signal = ShareableContentSignal(
            probe: { windows },
            scheduler: manualScheduler(scheduler),
            activeInterval: 0.5,
            idleInterval: 1.0
        )

        signal.start(context: teamsContext)
        XCTAssertEqual(scheduler.lastInterval, 1.0, "Starts on idle cadence until a window is present")

        windows = [Summary(bundleIdentifier: "com.microsoft.teams2", title: "Standup")]
        scheduler.tick?()
        XCTAssertEqual(scheduler.lastInterval, 0.5, "Switches to active cadence once a window is present")

        windows = []
        scheduler.tick?()
        XCTAssertEqual(scheduler.lastInterval, 1.0, "Returns to idle when window disappears")
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

        signal.start(context: teamsContext) { title in
            (title ?? "").lowercased().contains("meeting")
        }

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
}
