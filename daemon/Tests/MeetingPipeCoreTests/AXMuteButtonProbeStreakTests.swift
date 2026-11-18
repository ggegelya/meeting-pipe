import ApplicationServices
import XCTest
@testable import MeetingPipeCore
import MeetingPipeTestSupport

/// MIC20: an unreadable mute button costs the log one kept row and one summary row per streak,
/// not one row a second; a re-resolve that finds nothing says so; and while an end is held the
/// probe polls slowly and stays quiet, but still delivers a known read at once.
final class AXMuteButtonProbeStreakTests: XCTestCase {

    /// T13: loaded per test and thrown, not force-tried in a static initialiser: a trap there killed the
    /// xctest process, so one broken resource bundle read as a crash with every later test unrun.
    private var catalogue: MuteLabels!

    override func setUpWithError() throws {
        try super.setUpWithError()
        catalogue = try MuteLabelsLoader.loadDefault()
    }

    private final class Box {
        var title: String? = "Unmute"   // .muted
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var resolveCalls = 0
    }

    private func makeProbe(
        _ box: Box,
        log: RecordingEventLog,
        scheduler: @escaping AXMuteButtonProbe.Scheduler = { _, _ in {} },
        rearmThreshold: Int = 100
    ) -> AXMuteButtonProbe {
        AXMuteButtonProbe(
            app: "teams", axBus: AXObserverBus(), catalogue: catalogue, eventLog: log,
            probe: { _ in .init(title: box.title) },
            scheduler: scheduler, localeResolver: { "en" }, elementTimeout: { _ in },
            rearmThreshold: rearmThreshold, clock: { box.now }
        )
    }

    private func rows(_ log: RecordingEventLog, _ action: String) -> [[String: String]] {
        log.entries.filter { $0.action == action }.map(\.attributes)
    }

    private func button() -> AXUIElement { AXUIElementCreateApplication(1) }

    // MARK: - One kept row, one summary

    func test_knownThenUnknownReads_logOneKeptRow_andOneSummaryAtTheNextKnownRead() {
        let box = Box(), log = RecordingEventLog()
        let probe = makeProbe(box, log: log)
        probe.start(pid: 1, bundleID: "com.microsoft.teams2", button: button())

        box.title = "Mic is not available"
        for _ in 0..<7 {
            probe.evaluate(reason: "health_poll")
            box.now += 1
        }
        XCTAssertEqual(rows(log, "ax_mute_button_state_kept").count, 1, "one kept row per streak, not one per read")
        XCTAssertTrue(rows(log, "ax_mute_button_unknown_streak").isEmpty, "the summary waits for the streak to end")

        box.title = "Mute"
        probe.evaluate(reason: "health_poll")
        let summary = rows(log, "ax_mute_button_unknown_streak")
        XCTAssertEqual(summary.count, 1)
        XCTAssertEqual(summary.first?["reads"], "7")
        XCTAssertEqual(summary.first?["ended_by"], "known")
        XCTAssertEqual(summary.first?["kept_state"], "muted")
        XCTAssertEqual(summary.first?["streak_sec"], "7.0")
        XCTAssertEqual(summary.first?["rearm_attempts"], "0")

        // A second streak is a second kept row.
        box.title = nil
        probe.evaluate(reason: "health_poll")
        XCTAssertEqual(rows(log, "ax_mute_button_state_kept").count, 2)
    }

    func test_aStreakStillOpenAtStop_writesItsSummaryThere() {
        let box = Box(), log = RecordingEventLog()
        let probe = makeProbe(box, log: log)
        probe.start(pid: 1, bundleID: "com.microsoft.teams2", button: button())
        box.title = nil
        for _ in 0..<4 { probe.evaluate(reason: "health_poll") }

        probe.stop()
        let summary = rows(log, "ax_mute_button_unknown_streak")
        XCTAssertEqual(summary.count, 1)
        XCTAssertEqual(summary.first?["reads"], "4")
        XCTAssertEqual(summary.first?["ended_by"], "stop")
        probe.stop()
        XCTAssertEqual(rows(log, "ax_mute_button_unknown_streak").count, 1, "a second stop has nothing to close")
    }

