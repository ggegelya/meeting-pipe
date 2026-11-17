import CoreAudio
import XCTest
@testable import MeetingPipeCore

/// DET23: the mic-holder monitor on a fake HAL, inline (an injected scheduler runs everything on
/// the caller). Each acceptance bullet of the task is one test here.
final class MicHolderMonitorTests: XCTestCase {

    // MARK: - Fakes

    private final class FakeHAL: MicHolderMonitor.HAL {
        struct Object {
            var bundleID: String?
            var pid: pid_t
            var input: Bool?
            var output: Bool? = false
            var devices: [AudioObjectID]? = [77]
        }
        var objects: [AudioObjectID: Object] = [:]
        var listFailure: OSStatus?
        var parents: [pid_t: pid_t] = [:]
        private(set) var listReads = 0
        private(set) var identityReads: [AudioObjectID: Int] = [:]

        func processObjectIDs() -> Result<[AudioObjectID], MicHolderMonitor.HALReadError> {
            listReads += 1
            if let listFailure { return .failure(.init(status: listFailure)) }
            return .success(objects.keys.sorted())
        }
        func bundleID(_ object: AudioObjectID) -> String? {
            identityReads[object, default: 0] += 1
            return objects[object]?.bundleID
        }
        func pid(_ object: AudioObjectID) -> pid_t { objects[object]?.pid ?? -1 }
        func isRunningInput(_ object: AudioObjectID) -> Bool? { objects[object]?.input }
        func isRunningOutput(_ object: AudioObjectID) -> Bool? { objects[object]?.output }
        func inputDevices(_ object: AudioObjectID) -> [AudioObjectID]? { objects[object]?.devices }
        func parentPID(_ pid: pid_t) -> pid_t? { parents[pid] }
    }

    private final class Clock {
        var now: TimeInterval = 1000
    }

    private final class Timers {
        var actions: [TimeInterval: () -> Void] = [:]
        var oneShots: [(TimeInterval, () -> Void)] = []
        func fire(_ interval: TimeInterval) { actions[interval]?() }
        func runOneShots() {
            let pending = oneShots
            oneShots = []
            for (_, work) in pending { work() }
        }
    }

    private static let teams = "com.microsoft.teams2"
    private static let chrome = "com.google.Chrome"
    private static let families = ["com.microsoft.teams", teams, chrome, "us.zoom.xos"]

    private var hal: FakeHAL!
    private var clock: Clock!
    private var timers: Timers!
    private var log: RecordingEventLog!

    override func setUp() {
        super.setUp()
        hal = FakeHAL()
        clock = Clock()
        timers = Timers()
        log = RecordingEventLog()
    }

    private func makeMonitor(ownPID: pid_t = 999, roots: [pid_t: String] = [:]) -> MicHolderMonitor {
        let timers = self.timers!
        let clock = self.clock!
        return MicHolderMonitor(
            hal: hal,
            halBus: CoreAudioHALBus(),
            eventLog: log,
            familyIDs: Self.families,
            ownPID: ownPID,
            runningRoots: { roots },
            clock: { clock.now },
            scheduler: { interval, action in
                timers.actions[interval] = action
                return { timers.actions[interval] = nil }
            },
            oneShot: { delay, work in timers.oneShots.append((delay, work)) }
        )
    }

    /// One second on: advance the clock and fire the 1 Hz tick.
    private func tick(_ seconds: TimeInterval = 1) {
        clock.now += seconds
        timers.fire(MicHolderMonitor.tickInterval)
    }

    private func rows(_ action: String) -> [RecordingEventLog.Entry] {
        log.entries.filter { $0.action == action }
    }

    private var micHolderRows: [RecordingEventLog.Entry] {
        log.entries.filter { $0.action.hasPrefix("mic_holder_") }
    }

    // MARK: - Acceptance

