import XCTest
@testable import MeetingPipe
@testable import MeetingPipeCore

/// END27's app half: a record start never inherits a terminal engine.
///
/// On 2026-11-12 the resume `20261112-174606` started 63 ms after a first-reading window-gone had
/// ended its engine. `engageLifecycleIfNeeded` saw an adapter attached, logged `already_engaged`
/// and kept it, and an `.ended` engine ignores every later signal, so the 15:50:34 leave opened
/// no hold and the recording ran 380 s until the owner stopped it. These drive the real
/// controller and coordinator with `EngageOffMainTests`' counting adapter and build.
@MainActor
final class TerminalEngineReengageTests: XCTestCase {

    private var tempDir: URL!
    private var logs: URL!
    private var hosts: [FakeSessionHost] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("end27-\(UUID().uuidString)", isDirectory: true)
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
    private let discovery = MeetingLifecycleContext(bundleID: "com.microsoft.teams2", kind: .native, pid: 4321)

    private func makeController() -> (MeetingSessionController, FakeSessionHost, EngageOffMainTests.CountingAdapter, EngageOffMainTests.GatedBuild) {
        let host = FakeSessionHost(tempDir: tempDir)
        hosts.append(host)
        host.recorderSpy.lastSystemFires = 1
        let adapter = EngageOffMainTests.CountingAdapter()
        host.lifecycleCoord = MeetingLifecycleCoordinator(adapters: [adapter])
        let controller = MeetingSessionController(coordinator: host)
        let build = EngageOffMainTests.GatedBuild(gated: false)
        controller.engageSeams.buildHandles = { source, _ in build.build(source) }
        return (controller, host, adapter, build)
    }

    private func waitUntil(
        _ predicate: () -> Bool,
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if predicate() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
    }