    /// An unknown read from the first read on is its own `ax_mute_button_state` row already, and
    /// latches nothing, so it writes no summary unless a re-resolve was tried.
    func test_aStreakWithNoKnownReadingBeforeIt_andNoRearm_writesNoSummary() {
        let box = Box(), log = RecordingEventLog()
        box.title = nil
        let probe = makeProbe(box, log: log)
        probe.start(pid: 1, bundleID: "com.microsoft.teams2", button: button())
        probe.evaluate(reason: "health_poll")
        probe.stop()
        XCTAssertTrue(rows(log, "ax_mute_button_unknown_streak").isEmpty)
        XCTAssertTrue(rows(log, "ax_mute_button_state_kept").isEmpty)
    }

    // MARK: - A failed re-resolve is logged

    func test_aResolverThatFindsNothing_logsOneRearmFailedPerStreak_andTheSummaryCountsTheAttempts() {
        let box = Box(), log = RecordingEventLog()
        let probe = makeProbe(box, log: log, rearmThreshold: 2)
        probe.start(pid: 1, bundleID: "com.microsoft.teams2", button: button(), resolveElement: {
            box.resolveCalls += 1
            return nil
        })
        box.title = nil
        for _ in 0..<6 { probe.evaluate(reason: "health_poll") }
        XCTAssertEqual(box.resolveCalls, 3)
        XCTAssertEqual(rows(log, "ax_mute_button_rearm_failed").count, 1, "once per streak")
        XCTAssertTrue(rows(log, "ax_mute_button_rearmed").isEmpty)

        box.title = "Mute"
        probe.evaluate(reason: "health_poll")
        let summary = rows(log, "ax_mute_button_unknown_streak").first
        XCTAssertEqual(summary?["rearm_attempts"], "3")
        XCTAssertEqual(summary?["rearm_failures"], "3")

        box.title = nil
        for _ in 0..<2 { probe.evaluate(reason: "health_poll") }
        XCTAssertEqual(rows(log, "ax_mute_button_rearm_failed").count, 2, "a new streak logs its own failure")
    }

    func test_aResolverThatSucceeds_stillLogsRearmed_andNoFailure() {
        let box = Box(), log = RecordingEventLog()
        let probe = makeProbe(box, log: log, rearmThreshold: 2)
        probe.start(pid: 1, bundleID: "com.microsoft.teams2", button: button(), resolveElement: {
            AXUIElementCreateApplication(2)
        })
        box.title = nil
        for _ in 0..<2 { probe.evaluate(reason: "health_poll") }
        XCTAssertEqual(rows(log, "ax_mute_button_rearmed").count, 1)
        XCTAssertTrue(rows(log, "ax_mute_button_rearm_failed").isEmpty)
    }

    // MARK: - A held end

    func test_whileAnEndIsHeld_thePollStaysSlow_andWritesNoKeptRows_andClearingRestoresFast() {
        let box = Box(), log = RecordingEventLog()
        let scheduler = ManualScheduler()
        let probe = makeProbe(box, log: log, scheduler: scheduler.schedule)
        probe.start(pid: 1, bundleID: "com.microsoft.teams2", button: button())
        XCTAssertEqual(scheduler.scheduledDelays, [AXMuteButtonProbe.defaultPollInterval])

        probe.setEndHeld(true)
        box.title = nil
        for _ in 0..<10 { scheduler.tick() }
        XCTAssertEqual(scheduler.scheduledDelays.last, AXMuteButtonProbe.defaultSlowPollInterval, "held: slow despite unknown reads")
        XCTAssertEqual(scheduler.scheduledDelays.count, 2, "one move to slow, and it holds")
        XCTAssertTrue(rows(log, "ax_mute_button_state_kept").isEmpty, "no kept rows while held")

        probe.setEndHeld(false)
        scheduler.tick()
        XCTAssertEqual(scheduler.scheduledDelays.last, AXMuteButtonProbe.defaultPollInterval, "the next unknown read is news again")
        XCTAssertEqual(rows(log, "ax_mute_button_state_kept").count, 1, "a streak that outlives the hold writes its row then")

        probe.stop()
        let summary = rows(log, "ax_mute_button_unknown_streak").first
        XCTAssertEqual(summary?["reads"], "11")
        XCTAssertEqual(summary?["held_reads"], "10")
    }

