import ApplicationServices
import XCTest
@testable import MeetingPipe
@testable import MeetingPipeCore

/// END20 at the session spine: what happens to a start between `beginRecording` and the recorder
/// coming up. REC7 latched an end there only for a prompt-origin start; the resume, auto-consent and
/// hotkey starts dropped it, and a Stop pressed meanwhile was a no-op from `.idle` and abandoned the
/// prompt from `.prompting` while the start still committed. The recorder spy parks each start so
/// the end or the Stop lands inside the bring-up, then releases it.
@MainActor
final class StartInFlightTests: XCTestCase {

    private var tempDir: URL!
    private var logs: URL!
    private var hosts: [FakeSessionHost] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("end20-\(UUID().uuidString)", isDirectory: true)
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
    private let teamsEnd = EndingReason(leadingSignal: "process_audio_is_running_input_false", confirmedBy: ["shareable_content_window_gone"])

    private func makeController() -> (MeetingSessionController, FakeSessionHost) {
        let host = FakeSessionHost(tempDir: tempDir)
        hosts.append(host)
        host.recorderSpy.lastSystemFires = 1
        host.recorderSpy.fileToReturn = tempDir.appendingPathComponent("20261116-120000.wav")
        host.recorderSpy.startBehaviour = .park
        let controller = MeetingSessionController(coordinator: host)
        controller.engageSeams.buildHandles = { _, _ in nil }
        return (controller, host)
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

    private func rows(_ action: String) -> [[String: Any]] {
        let text = (try? String(contentsOf: logs.appendingPathComponent("events.jsonl"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }.filter { $0["action"] as? String == action }
    }

    private func neverCommitted(_ host: FakeSessionHost, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(host.hudSpy.presentCount, 0, "no HUD flashed for a start that never committed", file: file, line: line)
        XCTAssertFalse(
            rows("state_change").contains { $0["to"] as? String == "recording" },
            "the state machine never reached .recording", file: file, line: line
        )
    }

    /// Park a start, land `during` inside its bring-up, release it, and wait for it to resolve.
    private func runParkedStart(_ host: FakeSessionHost, start: () -> Void, during: () -> Void) async {
        start()
        await waitUntil({ host.recorderSpy.startCallCount == 1 }, "the start to park")
        during()
        host.recorderSpy.releasePark()
    }

    // MARK: - An end during the bring-up, every origin

    func test_aResumeStart_thatItsMeetingEndsDuring_isStoppedBeforeItCommits() async {
        let (controller, host) = makeController()
        controller.resumeCandidate = ResumeAfterEnd(
            bundleID: teams.bundleID, stem: "20261116-115500", endedAt: Date(), endedUptime: ProcessInfo.processInfo.systemUptime, workflowID: nil, summaryMode: .auto
        )
        await runParkedStart(host, start: { controller.handleMeetingStarted(source: teams) }) {
            controller.handleMeetingEnded(bundleID: teams.bundleID, reason: teamsEnd)
        }
        await waitUntil({ host.recorderSpy.stopCallCount == 1 }, "the fresh recording to stop")
        neverCommitted(host)
        let row = rows("recording_ended_during_start").first
        XCTAssertEqual(row?["origin"] as? String, "resume")
        XCTAssertEqual(row?["leading_signal"] as? String, teamsEnd.leadingSignal)
        await waitUntil({ host.stateMachine.current == .idle }, "the flush")
    }

    func test_anAutoConsentStart_thatItsMeetingEndsDuring_isStoppedBeforeItCommits() async {
        let (controller, host) = makeController()
        host.addAutoConsentApp(teams.bundleID)
        await runParkedStart(host, start: { controller.handleMeetingStarted(source: teams) }) {
            controller.handleMeetingEnded(bundleID: teams.bundleID, reason: teamsEnd)
        }
        await waitUntil({ host.recorderSpy.stopCallCount == 1 }, "the fresh recording to stop")
        neverCommitted(host)
        XCTAssertEqual(rows("recording_ended_during_start").first?["origin"] as? String, "idle")
        XCTAssertEqual(host.promptSpy.presentCount, 0)
        await waitUntil({ host.stateMachine.current == .idle }, "the flush")
    }

    /// REC7's own case still holds: the user answered Record and the meeting ended as it came up.
    func test_aPromptStart_thatItsMeetingEndsDuring_isStoppedBeforeItCommits() async {
        let (controller, host) = makeController()
        controller.handleMeetingStarted(source: teams)
        XCTAssertEqual(host.stateMachine.current, .prompting(source: teams))
        await runParkedStart(host, start: { controller.beginRecording(source: teams, summaryMode: .auto) }) {
            controller.handleMeetingEnded(bundleID: teams.bundleID, reason: teamsEnd)
        }
        await waitUntil({ host.recorderSpy.stopCallCount == 1 }, "the fresh recording to stop")
        neverCommitted(host)
        XCTAssertEqual(rows("recording_ended_during_start").first?["origin"] as? String, "prompt")
        await waitUntil({ host.stateMachine.current == .idle }, "the flush")
    }

    /// An end for another app, or any end while a source-less start comes up, is not the start's.
    func test_aForeignEnd_andAnEndDuringASourcelessStart_letTheStartCommit() async {
        let (controller, host) = makeController()
        host.addAutoConsentApp(teams.bundleID)
        await runParkedStart(host, start: { controller.handleMeetingStarted(source: teams) }) {
            controller.handleMeetingEnded(bundleID: "us.zoom.xos", reason: teamsEnd)
        }
        await waitUntil({ host.stateMachine.current.isRecordingState }, "the start to commit")
        XCTAssertEqual(host.recorderSpy.stopCallCount, 0)
        XCTAssertTrue(rows("recording_ended_during_start").isEmpty)
        controller.forceStop(reason: "test")
        await waitUntil({ host.stateMachine.current == .idle }, "the flush")

        let (sourceless, quietHost) = makeController()
        await runParkedStart(quietHost, start: { sourceless.toggleManual(surface: .menu) }) {
            sourceless.handleMeetingEnded(bundleID: "com.google.Chrome", reason: teamsEnd)
        }
        await waitUntil({ quietHost.stateMachine.current.isRecordingState }, "the source-less start to commit")
        XCTAssertEqual(quietHost.recorderSpy.stopCallCount, 0, "END19 owns what a source-less recording does with a foreign end")
        sourceless.forceStop(reason: "test")
        await waitUntil({ quietHost.stateMachine.current == .idle }, "the second flush")
    }

    // MARK: - A Stop during the bring-up

    func test_aHotkeyStart_stoppedDuringTheBringUp_neverReachesRecording() async {
        let (controller, host) = makeController()
        await runParkedStart(host, start: { controller.toggleManual(surface: .menu) }) {
            controller.forceStop(reason: "hotkey")
        }
        await waitUntil({ host.recorderSpy.stopCallCount == 1 }, "the fresh recording to stop")
        neverCommitted(host)
        let row = rows("recording_cancelled_during_start").first
        XCTAssertEqual(row?["cancelled_by"] as? String, "hotkey")
        XCTAssertEqual(row?["origin"] as? String, "idle")
        XCTAssertEqual(rows("force_stop").first?["cancelled_start"] as? Bool, true)
        await waitUntil({ host.stateMachine.current == .idle }, "the flush")
    }

    func test_theToggleDuringTheBringUp_cancelsRatherThanStartingAgain() async {
        let (controller, host) = makeController()
        // A start stopped as it comes up has captured no system audio yet; that is not the
        // "remote side missing" a finished recording warns about.
        host.recorderSpy.lastSystemFires = 0
        await runParkedStart(host, start: { controller.toggleManual(surface: .menu) }) {
            controller.toggleManual(surface: .menu)
        }
        await waitUntil({ host.recorderSpy.stopCallCount == 1 }, "the fresh recording to stop")
        neverCommitted(host)
        XCTAssertEqual(host.recorderSpy.startCallCount, 1)
        XCTAssertEqual(rows("recording_cancelled_during_start").first?["cancelled_by"] as? String, "toggle")
        await waitUntil({ host.stateMachine.current == .idle }, "the flush")
        XCTAssertTrue(host.notifierSpy.micOnly.isEmpty, "no coverage warning for a start that never committed")
    }

    /// From `.prompting` a Stop abandoned the prompt and the start Task still committed.
    func test_aPromptStart_stoppedDuringTheBringUp_doesNotCommit() async {
        let (controller, host) = makeController()
        controller.handleMeetingStarted(source: teams)
        await runParkedStart(host, start: { controller.beginRecording(source: teams, summaryMode: .auto) }) {
            controller.forceStop(reason: "hotkey")
        }
        await waitUntil({ host.recorderSpy.stopCallCount == 1 }, "the fresh recording to stop")
        neverCommitted(host)
        XCTAssertEqual(rows("recording_cancelled_during_start").first?["origin"] as? String, "prompt")
        await waitUntil({ host.stateMachine.current == .idle }, "the flush")
    }

    /// A direct second begin is still just ignored (the 2026-06-12 freeze guard).
    func test_aSecondBeginDuringTheBringUp_isStillIgnored() async {
        let (controller, host) = makeController()
        await runParkedStart(host, start: { controller.beginRecording(source: teams, summaryMode: .auto) }) {
            controller.beginRecording(source: teams, summaryMode: .auto)
        }
        await waitUntil({ host.stateMachine.current.isRecordingState }, "the one start to commit")
        XCTAssertEqual(host.recorderSpy.startCallCount, 1)
        XCTAssertTrue(rows("recording_cancelled_during_start").isEmpty)
        controller.forceStop(reason: "test")
        await waitUntil({ host.stateMachine.current == .idle }, "the flush")
    }

    // MARK: - No prompt behind a start, and no second recording

    func test_aStartingDuringAnIdleOriginBringUp_raisesNoPrompt() async {
        let (controller, host) = makeController()
        await runParkedStart(host, start: { controller.toggleManual(surface: .menu) }) {
            controller.handleMeetingStarted(source: teams)
        }
        await waitUntil({ host.stateMachine.current.isRecordingState }, "the start to commit")
        XCTAssertEqual(host.promptSpy.presentCount, 0, "a prompt raised now would outlive the commit")
        controller.forceStop(reason: "test")
        await waitUntil({ host.stateMachine.current == .idle }, "the flush")
    }

    /// F044: "Always" on a stale panel while a recording runs starts nothing and consents nothing.
    func test_chooseAlways_whileRecording_startsNothing() async {
        let (controller, host) = makeController()
        host.stateMachine.setRecording(file: tempDir.appendingPathComponent("live.wav"), source: teams, summaryMode: .auto)
        controller.chooseAlways(source: teams)
        await Task.yield()
        XCTAssertEqual(host.recorderSpy.startCallCount, 0)
        XCTAssertFalse(host.liveAutoConsentApps.contains(teams.bundleID))
        XCTAssertTrue(host.stateMachine.current.isRecordingState)
    }

    func test_chooseAlways_onItsOwnPrompt_consentsAndRecords() async {
        let (controller, host) = makeController()
        host.recorderSpy.startBehaviour = .succeed
        controller.handleMeetingStarted(source: teams)
        controller.chooseAlways(source: teams)
        await waitUntil({ host.stateMachine.current.isRecordingState }, "the recording")
        XCTAssertTrue(host.liveAutoConsentApps.contains(teams.bundleID))
        controller.forceStop(reason: "test")
        await waitUntil({ host.stateMachine.current == .idle }, "the flush")
    }

    /// The recorder refusing a start because one is running must not go idle over it: every stop
    /// path keys on `.recording`, so that recording could not be stopped until Quit.
    func test_alreadyRecording_inTheCatch_leavesTheRecordingAlone() async {
        let (controller, host) = makeController()
        host.recorderSpy.parkFailure = MeetingRecorder.RecorderError.alreadyRecording
        let live = tempDir.appendingPathComponent("live.wav")
        await runParkedStart(host, start: { controller.beginRecording(source: teams, summaryMode: .auto) }) {
            host.stateMachine.setRecording(file: live, source: teams, summaryMode: .auto)
        }
        await waitUntil({ !self.rows("recording_error").isEmpty }, "the refused start to resolve")
        XCTAssertEqual(host.stateMachine.current, .recording(file: live, source: teams, summaryMode: .auto))
        XCTAssertTrue(host.notifierSpy.errors.isEmpty, "no 'could not start' for a recording that is running")
        XCTAssertFalse(host.stateMachine.isCoolingDown(bundleID: teams.bundleID, cooldownSec: 60))
        XCTAssertEqual(rows("recording_error").first?["reason"] as? String, "already_recording")
    }

    // MARK: - With the lifecycle consumer running

    /// A native adapter that publishes process audio, as Teams' does, driven by hand.
    final class MicAdapter: LifecycleAdapter {
        let bundleIDs: Set<String> = ["com.microsoft.teams2"]
        let kind: MeetingLifecycleContext.Kind = .native
        let publishesProcessAudio = true
        private(set) var sink: ((PrimarySignalEvent) -> Void)?
        func start(context: MeetingLifecycleContext, handle: LifecycleAdapterHandle, sink: @escaping (PrimarySignalEvent) -> Void) throws {
            self.sink = sink
        }
        func stop() {}
        func emit(_ kind: PrimarySignalKind, _ state: PrimarySignalState, _ context: MeetingLifecycleContext) {
            sink?(PrimarySignalEvent(kind: kind, state: state, timestamp: Date(), context: context))
        }
    }

    private let context = MeetingLifecycleContext(bundleID: "com.microsoft.teams2", kind: .native, pid: 4321)

    /// END27 and END20 together: the 2026-11-12 15:46:06 first readings (Leave healthy, the window's
    /// initial false 2 ms ahead of process audio's initial true) landing inside a resume's bring-up.
    /// The engine holds the window-gone for the mic, so there is no end for the latch to take, and
    /// the resume commits instead of being stopped by a false reading.
    func test_theResumeRace_duringAResumesBringUp_doesNotStopIt() async throws {
        let (controller, host) = makeController()
        let adapter = MicAdapter()
        host.lifecycleCoord = MeetingLifecycleCoordinator(adapters: [adapter])
        controller.startConsumers()
        defer { controller.shutdownConsumers() }
        controller.resumeCandidate = ResumeAfterEnd(
            bundleID: teams.bundleID, stem: "20261112-172307", endedAt: Date(), endedUptime: ProcessInfo.processInfo.systemUptime, workflowID: nil, summaryMode: .auto
        )
        try host.lifecycleCoord.engage(context: context, handle: LifecycleAdapterHandle())
        await runParkedStart(host, start: { controller.handleMeetingStarted(source: teams) }) {
            adapter.emit(.axLeaveButton, .live, context)
            adapter.emit(.shareableContentWindow, .ended, context)
            adapter.emit(.processAudioIsRunningInput, .live, context)
        }
        await waitUntil({ host.stateMachine.current.isRecordingState }, "the resume to commit")
        await waitUntil({ host.lifecycleCoord.current == .inMeeting(context: context) }, "the engine to be promoted")
        XCTAssertEqual(host.recorderSpy.stopCallCount, 0)
        XCTAssertTrue(rows("recording_ended_during_start").isEmpty)
        controller.forceStop(reason: "test")
        await waitUntil({ host.stateMachine.current == .idle }, "the flush")
    }

    /// D075: a `.starting` for the app being recorded is confirmed even while the title read is
    /// stalled, since the confirm needs no title.
    func test_aStalledTitleRead_doesNotHoldBackTheLateStartConfirm() async throws {
        let (controller, host) = makeController()
        let adapter = MicAdapter()
        host.lifecycleCoord = MeetingLifecycleCoordinator(adapters: [adapter])
        // Captures nothing from the controller or host, so outliving the test is harmless.
        let reads = OSAllocatedUnfairLockBox<Int>(0)
        controller.engageSeams.resolveStartingSource = { context in
            reads.value += 1
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            return MeetingSessionController.appSource(from: context, title: "late")
        }
        host.stateMachine.setRecording(file: tempDir.appendingPathComponent("live.wav"), source: teams, summaryMode: .auto)
        controller.startConsumers()
        defer { controller.shutdownConsumers() }
        try host.lifecycleCoord.engage(context: context, handle: LifecycleAdapterHandle())
        adapter.emit(.axLeaveButton, .live, context)
        await waitUntil({ host.lifecycleCoord.current == .inMeeting(context: context) }, "the late-start confirm")
        XCTAssertEqual(rows("lifecycle_late_start_confirmed").count, 1)
        XCTAssertEqual(reads.value, 0, "the confirm ran first, so the title was never read")
        XCTAssertTrue(rows("prompt_title_deadline_passed").isEmpty, "and it did not wait out the deadline")
    }

    /// D075: a real prompt whose title read stalls shows without the title once the deadline passes.
    func test_aStalledTitleRead_promptsWithoutTheTitleAtTheDeadline() async throws {
        let (controller, host) = makeController()
        let adapter = MicAdapter()
        host.lifecycleCoord = MeetingLifecycleCoordinator(adapters: [adapter])
        controller.startingTitleDeadlineSec = 0.05
        controller.engageSeams.resolveStartingSource = { context in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            return MeetingSessionController.appSource(from: context, title: "late")
        }
        controller.startConsumers()
        defer { controller.shutdownConsumers() }
        try host.lifecycleCoord.engage(context: context, handle: LifecycleAdapterHandle())
        adapter.emit(.axLeaveButton, .live, context)
        await waitUntil({ host.promptSpy.presentCount == 1 }, "the prompt at the deadline")
        guard case .prompting(let shown) = host.stateMachine.current else {
            return XCTFail("expected a prompt, got \(host.stateMachine.current)")
        }
        XCTAssertNil(shown.meetingTitle)
        XCTAssertEqual(rows("prompt_title_deadline_passed").count, 1)
        controller.forceStop(reason: "test")
    }
}

private extension AppState {
    var isRecordingState: Bool {
        if case .recording = self { return true }
        return false
    }
}
