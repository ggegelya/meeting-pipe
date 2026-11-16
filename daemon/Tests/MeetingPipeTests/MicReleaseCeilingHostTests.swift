import XCTest
@testable import MeetingPipe
@testable import MeetingPipeCore

/// END23 at the session spine: a Teams recording stops 120 s into a monitor-read mic release,
/// whatever the engine reads, with the cut at the release. The monitor is the fake host's stated
/// snapshot; the ceiling's tick is driven by hand on a virtual clock, as END28's is.
@MainActor
final class MicReleaseCeilingHostTests: XCTestCase {

    private var tempDir: URL!
    private var logs: URL!
    private var hosts: [FakeSessionHost] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("end23-\(UUID().uuidString)", isDirectory: true)
        logs = tempDir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        setenv("MEETINGPIPE_LOGS_DIR", logs.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("MEETINGPIPE_LOGS_DIR")
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private let teams = AppSource(bundleID: "com.microsoft.teams2", displayName: "Microsoft Teams")
    private let context = MeetingLifecycleContext(bundleID: "com.microsoft.teams2", kind: .native, pid: 4321)
    /// The monitor clock's reading at the recording's commit, and the wall clock it matches.
    private let armedAt: TimeInterval = 1000
    private let wallAtArm = Date(timeIntervalSince1970: 1_800_000_000)
    /// The recorder started 600 s before the ceiling was armed in these hand-built recordings.
    private let recordedBeforeArm: TimeInterval = 600

    private struct Rig {
        let controller: MeetingSessionController
        let host: FakeSessionHost
        let file: URL
    }

    private func rows(_ action: String) -> [[String: Any]] {
        let text = (try? String(contentsOf: logs.appendingPathComponent("events.jsonl"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }.filter { $0["action"] as? String == action }
    }

    private func waitUntil(_ predicate: () -> Bool, _ what: String, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if predicate() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
    }

    /// A Teams recording running with the ceiling armed, built by hand so the engine can be put in
    /// any phase without a lifecycle end reaching the controller (no consumers run).
    private func recording(captureMode: CaptureMode = .captureFirst) -> Rig {
        let host = FakeSessionHost(tempDir: tempDir)
        hosts.append(host)
        let controller = MeetingSessionController(coordinator: host)
        let file = tempDir.appendingPathComponent("20261112-174606.wav")
        host.stateMachine.setRecording(file: file, source: teams, summaryMode: .auto)
        host.recorderSpy.startedAt = wallAtArm.addingTimeInterval(-recordedBeforeArm)
        controller.activeCaptureMode = captureMode
        host.micHolderSpy.snapshot = snapshot(armedAt, .held, leftHeldAt: nil)
        controller.armMicReleaseCeiling(file: file, source: teams)
        return Rig(controller: controller, host: host, file: file)
    }

    private func snapshot(_ at: TimeInterval, _ level: MicHolderLevel, leftHeldAt: TimeInterval?) -> MicHolderMonitor.Snapshot {
        MicHolderMonitor.Snapshot(at: at, readings: [
            "com.microsoft.teams2": .init(level: level, since: leftHeldAt ?? at, readAt: at, leftHeldAt: leftHeldAt),
            "com.microsoft.teams": .init(level: .released, since: 0, readAt: at, leftHeldAt: nil),
        ])
    }

    /// One tick a second from `from` for `seconds`, the wall clock `wallOffset` ahead of the
    /// monitor's (a sleep moves only the wall clock).
    private func tick(_ rig: Rig, from: TimeInterval, seconds: Int, _ level: MicHolderLevel, leftHeldAt: TimeInterval?, wallOffset: TimeInterval = 0) {
        for offset in 0..<seconds {
            let at = from + TimeInterval(offset)
            rig.host.micHolderSpy.snapshot = snapshot(at, level, leftHeldAt: leftHeldAt)
            rig.controller.micReleaseCeilingTick(file: rig.file, now: wallAtArm.addingTimeInterval(at - armedAt + wallOffset))
        }
    }

    /// Held for 10 s from the arm, then released at 1010 for 130 s of ticks.
    private func releaseFor130s(_ rig: Rig, wallOffsetAfterStart: TimeInterval = 0) {
        tick(rig, from: armedAt, seconds: 10, .held, leftHeldAt: nil)
        tick(rig, from: 1011, seconds: 5, .released, leftHeldAt: 1010)
        tick(rig, from: 1016, seconds: 125, .released, leftHeldAt: 1010, wallOffset: wallOffsetAfterStart)
    }

    /// Seconds from the recorder's start to the release at 1010 on the monitor's clock.
    private var expectedCutSeconds: Double { recordedBeforeArm + 10 }

    // MARK: - The 20261112-174606 shape

    func test_aReleaseOnAnEndedEngine_stopsTheRecording_cutAtTheRelease() async throws {
        let rig = recording()
        let adapter = EngageOffMainTests.CountingAdapter()
        rig.host.lifecycleCoord = MeetingLifecycleCoordinator(adapters: [adapter])
        try rig.host.lifecycleCoord.engage(context: context, handle: LifecycleAdapterHandle())
        adapter.sink?(PrimarySignalEvent(kind: .axLeaveButton, state: .live, timestamp: Date(), context: context))
        adapter.sink?(PrimarySignalEvent(kind: .shareableContentWindow, state: .ended, timestamp: Date(), context: context))
        await waitUntil({ rig.host.lifecycleCoord.isTerminal }, "the terminal engine")

        tick(rig, from: armedAt, seconds: 10, .held, leftHeldAt: nil)
        tick(rig, from: 1011, seconds: 119, .released, leftHeldAt: 1010)
        XCTAssertEqual(rig.host.recorderSpy.stopCallCount, 0, "119 s counted is not yet the ceiling")
        tick(rig, from: 1130, seconds: 2, .released, leftHeldAt: 1010)
        await waitUntil({ rig.host.recorderSpy.stopCallCount == 1 }, "the stop")

        let row = try XCTUnwrap(rows("mic_release_ceiling_stop").first)
        XCTAssertEqual(row["bundle_id"] as? String, teams.bundleID)
        XCTAssertEqual(row["file"] as? String, rig.file.lastPathComponent)
        XCTAssertEqual(row["engine_phase"] as? String, "ended")
        XCTAssertEqual(row["hold_open"] as? Bool, false)
        XCTAssertEqual(try XCTUnwrap(row["released_sec"] as? Double), 121, accuracy: 0.01)
        let trim = try XCTUnwrap(rows("held_end_trimmed").first)
        XCTAssertEqual(try XCTUnwrap(trim["limit_sec"] as? Double), expectedCutSeconds, accuracy: 0.01)
        XCTAssertEqual(trim["stop_route"] as? String, "mic_release_ceiling")
        XCTAssertEqual(trim["mode"] as? String, "suggested", "a lossless capture keeps the tail")
        XCTAssertEqual(rig.host.recorderSpy.lastStopLimitSeconds, .some(nil))
        XCTAssertNil(rig.controller.resumeCandidate, "a ceiling stop leaves no resume behind")
    }

    func test_anOpenHold_isReleasedNotConcluded_andNoHoldTimerSurvives() async throws {
        let rig = recording()
        rig.controller.beginTeardownHold(context: context)
        XCTAssertTrue(rig.controller.holdPolicy.isOpen)
        XCTAssertNotNil(rig.controller.cancelHoldTimer)

        releaseFor130s(rig)
        await waitUntil({ rig.host.recorderSpy.stopCallCount == 1 }, "the stop")

        XCTAssertFalse(rig.controller.holdPolicy.isOpen)
        XCTAssertNil(rig.controller.cancelHoldTimer)
        XCTAssertEqual(rig.host.hudSpy.confirmingEndStates, [true, false])
        XCTAssertEqual(rows("mic_release_ceiling_stop").first?["hold_open"] as? Bool, true)
        // END21's Stop rule would refuse this cut (the engine never read the mic released); the
        // ceiling's evidence is the monitor, so it cuts anyway.
        let trim = try XCTUnwrap(rows("held_end_trimmed").first)
        XCTAssertEqual(try XCTUnwrap(trim["limit_sec"] as? Double), expectedCutSeconds, accuracy: 0.01)
    }

    /// The hold is released, not concluded: with real engine evidence that would give END21's Stop
    /// rule a cut of its own (the mic released and the window gone after it), the monitor's cut
    /// still wins. Concluding the hold instead would overwrite `pendingEndTrimAt` with the engine's.
    func test_anOpenHoldWithItsOwnEvidence_stillCutsAtTheMonitorsRelease() async throws {
        let host = FakeSessionHost(tempDir: tempDir)
        hosts.append(host)
        host.recorderSpy.lastSystemFires = 1
        let file = tempDir.appendingPathComponent("20261117-100000.wav")
        host.recorderSpy.fileToReturn = file
        let adapter = StartInFlightTests.MicAdapter()
        host.lifecycleCoord = MeetingLifecycleCoordinator(adapters: [adapter])
        let controller = MeetingSessionController(coordinator: host)
        controller.engageSeams.buildHandles = { _, _ in nil }
        controller.startConsumers()
        defer { controller.shutdownConsumers() }
        controller.beginRecording(source: teams, summaryMode: .auto)
        await waitUntil({ if case .recording = host.stateMachine.current { return true }; return false }, "the recording")
        try host.lifecycleCoord.engage(context: context, handle: LifecycleAdapterHandle())
        adapter.emit(.axLeaveButton, .live, context)
        adapter.emit(.processAudioIsRunningInput, .live, context)
        adapter.emit(.shareableContentWindow, .live, context)
        await waitUntil({ host.lifecycleCoord.current == .inMeeting(context: context) }, "in meeting")
        try? await Task.sleep(nanoseconds: 20_000_000)
        adapter.emit(.axLeaveButton, .ended, context)
        await waitUntil({ controller.holdPolicy.isOpen }, "the hold")
        try? await Task.sleep(nanoseconds: 1_100_000_000)
        adapter.emit(.processAudioIsRunningInput, .ended, context)
        try? await Task.sleep(nanoseconds: 20_000_000)
        adapter.emit(.shareableContentWindow, .ended, context)
        await waitUntil({ host.lifecycleCoord.holdEvidence?.callWindowBacksRelease == true }, "the engine's evidence")
        let engineRelease = try XCTUnwrap(host.lifecycleCoord.holdEvidence?.releasedAt)
        let startedAt = try XCTUnwrap(host.recorderSpy.startedAt)

        // Re-arm on the virtual monitor clock and run a release whose wall-clock cut is far from
        // the engine's.
        host.micHolderSpy.snapshot = snapshot(armedAt, .held, leftHeldAt: nil)
        controller.armMicReleaseCeiling(file: file, source: teams)
        releaseFor130s(Rig(controller: controller, host: host, file: file))
        await waitUntil({ host.recorderSpy.stopCallCount == 1 }, "the stop")

        let limit = try XCTUnwrap(rows("held_end_trimmed").first?["limit_sec"] as? Double)
        XCTAssertEqual(limit, wallAtArm.addingTimeInterval(10).timeIntervalSince(startedAt), accuracy: 0.01)
        XCTAssertNotEqual(limit, engineRelease.timeIntervalSince(startedAt), accuracy: 1)
    }

    func test_aRegulatedCapture_truncatesAtTheRelease() async throws {
        let rig = recording(captureMode: .regulatedGate)
        releaseFor130s(rig)
        await waitUntil({ rig.host.recorderSpy.stopCallCount == 1 }, "the stop")
        XCTAssertEqual(rows("held_end_trimmed").first?["mode"] as? String, "truncated")
        let limit = try XCTUnwrap(rig.host.recorderSpy.lastStopLimitSeconds ?? nil)
        XCTAssertEqual(limit, expectedCutSeconds, accuracy: 0.01)
    }

    func test_aSleepBetweenTheReleaseAndTheStop_doesNotMoveTheCut() async throws {
        let rig = recording()
        // An hour of sleep after the release was first seen: the monitor's clock skips it, the
        // wall clock does not.
        releaseFor130s(rig, wallOffsetAfterStart: 3600)
        await waitUntil({ rig.host.recorderSpy.stopCallCount == 1 }, "the stop")
        let trim = try XCTUnwrap(rows("held_end_trimmed").first)
        XCTAssertEqual(try XCTUnwrap(trim["limit_sec"] as? Double), expectedCutSeconds, accuracy: 0.01)
    }

    func test_aTickAfterTheStop_doesNothing() async throws {
        let rig = recording()
        releaseFor130s(rig)
        await waitUntil({ rig.host.recorderSpy.stopCallCount == 1 }, "the stop")
        XCTAssertNil(rig.controller.micReleaseCeiling, "stopRecording disarms it")
        tick(rig, from: 1141, seconds: 200, .released, leftHeldAt: 1010)
        XCTAssertEqual(rig.host.recorderSpy.stopCallCount, 1)
        XCTAssertEqual(rows("mic_release_ceiling_stop").count, 1)
    }

    func test_aShortGapThatReturns_keepsTheRecording() {
        let rig = recording()
        tick(rig, from: armedAt, seconds: 10, .held, leftHeldAt: nil)
        tick(rig, from: 1010, seconds: 23, .released, leftHeldAt: 1010)
        tick(rig, from: 1033, seconds: 200, .held, leftHeldAt: nil)
        XCTAssertEqual(rig.host.recorderSpy.stopCallCount, 0)
        XCTAssertTrue(rows("mic_release_ceiling_stop").isEmpty)
    }

    // MARK: - Arming

    func test_onlyANativeTeamsRecordingIsArmed() async throws {
        for (source, armed) in [
            (teams, true),
            (AppSource(bundleID: "us.zoom.xos", displayName: "Zoom"), false),
            (AppSource(bundleID: "com.google.Chrome", displayName: "Teams", kind: .browser), false),
        ] {
            let host = FakeSessionHost(tempDir: tempDir)
            hosts.append(host)
            let controller = MeetingSessionController(coordinator: host)
            controller.engageSeams.buildHandles = { _, _ in nil }
            host.recorderSpy.fileToReturn = tempDir.appendingPathComponent("\(source.bundleID).wav")
            controller.beginRecording(source: source, summaryMode: .auto)
            await waitUntil({ if case .recording = host.stateMachine.current { return true }; return false }, "the recording")
            XCTAssertEqual(controller.micReleaseCeiling != nil, armed, source.bundleID)
            XCTAssertEqual(controller.cancelMicReleaseCeilingTimer != nil, armed, source.bundleID)
            controller.disarmMicReleaseCeiling()
        }

        let host = FakeSessionHost(tempDir: tempDir)
        hosts.append(host)
        let controller = MeetingSessionController(coordinator: host)
        host.recorderSpy.fileToReturn = tempDir.appendingPathComponent("manual.wav")
        controller.beginRecording(source: nil, summaryMode: .auto)
        await waitUntil({ if case .recording = host.stateMachine.current { return true }; return false }, "the manual recording")
        XCTAssertNil(controller.micReleaseCeiling, "a source-less recording's end is END11's")
    }
}