    func test_aKnownReadDuringAHold_isDeliveredAtOnce() {
        let box = Box(), log = RecordingEventLog()
        var states: [MuteLabels.State] = []
        let probe = makeProbe(box, log: log)
        probe.onChange = { states.append($0.state) }
        probe.start(pid: 1, bundleID: "com.microsoft.teams2", button: button())
        probe.setEndHeld(true)
        box.title = nil
        probe.evaluate(reason: "health_poll")
        box.title = "Mute"   // a rescued call, unmuted
        probe.evaluate(reason: "health_poll")
        XCTAssertEqual(states, [.muted, .unmuted])
    }

    func test_aNewStart_clearsTheHeldFlag() {
        let box = Box(), log = RecordingEventLog()
        let probe = makeProbe(box, log: log)
        probe.start(pid: 1, bundleID: "com.microsoft.teams2", button: button())
        probe.setEndHeld(true)
        probe.start(pid: 1, bundleID: "com.microsoft.teams2", button: button())
        box.title = nil
        probe.evaluate(reason: "health_poll")
        XCTAssertEqual(rows(log, "ax_mute_button_state_kept").count, 1, "the next recording's probe is not held")
    }

    // MARK: - The flag's path: MicGate and its adapter

    func test_micGate_forwardsTheHeldFlagToItsActiveAdapters_andStopClearsIt() throws {
        let adapter = HeldRecordingAdapter()
        let gate = MicGate(
            catalogue: catalogue, halBus: CoreAudioHALBus(), axBus: AXObserverBus(), adapters: [adapter]
        )
        try gate.start(
            context: MeetingLifecycleContext(bundleID: "com.microsoft.teams2", kind: .native, pid: 1),
            handle: MicGateAdapterHandle()
        )
        gate.setEndHeld(true)
        XCTAssertTrue(gate.isEndHeld)
        gate.setEndHeld(false)
        XCTAssertEqual(adapter.held, [true, false])

        gate.setEndHeld(true)
        gate.stop()
        XCTAssertFalse(gate.isEndHeld, "a hold never carries into the next recording's gate")
    }

    /// The one link production depends on: without `NativeMuteAdapter.setEndHeld` the protocol's
    /// no-op default would swallow the flag and the probe would never back off.
    func test_nativeMuteAdapter_carriesTheHeldFlagToItsProbe() throws {
        let box = Box(), log = RecordingEventLog()
        let scheduler = ManualScheduler()
        let adapter = NativeMuteAdapter(config: .teams, probe: makeProbe(box, log: log, scheduler: scheduler.schedule))
        try adapter.start(
            context: MeetingLifecycleContext(bundleID: "com.microsoft.teams2", kind: .native, pid: 1),
            handle: MicGateAdapterHandle(muteButton: button()),
            sink: { _ in }
        )
        adapter.setEndHeld(true)
        box.title = nil
        for _ in 0..<3 { scheduler.tick() }
        XCTAssertEqual(scheduler.scheduledDelays.last, AXMuteButtonProbe.defaultSlowPollInterval)
        XCTAssertTrue(rows(log, "ax_mute_button_state_kept").isEmpty)
    }
}

private final class HeldRecordingAdapter: MicGateAdapter {
    let bundleIDs: Set<String> = ["com.microsoft.teams2"]
    let app = "teams"
    private(set) var held: [Bool] = []

    func start(
        context: MeetingLifecycleContext,
        handle: MicGateAdapterHandle,
        sink: @escaping (AXMuteButtonProbe.Event) -> Void
    ) throws {}

    func stop() {}

    func setEndHeld(_ held: Bool) { self.held.append(held) }
}