    private func eventRows(action: String) -> [[String: Any]] {
        let text = (try? String(contentsOf: logs.appendingPathComponent("events.jsonl"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }.filter { $0["action"] as? String == action }
    }

    private func emit(_ adapter: EngageOffMainTests.CountingAdapter, _ kind: PrimarySignalKind, _ state: PrimarySignalState, _ context: MeetingLifecycleContext) {
        adapter.sink?(PrimarySignalEvent(kind: kind, state: state, timestamp: Date(), context: context))
    }

    /// The incident end to end: the engine ends on a first reading, the resume starts on it, the
    /// start re-engages instead of keeping it, and the later leave opens a hold.
    func test_aResumeOnATerminalEngine_reengages_andTheLeaveOpensAHold() async throws {
        let (controller, host, adapter, _) = makeController()
        controller.startConsumers()
        defer { controller.shutdownConsumers() }

        // Discovery engages and the engine ends on its first readings (an adapter with no process
        // audio, so nothing holds the window-gone): the consumer prompts and then withdraws it.
        // DET18: a weak end only withdraws a prompt once the microphone has been released, so the
        // host reads the call as down here; a weak end alone keeps the panel up.
        host.liveCallSignal = .callIsDown
        try host.lifecycleCoord.engage(context: discovery, handle: LifecycleAdapterHandle())
        emit(adapter, .axLeaveButton, .live, discovery)
        emit(adapter, .shareableContentWindow, .ended, discovery)
        await waitUntil({ host.lifecycleCoord.isTerminal }, "the terminal engine")
        await waitUntil(
            { host.promptSpy.presentCount == 1 && host.promptSpy.dismissCount >= 1 && host.stateMachine.current == .idle },
            "the prompt the consumer raised and withdrew"
        )
        XCTAssertEqual(adapter.starts.count, 1)

        // The way back inside the window: no prompt, the recording starts on the terminal engine.
        controller.resumeCandidate = ResumeAfterEnd(
            bundleID: teams.bundleID, stem: "20261112-172307",
            endedAt: Date().addingTimeInterval(-38.6), workflowID: nil, summaryMode: .auto
        )
        host.recorderSpy.fileToReturn = tempDir.appendingPathComponent("20261112-174606.wav")
        controller.handleMeetingStarted(source: teams)

        await waitUntil({ adapter.starts.count == 2 }, "the re-engage")
        let rows = eventRows(action: "lifecycle_reengaged")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["reason"] as? String, "terminal_at_start")
        XCTAssertEqual(rows.first?["bundle_id"] as? String, teams.bundleID)
        XCTAssertEqual(rows.first?["has_handles"] as? Bool, true)
        XCTAssertTrue(
            eventRows(action: "lifecycle_engage_skipped").allSatisfy { $0["reason"] as? String != "already_engaged" },
            "the terminal engine is not kept as already engaged"
        )

        // The fresh engagement hears its signals, is promoted for the recording, and the leave holds.
        let recorded = try XCTUnwrap(adapter.starts.last.map {
            MeetingLifecycleContext(bundleID: teams.bundleID, kind: .native, pid: $0.pid)
        })
        emit(adapter, .axLeaveButton, .live, recorded)
        await waitUntil({ host.lifecycleCoord.current == .inMeeting(context: recorded) }, "the late promotion")
        emit(adapter, .processAudioIsRunningInput, .ended, recorded)
        await waitUntil({ controller.holdPolicy.isOpen }, "the hold the leave opens")
        if case .recording = host.stateMachine.current {} else {
            XCTFail("a weak end holds with the recorder running")
        }
    }

    /// DET18 item 4: a weak end keeps the prompt up over a terminal engine, and a Record from that
    /// kept panel re-engages rather than recording with no end detection.
    func test_aRecordFromAPromptKeptThroughAWeakEnd_reengagesTheTerminalEngine() async throws {
        let (controller, host, adapter, _) = makeController()
        controller.startConsumers()
        defer { controller.shutdownConsumers() }

        try host.lifecycleCoord.engage(context: discovery, handle: LifecycleAdapterHandle())
        emit(adapter, .axLeaveButton, .live, discovery)
        emit(adapter, .shareableContentWindow, .ended, discovery)
        await waitUntil({ host.lifecycleCoord.isTerminal }, "the terminal engine")
        await waitUntil({ host.promptSpy.mayHaveEndedCount == 1 }, "the panel kept and marked")
        XCTAssertEqual(host.promptSpy.dismissCount, 0, "a weak end no longer withdraws the panel")
        guard case .prompting(let prompted) = host.stateMachine.current else {
            return XCTFail("the prompt is still up, got \(host.stateMachine.current)")
        }

        host.recorderSpy.fileToReturn = tempDir.appendingPathComponent("20261116-101500.wav")
        XCTAssertTrue(controller.resolvePromptPick(.record, source: prompted))
        await waitUntil({ adapter.starts.count == 2 }, "the re-engage")
        XCTAssertEqual(eventRows(action: "lifecycle_reengaged").first?["reason"] as? String, "terminal_at_start")
    }

    /// A start against a live engine keeps it: the guard's protection for every non-terminal phase.
    func test_aStartAgainstALiveEngine_isStillSkippedAsAlreadyEngaged() async throws {
        let (controller, host, adapter, build) = makeController()
        try host.lifecycleCoord.engage(context: discovery, handle: LifecycleAdapterHandle())
        emit(adapter, .axLeaveButton, .live, discovery)
        host.lifecycleCoord.confirmRecording()
        await waitUntil({ host.lifecycleCoord.current == .inMeeting(context: discovery) }, "a live engine")

        controller.engageLifecycleIfNeeded(source: teams, handles: build.build(teams))

        XCTAssertEqual(adapter.starts.count, 1, "the live adapter is not restarted")
        XCTAssertEqual(eventRows(action: "lifecycle_engage_skipped").first?["reason"] as? String, "already_engaged")
        XCTAssertTrue(eventRows(action: "lifecycle_reengaged").isEmpty)
        await Task.yield()
        XCTAssertEqual(host.lifecycleCoord.current, .inMeeting(context: discovery), "and its engine is not reset")
    }
}
