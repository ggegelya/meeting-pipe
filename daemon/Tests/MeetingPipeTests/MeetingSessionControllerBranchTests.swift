import AVFoundation
import XCTest
@testable import MeetingPipe

/// The first constructible coverage of the daemon's session spine (ARCH4).
///
/// Until the `SessionHost` seam existed, nothing could build a
/// `MeetingSessionController`: it reached through `unowned let coordinator:
/// Coordinator`, whose init constructs ~18 AVFoundation / AppKit subsystems. So
/// every transition in the daemon, including the two invariants ARCHITECTURE.md
/// declares (never two `.recording`; `.stopping` always advances), was enforced
/// by `swift build` and nothing else. `MeetingSessionControllerTests`' own header
/// conceded it covered two static helpers.
///
/// These tests drive the real controller against `FakeSessionHost`, whose state
/// machine, consent store, and workflow store are the real types. The assertions
/// are on state the controller actually drove, not on a mock's expectations.
@MainActor
final class MeetingSessionControllerBranchTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("arch4-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private func makeController(
        workflows: [Workflow] = []
    ) -> (MeetingSessionController, FakeSessionHost) {
        let host = FakeSessionHost(tempDir: tempDir, workflows: workflows)
        return (MeetingSessionController(coordinator: host), host)
    }

    private func source(_ bundleID: String = "us.zoom.xos") -> AppSource {
        AppSource(bundleID: bundleID, displayName: "Zoom")
    }

    /// `beginRecording` commits to a start, then does the work in a detached
    /// `Task`. Wait for a condition that Task establishes, bounded, rather than
    /// yielding a fixed number of times: a fixed yield count passes on an idle
    /// machine and flakes under load (it did, once, while the pipeline suite was
    /// saturating the CPU).
    private func waitUntil(
        _ predicate: () -> Bool,
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if predicate() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 500_000)  // 0.5 ms
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
    }

    /// For the branches that return *before* spawning the Task. Nothing to await;
    /// a yield only proves the synchronous path already ran.
    private func settle() async {
        await Task.yield()
    }

    // MARK: - beginRecording: the permission gate

    func test_beginRecording_withoutMicPermission_refusesAndDeepLinksToPermissions() async {
        let (controller, host) = makeController()
        host.micAuthorizationStatus = .denied

        controller.beginRecording(source: source(), summaryMode: .auto)
        await settle()

        // A silent recording with an empty transcript is worse than no recording,
        // so the refusal is total: the recorder is never touched.
        XCTAssertEqual(host.recorderSpy.startCallCount, 0)
        XCTAssertEqual(host.notifierSpy.errors.count, 1)
        XCTAssertTrue(host.notifierSpy.errors[0].contains("Microphone permission"))
        // And it is actionable, not just an error string.
        XCTAssertEqual(host.menuPreferencesPermissionsCallCount, 1)
        XCTAssertEqual(host.statusBarSpy.idleCount, 1)
        XCTAssertEqual(host.stateMachine.current, .idle)
    }

    func test_beginRecording_withUndeterminedMicPermission_alsoRefuses() async {
        // Only `.authorized` starts a recording; `.notDetermined` must not be
        // mistaken for "probably fine".
        let (controller, host) = makeController()
        host.micAuthorizationStatus = .notDetermined

        controller.beginRecording(source: source(), summaryMode: .auto)
        await settle()

        XCTAssertEqual(host.recorderSpy.startCallCount, 0)
        XCTAssertEqual(host.stateMachine.current, .idle)
    }

    // MARK: - beginRecording: dry run

    func test_beginRecording_inDryRun_skipsRecorderAndHUDAndReturnsToIdle() async {
        let (controller, host) = makeController()
        host.dryRun = true

        controller.beginRecording(source: source(), summaryMode: .auto)
        await settle()

        // Detection ran; the recorder and HUD deliberately did not, so a workday
        // logs as detection-only signals.
        XCTAssertEqual(host.recorderSpy.startCallCount, 0)
        XCTAssertEqual(host.hudSpy.presentCount, 0)
        XCTAssertEqual(host.notifierSpy.recordingStarted.count, 0)
        XCTAssertEqual(host.statusBarSpy.idleCount, 1)
        XCTAssertEqual(host.stateMachine.current, .idle)
    }

    // MARK: - beginRecording: the second-press guard

    func test_beginRecording_ignoresASecondPressWhileAStartIsInFlight() async {
        // Five stacked `recorder.start()` calls froze the daemon on 2026-06-12.
        // The engine bring-up is async, so a second toggle press lands while the
        // first start is still resolving.
        let (controller, host) = makeController()
        host.recorderSpy.startBehaviour = .hang

        controller.beginRecording(source: source(), summaryMode: .auto)
        controller.beginRecording(source: source(), summaryMode: .auto)
        controller.beginRecording(source: source(), summaryMode: .auto)
        await waitUntil({ host.recorderSpy.startCallCount >= 1 }, "the first start to be entered")

        XCTAssertEqual(host.recorderSpy.startCallCount, 1)
    }

    func test_beginRecording_acceptsANewStartOnceTheFirstResolved() async {
        // The guard must not latch: a failed start has to leave the door open.
        let (controller, host) = makeController()
        host.recorderSpy.startBehaviour = .fail(MeetingRecorder.RecorderError.engineStartFailed("boom"))

        controller.beginRecording(source: source(), summaryMode: .auto)
        await waitUntil({ host.notifierSpy.errors.count == 1 }, "the failed start to resolve")
        XCTAssertEqual(host.recorderSpy.startCallCount, 1)

        host.recorderSpy.startBehaviour = .succeed
        controller.beginRecording(source: source(), summaryMode: .auto)
        await waitUntil({ host.recorderSpy.startCallCount == 2 }, "the second start")
    }

    // MARK: - beginRecording: failure routing

    func test_beginRecording_whenTheRecorderFails_notifiesAndReturnsToIdle() async {
        let (controller, host) = makeController()
        host.recorderSpy.startBehaviour = .fail(MeetingRecorder.RecorderError.engineStartFailed("boom"))

        controller.beginRecording(source: source(), summaryMode: .auto)
        await waitUntil({ host.notifierSpy.errors.count == 1 }, "the failure to be surfaced")

        XCTAssertTrue(host.notifierSpy.errors[0].contains("Could not start recording"))
        XCTAssertEqual(host.statusBarSpy.idleCount, 1)
        XCTAssertEqual(host.stateMachine.current, .idle)
        // A failed start arms the re-prompt cooldown, so a renegotiating headset
        // does not re-prompt in a loop.
        XCTAssertTrue(host.stateMachine.isCoolingDown(bundleID: "us.zoom.xos", cooldownSec: 60))
    }

    func test_beginRecording_manualFailure_armsNoCooldown() async {
        // A manual recording has no bundle to cool down; `recordingStartInFlight`
        // already bounds re-clicks there.
        let (controller, host) = makeController()
        host.recorderSpy.startBehaviour = .fail(MeetingRecorder.RecorderError.engineStartFailed("boom"))

        controller.beginRecording(source: nil, summaryMode: .auto)
        await waitUntil({ host.notifierSpy.errors.count == 1 }, "the failure to be surfaced")

        XCTAssertEqual(host.stateMachine.current, .idle)
    }

    // MARK: - beginRecording: the workflow override

    func test_beginRecording_honoursThePendingWorkflowOverrideAndClearsIt() async {
        var chosen = Workflow(name: "Client work")
        chosen.contextPrompt = "client"
        var other = Workflow(name: "Standup")
        other.contextPrompt = "standup"
        let (controller, host) = makeController(workflows: [other, chosen])

        controller.pendingWorkflowOverride = chosen.id
        controller.beginRecording(source: source(), summaryMode: .auto)
        await waitUntil({ !host.statusBarSpy.recordings.isEmpty }, "the recording to be announced")

        XCTAssertEqual(host.recorderSpy.startCallCount, 1)
        XCTAssertEqual(controller.activeWorkflow?.id, chosen.id)
        XCTAssertEqual(host.statusBarSpy.recordings.first?.workflow?.id, chosen.id)
        // The override is one-shot: it must not leak into the next meeting.
        XCTAssertNil(controller.pendingWorkflowOverride)
    }

    func test_beginRecording_startsRecordingStateAndPresentsTheHUD() async {
        let (controller, host) = makeController()

        controller.beginRecording(source: source(), summaryMode: .byo)
        await waitUntil({ !host.statusBarSpy.recordings.isEmpty }, "the recording to be announced")

        XCTAssertEqual(host.recorderSpy.startCallCount, 1)
        XCTAssertEqual(host.hudSpy.presentCount, 1)
        XCTAssertEqual(host.notifierSpy.recordingStarted.count, 1)
        XCTAssertEqual(host.statusBarSpy.recordings.count, 1)
        // The summary mode reaches the status bar intact: a BYO meeting must not
        // become an Anthropic auto-summary.
        XCTAssertEqual(host.statusBarSpy.recordings.first?.summaryMode, .byo)
        XCTAssertTrue(host.stateMachine.current.isRecording)
    }

    func test_beginRecording_passesTheLiveOutputDirAndVoiceProcessingToTheRecorder() async {
        let (controller, host) = makeController()
        host.liveVoiceProcessing = true

        controller.beginRecording(source: source(), summaryMode: .auto)
        await waitUntil({ host.recorderSpy.lastStartArgs != nil }, "the recorder to be started")

        XCTAssertEqual(host.recorderSpy.lastStartArgs?.outputDir, host.liveOutputDir)
        XCTAssertEqual(host.recorderSpy.lastStartArgs?.voiceProcessing, true)
    }

    // MARK: - handleMeetingStarted: prompt vs auto-consent

    func test_handleMeetingStarted_promptsWithTheLivePromptTimeout() {
        let (controller, host) = makeController()
        host.livePromptTimeoutSec = 17

        controller.handleMeetingStarted(source: source())

        XCTAssertEqual(host.promptSpy.presentCount, 1)
        XCTAssertEqual(host.promptSpy.lastAutoDismissAfter, 17)
        XCTAssertEqual(host.statusBarSpy.promptedSources.count, 1)
        XCTAssertTrue(host.stateMachine.current.isPrompting)
        // Prompting is not recording.
        XCTAssertEqual(host.recorderSpy.startCallCount, 0)
    }

    func test_handleMeetingStarted_autoConsentedAppRecordsWithoutPrompting() async {
        let (controller, host) = makeController()
        host.liveAutoConsentApps = ["us.zoom.xos"]

        controller.handleMeetingStarted(source: source())
        await waitUntil({ host.stateMachine.current.isRecording }, "auto-consent to start recording")

        XCTAssertEqual(host.promptSpy.presentCount, 0)
        XCTAssertEqual(host.recorderSpy.startCallCount, 1)
    }

    func test_handleMeetingStarted_withinTheRepromptCooldown_doesNothing() {
        let (controller, host) = makeController()
        host.stateMachine.recordCooldownEnd(bundleID: "us.zoom.xos")

        controller.handleMeetingStarted(source: source())

        // A lifecycle `.starting` queued just before disengage must not re-prompt
        // the meeting the user just skipped.
        XCTAssertEqual(host.promptSpy.presentCount, 0)
        XCTAssertEqual(host.recorderSpy.startCallCount, 0)
        XCTAssertEqual(host.stateMachine.current, .idle)
    }

    // MARK: - The invariant ARCHITECTURE.md declares

    func test_neverTwoRecordings_aSecondBeginWhileRecordingIsIgnored() async {
        let (controller, host) = makeController()

        controller.beginRecording(source: source(), summaryMode: .auto)
        await waitUntil({ host.stateMachine.current.isRecording }, "the first recording to start")

        // A second detection while already recording must not stack a start.
        controller.handleMeetingStarted(source: source("com.microsoft.teams2"))
        await settle()

        XCTAssertEqual(host.recorderSpy.startCallCount, 1)
        XCTAssertTrue(host.stateMachine.current.isRecording)
    }
}

/// `AppState`'s cases carry associated values, so a test that only cares "which
/// state" would otherwise pattern-match five times over.
private extension AppState {
    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }

    var isPrompting: Bool {
        if case .prompting = self { return true }
        return false
    }
}