    func testHeldReleasedHeldEmitsOneChangeRowEachAndAGapOfTheRightLength() {
        hal.objects[10] = .init(bundleID: "com.microsoft.teams2.modulehost", pid: 500, input: false)
        let monitor = makeMonitor()
        monitor.start()
        XCTAssertTrue(micHolderRows.isEmpty, "a released family at start is a silent baseline")

        hal.objects[10]?.input = true
        tick()
        hal.objects[10]?.input = false
        tick()
        tick(22) // 23 s of gap in all, the shape the audit could only bound
        hal.objects[10]?.input = true
        tick()

        let changes = rows("mic_holder_changed")
        XCTAssertEqual(changes.map { $0.attributes["level"] }, ["held", "released", "held"])
        XCTAssertEqual(changes.map { $0.attributes["family"] }, [Self.teams, Self.teams, Self.teams])
        XCTAssertEqual(changes[0].attributes["bundle_id"], "com.microsoft.teams2.modulehost")
        XCTAssertEqual(changes[1].attributes["prior_sec"], "1.0", "the release row carries the held span")
        let gaps = rows("mic_holder_gap")
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps[0].attributes["gap_sec"], "23.0")
        XCTAssertEqual(gaps[0].attributes["via"], "released")
    }

    func testAnUnchangedSampleEmitsNothing() {
        hal.objects[10] = .init(bundleID: Self.teams, pid: 500, input: true)
        let monitor = makeMonitor()
        monitor.start()
        let afterStart = log.entries.count
        XCTAssertEqual(rows("mic_holder_changed").count, 1, "a held family at start is news")
        for _ in 0..<30 { tick() }
        XCTAssertEqual(log.entries.count, afterStart)
    }

    func testAnObjectVanishingThenReRegisteringUnderANewIdInsideFiveSecondsReadsUnknownNotReleased() {
        hal.objects[10] = .init(bundleID: Self.teams, pid: 500, input: true)
        let monitor = makeMonitor()
        monitor.start()
        hal.objects[10] = nil
        tick()
        XCTAssertEqual(monitor.snapshot()[Self.teams]?.level, .unknown)
        hal.objects[11] = .init(bundleID: Self.teams, pid: 500, input: false)
        tick(2)
        XCTAssertEqual(monitor.snapshot()[Self.teams]?.level, .unknown, "still inside the grace")
        hal.objects[11]?.input = true
        tick()
        XCTAssertEqual(monitor.snapshot()[Self.teams]?.level, .held)
        XCTAssertEqual(rows("mic_holder_changed").map { $0.attributes["level"] }, ["held", "unknown", "held"])
        XCTAssertEqual(rows("mic_holder_changed")[1].attributes["reason"], "vanished")
        XCTAssertFalse(rows("mic_holder_changed").contains { $0.attributes["level"] == "released" })
    }

    func testAVanishedHolderReadsReleasedOnceTheGraceRunsOut() {
        hal.objects[10] = .init(bundleID: Self.teams, pid: 500, input: true)
        let monitor = makeMonitor()
        monitor.start()
        hal.objects[10] = nil
        tick()
        tick(MicHolderLedger.vanishGrace)
        XCTAssertEqual(monitor.snapshot()[Self.teams]?.level, .released)
        XCTAssertEqual(rows("mic_holder_changed").map { $0.attributes["level"] }, ["held", "unknown", "released"])
    }

    func testAFailedListReadReadsUnknownWithOneRowNotOnePerFamily() {
        hal.objects[10] = .init(bundleID: Self.teams, pid: 500, input: true)
        let monitor = makeMonitor()
        monitor.start()
        hal.listFailure = -1
        tick()
        tick()
        XCTAssertEqual(Set(monitor.snapshot().values.map(\.level)), [.unknown])
        XCTAssertEqual(rows("mic_holder_list_unknown").count, 1)
        XCTAssertEqual(rows("mic_holder_changed").count, 1, "only the start's held row")

        hal.listFailure = nil
        tick()
        XCTAssertEqual(monitor.snapshot()[Self.teams]?.level, .held)
        XCTAssertEqual(rows("mic_holder_list_unknown").last?.attributes["recovered"], "true")
        XCTAssertEqual(rows("mic_holder_changed").count, 1, "a family that read the same across the outage writes nothing")
    }

    func testEveryMatchedReadFailingReadsUnknown() {
        hal.objects[10] = .init(bundleID: Self.teams, pid: 500, input: false)
        let monitor = makeMonitor()
        monitor.start()
        hal.objects[10]?.input = nil
        tick()
        XCTAssertEqual(monitor.snapshot()[Self.teams]?.level, .unknown)
        XCTAssertEqual(rows("mic_holder_changed").last?.attributes["reason"], "read_failed")
    }

    func testAReadingOlderThanThreeSecondsReadsUnknown() {
        hal.objects[10] = .init(bundleID: Self.teams, pid: 500, input: true)
        let monitor = makeMonitor()
        monitor.start()
        XCTAssertEqual(monitor.snapshot(at: clock.now + 3)[Self.teams]?.level, .held)
        XCTAssertEqual(monitor.snapshot(at: clock.now + 3.5)[Self.teams]?.level, .unknown)
    }

    func testAStallOfTenSecondsEmitsSamplerSilentOnce() {
        let monitor = makeMonitor()
        monitor.start()
        clock.now += 9
        monitor.checkSamplerForTesting()
        XCTAssertTrue(rows("mic_holder_sampler_silent").isEmpty)
        clock.now += 1
        monitor.checkSamplerForTesting()
        clock.now += 5
        monitor.checkSamplerForTesting()
        XCTAssertEqual(rows("mic_holder_sampler_silent").count, 1)
        XCTAssertEqual(rows("mic_holder_sampler_silent").first?.attributes["silent_sec"], "10.0")

        tick()
        clock.now += 10
        monitor.checkSamplerForTesting()
        XCTAssertEqual(rows("mic_holder_sampler_silent").count, 2, "a tick re-arms the watchdog")
    }

    func testAChromeHelperIsAttributedByPidAncestry() {
        hal.objects[20] = .init(bundleID: nil, pid: 702, input: true)
        hal.parents = [702: 701, 701: 700, 700: 1]
        let monitor = makeMonitor(roots: [700: Self.chrome])
        monitor.start()
        XCTAssertEqual(monitor.snapshot()[Self.chrome]?.level, .held)
        XCTAssertEqual(rows("mic_holder_changed").first?.attributes["pid"], "702")
    }

    func testTheDaemonsOwnPidIsNeverAHolder() {
        // Even an object whose bundle prefix matches a family: the recorder's own input is not a call.
        hal.objects[30] = .init(bundleID: Self.teams, pid: 999, input: true)
        hal.objects[31] = .init(bundleID: nil, pid: 999, input: true)
        let monitor = makeMonitor(ownPID: 999, roots: [999: Self.teams])
        monitor.start()
        tick()
        XCTAssertEqual(monitor.snapshot()[Self.teams]?.level, .released)
        XCTAssertTrue(rows("mic_holder_changed").isEmpty)
    }

    func testABurstOfListChangesProducesAtMostOneRefreshPerSecond() {
        let monitor = makeMonitor()
        monitor.start()
        let readsAfterStart = hal.listReads
        for _ in 0..<6 { monitor.listChangedForTesting() }
        XCTAssertEqual(timers.oneShots.count, 1, "the burst folds into one scheduled refresh")
        XCTAssertEqual(timers.oneShots.first?.0, MicHolderMonitor.refreshWindow)
        XCTAssertEqual(hal.listReads, readsAfterStart, "nothing reads inside the window")
        clock.now += 1
        timers.runOneShots()
        XCTAssertEqual(hal.listReads, readsAfterStart + 1)

        clock.now += 1
        monitor.listChangedForTesting()
        XCTAssertEqual(hal.listReads, readsAfterStart + 2, "a window old: refresh at once")
        monitor.listChangedForTesting()
        XCTAssertEqual(hal.listReads, readsAfterStart + 2)
    }

    // MARK: - Shape

    func testTheLongestRegistryIdWins() {
        XCTAssertEqual(MicHolderMonitor.family(forBundleID: "com.microsoft.teams2.modulehost", in: Self.families), Self.teams)
        XCTAssertEqual(MicHolderMonitor.family(forBundleID: "com.microsoft.teams.helper", in: Self.families), "com.microsoft.teams")
        XCTAssertEqual(MicHolderMonitor.family(forBundleID: "com.google.Chrome.helper", in: Self.families), Self.chrome)
        XCTAssertNil(MicHolderMonitor.family(forBundleID: "com.google.Chromebook", in: Self.families))
    }

    func testIdentityIsReadOncePerObject() {
        hal.objects[10] = .init(bundleID: Self.teams, pid: 500, input: false)
        hal.objects[40] = .init(bundleID: "com.apple.Music", pid: 600, input: false)
        let monitor = makeMonitor()
        monitor.start()
        for _ in 0..<5 { tick() }
        XCTAssertEqual(hal.identityReads[10], 1)
        XCTAssertEqual(hal.identityReads[40], 1, "a negative attribution is cached too")
        hal.objects[40] = nil
        tick()
        hal.objects[40] = .init(bundleID: "com.apple.Music", pid: 601, input: false)
        tick()
        XCTAssertEqual(hal.identityReads[40], 2, "an id that left the list is described again")
    }

    func testTheSightingLagIsLoggedOncePerHold() {
        hal.objects[10] = .init(bundleID: Self.teams, pid: 500, input: false)
        let monitor = makeMonitor()
        monitor.start()
        hal.objects[10]?.input = true
        tick()
        clock.now += 12
        monitor.noteSighting(bundleID: "com.microsoft.teams2")
        monitor.noteSighting(bundleID: "com.microsoft.teams2")
        XCTAssertEqual(rows("mic_holder_sighting_lag").count, 1)
        XCTAssertEqual(rows("mic_holder_sighting_lag").first?.attributes["lag_sec"], "12.0")
        hal.objects[10]?.input = false
        tick()
        XCTAssertEqual(rows("mic_holder_changed").last?.attributes["sighted"], "true")
        XCTAssertEqual(rows("mic_holder_changed").last?.attributes["recorded"], "false")
    }

    func testTheHeartbeatReportsOnceAMinute() {
        let monitor = makeMonitor()
        monitor.start()
        for _ in 0..<59 { tick() }
        XCTAssertTrue(rows("mic_holder_heartbeat").isEmpty)
        tick()
        XCTAssertEqual(rows("mic_holder_heartbeat").count, 1)
        XCTAssertEqual(rows("mic_holder_heartbeat").first?.attributes["ticks"], "61", "the start sample counts")
    }

    func testIOChangesAreLoggedOnlyOnChange() {
        hal.objects[10] = .init(bundleID: Self.teams, pid: 500, input: true, output: false, devices: [77])
        let monitor = makeMonitor()
        monitor.start()
        tick()
        XCTAssertTrue(rows("mic_holder_io_changed").isEmpty)
        hal.objects[10]?.devices = [78]
        tick()
        tick()
        XCTAssertEqual(rows("mic_holder_io_changed").count, 1)
        XCTAssertEqual(rows("mic_holder_io_changed").first?.attributes["input_devices"], "[78]")
    }

    /// The 2-rows-a-second bar: an edge is one change row (plus the gap on a re-hold), never a
    /// third `io_changed` for the device set the edge itself moved.
    func testNoTickWritesMoreThanTwoRowsAcrossAReleaseAndAReHold() {
        hal.objects[10] = .init(bundleID: Self.teams, pid: 500, input: false)
        let monitor = makeMonitor()
        monitor.start()
        var perTick: [Int] = []
        for input in [true, false, true, false, true] {
            let before = micHolderRows.count
            hal.objects[10]?.input = input
            tick()
            perTick.append(micHolderRows.count - before)
        }
        XCTAssertEqual(perTick, [1, 1, 2, 1, 2])
        XCTAssertTrue(rows("mic_holder_io_changed").isEmpty)
        XCTAssertEqual(rows("mic_holder_changed").first?.attributes["input_devices"], "[77]")
    }

    func testOutputTogglingOnAFamilyThatIsNotHeldWritesNothing() {
        hal.objects[20] = .init(bundleID: Self.chrome + ".helper", pid: 700, input: false, output: false)
        let monitor = makeMonitor()
        monitor.start()
        for index in 0..<10 {
            hal.objects[20]?.output = index.isMultiple(of: 2)
            tick()
        }
        XCTAssertTrue(micHolderRows.isEmpty)
    }

    func testAHolderThatVanishesAtTheEndOfARecordedCallStillOpensTheReleaseWindow() {
        hal.objects[10] = .init(bundleID: Self.teams, pid: 500, input: true)
        let monitor = makeMonitor()
        monitor.start()
        monitor.setRecording(true)
        hal.objects[10] = nil
        tick()
        tick(MicHolderLedger.vanishGrace)
        XCTAssertEqual(rows("mic_holder_changed").map { $0.attributes["level"] }, ["held", "unknown", "released"])
        XCTAssertEqual(rows("mic_holder_changed")[1].attributes["recorded"], "true", "the edge out of held carries the span flags")
        monitor.noteLevels(micDb: -40, systemDb: -30)
        monitor.setRecording(false)
        XCTAssertEqual(rows("mic_holder_release_levels").count, 1)
        XCTAssertEqual(rows("mic_holder_release_levels").first?.attributes["truncated"], "true")
    }

    func testAnObjectWhoseIdentityCouldNotBeReadIsReadAgain() {
        hal.objects[10] = .init(bundleID: nil, pid: -1, input: true)
        let monitor = makeMonitor()
        monitor.start()
        hal.objects[10]?.bundleID = Self.teams
        hal.objects[10]?.pid = 500
        tick()
        XCTAssertEqual(monitor.snapshot()[Self.teams]?.level, .held)
    }

    func testANegativeAttributionIsReDecidedOnceItExpires() {
        hal.objects[20] = .init(bundleID: nil, pid: 702, input: true)
        hal.parents = [702: 700]
        var roots: [pid_t: String] = [:]
        let timers = self.timers!
        let clock = self.clock!
        let monitor = MicHolderMonitor(
            hal: hal, halBus: CoreAudioHALBus(), eventLog: log, familyIDs: Self.families, ownPID: 999,
            runningRoots: { roots }, clock: { clock.now },
            scheduler: { interval, action in timers.actions[interval] = action; return { timers.actions[interval] = nil } },
            oneShot: { _, work in work() }
        )
        monitor.start()
        XCTAssertEqual(monitor.snapshot()[Self.chrome]?.level, .released, "Chrome had not shown up in the running apps yet")
        roots = [700: Self.chrome]
        tick()
        XCTAssertEqual(monitor.snapshot()[Self.chrome]?.level, .released, "the negative holds inside its TTL")
        tick(MicHolderMonitor.negativeIdentityTTL)
        XCTAssertEqual(monitor.snapshot()[Self.chrome]?.level, .held)
    }

    func testAReleaseDuringARecordingLogsTheSystemLevelWindow() {
        hal.objects[10] = .init(bundleID: Self.teams, pid: 500, input: true)
        let monitor = makeMonitor()
        monitor.start()
        monitor.setRecording(true)
        hal.objects[10]?.input = false
        tick()
        for _ in 0..<MicHolderLevelPacker.releaseWindowSeconds { monitor.noteLevels(micDb: -40, systemDb: -30) }
        let window = rows("mic_holder_release_levels")
        XCTAssertEqual(window.count, 1)
        XCTAssertEqual(window.first?.attributes["family"], Self.teams)
        XCTAssertEqual(window.first?.attributes["truncated"], "false")
        XCTAssertEqual(rows("mic_holder_levels").count, 2, "two packed minutes, not 120 rows")
        monitor.setRecording(false)
        XCTAssertEqual(rows("mic_holder_levels").count, 2, "nothing left to flush")
    }

    func testStopEndsTheMonitor() {
        hal.objects[10] = .init(bundleID: Self.teams, pid: 500, input: true)
        let monitor = makeMonitor()
        monitor.start()
        monitor.stop()
        XCTAssertTrue(timers.actions.isEmpty)
        XCTAssertTrue(monitor.snapshot().isEmpty)
    }

    // MARK: - Packer

    func testThePackerWritesOneRowAMinuteAndFlushesAPartialOne() {
        var packer = MicHolderLevelPacker()
        var out: [MicHolderLevelPacker.Row] = []
        for second in 0..<90 {
            out += packer.note(micDb: Float(-second), systemDb: second.isMultiple(of: 2) ? -20 : nil, held: ["a"])
        }
        XCTAssertEqual(out.count, 1)
        guard case let .minute(mic, sys, held) = out[0] else { return XCTFail("minute row") }
        XCTAssertEqual(mic.count, 60)
        XCTAssertEqual(sys[0], -20)
        XCTAssertNil(sys[1])
        XCTAssertEqual(held, ["a"])
        packer.noteRelease(family: "b")
        _ = packer.note(micDb: -50, systemDb: -60, held: ["b"])
        let tail = packer.finish()
        XCTAssertEqual(tail.count, 2)
        XCTAssertEqual(tail[0], .afterRelease(family: "b", systemDb: [-60], regainedAfter: 1, truncated: true))
    }
}

// MARK: - MIC22: the holder's devices reach the snapshot

extension MicHolderMonitorTests {

    /// MIC22 compares these against the device we capture, so a held family publishes them and a
    /// released one publishes none.
    func testAHeldFamilysReadingCarriesItsInputDevices_andAReleasedOneNone() {
        hal.objects[10] = .init(bundleID: "com.microsoft.teams2.modulehost", pid: 500, input: true, devices: [77, 78])
        hal.objects[11] = .init(bundleID: Self.chrome, pid: 600, input: false, devices: [79])
        let monitor = makeMonitor()
        monitor.start()
        let readings = monitor.currentSnapshot().readings
        XCTAssertEqual(readings[Self.teams]?.level, .held)
        XCTAssertEqual(readings[Self.teams]?.inputDevices, [77, 78])
        XCTAssertEqual(readings[Self.chrome]?.inputDevices, [])

        hal.objects[10]?.input = false
        tick()
        XCTAssertEqual(monitor.currentSnapshot().readings[Self.teams]?.inputDevices, [], "released: nothing to compare")
    }
}
