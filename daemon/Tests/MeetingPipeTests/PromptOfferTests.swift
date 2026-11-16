import XCTest
@testable import MeetingPipe
@testable import MeetingPipeCore

/// DET18: an unanswered or flickering prompt no longer loses the call.
///
/// The work-laptop pack held 32 prompt timeouts, every one a skip, and 19 Teams calls (5.3 h, an
/// upper bound) that went wholly unrecorded while the app stayed on screen; a second call in the
/// same app 8 s after a skipped one got no prompt for 25.6 minutes; 298 prompts were withdrawn by a
/// weak end and re-raised within 15 s. These drive the real controller against `FakeSessionHost`.
@MainActor
final class PromptOfferTests: XCTestCase {

    private var tempDir: URL!
    private var logs: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("det18-\(UUID().uuidString)", isDirectory: true)
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
    private let micLive = SkippedMeetingLatch.Reading(processAudio: true)
    private let fullSignature = SkippedMeetingLatch.Reading(processAudio: true, isWinner: true)
    private let bothAbsent = SkippedMeetingLatch.Reading(processAudio: false)

    private func makeController() -> (MeetingSessionController, FakeSessionHost) {
        let host = FakeSessionHost(tempDir: tempDir)
        return (MeetingSessionController(coordinator: host), host)
    }

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
            try? await Task.sleep(nanoseconds: 500_000)
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
    }

    private func dismissedRows() -> [[String: Any]] {
        let text = (try? String(contentsOf: logs.appendingPathComponent("events.jsonl"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }.filter { $0["action"] as? String == "prompt_dismissed" }
    }

    /// Prompt for Teams and let the timeout run with the `skip` default.
    private func promptThenTimeOut(_ controller: MeetingSessionController, _ host: FakeSessionHost) async {
        host.livePromptTimeoutSec = 0.01
        let presented = host.promptSpy.presentCount
        controller.handleMeetingStarted(source: teams)
        XCTAssertEqual(host.promptSpy.presentCount, presented + 1)
        await waitUntil({ host.stateMachine.current == .idle }, "the timeout")
    }

    // MARK: - Items 1 and 2: the timeout is an offer that lives with the span

    func test_aTimeout_isAnOffer_notASkip() async {
        let (controller, host) = makeController()
        await promptThenTimeOut(controller, host)

        XCTAssertFalse(host.stateMachine.isSkipLatched(bundleID: teams.bundleID))
        XCTAssertFalse(host.stateMachine.isCoolingDown(bundleID: teams.bundleID, cooldownSec: 60))
        XCTAssertTrue(host.stateMachine.isOffered(bundleID: teams.bundleID))
        XCTAssertEqual(host.stateMachine.liveSuppressedCandidate(), teams, "the offer holds the prompt's own source")
        XCTAssertEqual(host.statusBarSpy.offeredSources, [teams])
        XCTAssertEqual(host.statusBarSpy.isStillOffered?(), true)
        XCTAssertEqual(host.notifierSpy.skipped.last?.origin, .timedOut)

        // While the span lives the panel does not come back over the same call.
        controller.handleScanReadings([teams.bundleID: micLive])
        controller.handleMeetingStarted(source: teams)
        XCTAssertEqual(host.promptSpy.presentCount, 1)
    }

    /// Acceptance (a): the 2026-10-21 shape. A timeout, the skipped call's span ends, then a
    /// full-signature sighting of the next call in the same app produces a prompt.
    func test_theNextCallInTheSameApp_isPromptedOnceTheSpanEnds() async {
        let (controller, host) = makeController()
        await promptThenTimeOut(controller, host)
        controller.handleScanReadings([teams.bundleID: micLive])

        controller.handleScanReadings([teams.bundleID: bothAbsent])
        controller.handleScanReadings([teams.bundleID: bothAbsent])
        XCTAssertFalse(host.stateMachine.isPromptHeld(bundleID: teams.bundleID))
        XCTAssertEqual(host.statusBarSpy.isStillOffered?(), false, "the menu bar collapses with the span")
        XCTAssertEqual(dismissedRows().last?["reason"] as? String, "span_lapsed")

        controller.handleScanReadings([teams.bundleID: fullSignature])
        controller.handleMeetingStarted(source: teams)
        XCTAssertEqual(host.promptSpy.presentCount, 2, "the second call gets its own prompt")
    }

    /// Acceptance (b), the explicit-skip half: a full-signature sighting after a both-absent poll
    /// gets a prompt, where the bundle-keyed latch used to swallow it.
    func test_anExplicitSkip_holdsForItsSpan_andTheNextCallPrompts() {
        let (controller, host) = makeController()
        controller.handleMeetingStarted(source: teams)
        controller.resolvePromptPick(.skip, source: teams)
        XCTAssertTrue(host.stateMachine.isSkipLatched(bundleID: teams.bundleID))
        XCTAssertEqual(host.statusBarSpy.suppressedSources, [teams])

        controller.handleScanReadings([teams.bundleID: micLive])
        controller.handleMeetingStarted(source: teams)
        XCTAssertEqual(host.promptSpy.presentCount, 1, "the skipped call stays skipped")

        controller.handleScanReadings([teams.bundleID: bothAbsent])
        controller.handleScanReadings([teams.bundleID: bothAbsent])
        controller.handleScanReadings([teams.bundleID: fullSignature])
        controller.handleMeetingStarted(source: teams)
        XCTAssertEqual(host.promptSpy.presentCount, 2)
    }

    // MARK: - Item 4: a weak starting-phase end does not withdraw the panel

    /// Acceptance (c).
    func test_aWeakEnd_keepsThePanel_andAnAppQuitWithdrawsIt() {
        let (controller, host) = makeController()
        controller.handleMeetingStarted(source: teams)

        controller.handleMeetingEnded(
            bundleID: teams.bundleID,
            reason: EndingReason(leadingSignal: PrimarySignalKind.shareableContentWindow.rawValue)
        )
        XCTAssertEqual(host.stateMachine.current, .prompting(source: teams), "no prompting -> idle")
        XCTAssertEqual(host.promptSpy.dismissCount, 0)
        XCTAssertEqual(host.promptSpy.mayHaveEndedCount, 1)

        controller.handleMeetingEnded(
            bundleID: teams.bundleID,
            reason: EndingReason(leadingSignal: PrimarySignalKind.workspaceAppTerminated.rawValue)
        )
        XCTAssertEqual(host.stateMachine.current, .idle)
        XCTAssertEqual(host.promptSpy.dismissCount, 1)
        XCTAssertEqual(dismissedRows().last?["reason"] as? String, "withdrawn_definitive")
    }

    /// Acceptance (d): a withdraw while the call may still be on screen backs off instead of
    /// re-raising on the immediate refresh.
    func test_aWithdrawOnMicRelease_isNotReRaisedByTheNextRefresh() {
        let (controller, host) = makeController()
        controller.handleMeetingStarted(source: teams)
        host.liveCallSignal = .callIsDown

        controller.handleMeetingEnded(
            bundleID: teams.bundleID,
            reason: EndingReason(leadingSignal: PrimarySignalKind.shareableContentWindow.rawValue)
        )
        XCTAssertEqual(host.stateMachine.current, .idle)
        XCTAssertEqual(dismissedRows().last?["reason"] as? String, "withdrawn_mic_released")

        controller.handleMeetingStarted(source: teams)
        controller.handleDiscovery(teams)
        XCTAssertEqual(host.promptSpy.presentCount, 1, "the withdraw backs off for one idle poll")

        controller.promptBackoff = (bundleID: teams.bundleID, until: Date().addingTimeInterval(-1))
        controller.handleMeetingStarted(source: teams)
        XCTAssertEqual(host.promptSpy.presentCount, 2, "and prompts again once the backoff is spent")
    }

    // MARK: - Item 5: a pick after the panel left acts on the held source

    /// Acceptance (e).
    func test_aMenuPickAfterTheTimeout_actsOnTheHeldSource() async {
        let (controller, host) = makeController()
        await promptThenTimeOut(controller, host)

        XCTAssertTrue(controller.resolvePromptPick(.record, source: teams))
        await waitUntil({ { if case .recording = host.stateMachine.current { return true }; return false }() }, "the attached recording")
        XCTAssertEqual(host.statusBarSpy.recordings.last?.source, teams)
    }

    func test_aSkipPickAfterTheTimeout_turnsTheOfferIntoASkip() async {
        let (controller, host) = makeController()
        await promptThenTimeOut(controller, host)

        XCTAssertTrue(controller.resolvePromptPick(.skip, source: teams))
        XCTAssertTrue(host.stateMachine.isSkipLatched(bundleID: teams.bundleID))
        XCTAssertEqual(host.statusBarSpy.suppressedSources, [teams])
    }

    func test_aPickWithNothingToActOn_isRefused() {
        let (controller, host) = makeController()
        XCTAssertFalse(controller.resolvePromptPick(.record, source: teams))
        XCTAssertEqual(host.recorderSpy.startCallCount, 0)
    }

    func test_hoverPausesAndResumesThePromptTimeout() {
        let (controller, host) = makeController()
        controller.handleMeetingStarted(source: teams)
        controller.setPromptTimeoutPaused(true)
        XCTAssertTrue(host.stateMachine.isPromptTimeoutPaused)
        controller.setPromptTimeoutPaused(false)
        XCTAssertFalse(host.stateMachine.isPromptTimeoutPaused)
    }

    // MARK: - Item 6: why a prompt left the screen

    func test_everyExitLogsItsReasonAndPointerState() async {
        let (controller, host) = makeController()

        controller.handleMeetingStarted(source: teams)
        host.promptSpy.isPointerOver = true
        controller.resolvePromptPick(.skip, source: teams)
        host.promptSpy.isPointerOver = false
        host.stateMachine.clearSuppression(bundleID: teams.bundleID)

        await promptThenTimeOut(controller, host)
        host.stateMachine.clearSuppression(bundleID: teams.bundleID)
        host.livePromptTimeoutSec = 30

        controller.handleMeetingStarted(source: teams)
        controller.forceStop(reason: "hotkey")

        host.stateMachine.clearSuppression(bundleID: teams.bundleID)
        host.recorderSpy.fileToReturn = tempDir.appendingPathComponent("20261116-100000.wav")
        controller.handleMeetingStarted(source: teams)
        controller.resolvePromptPick(.record, source: teams)
        await waitUntil({ { if case .recording = host.stateMachine.current { return true }; return false }() }, "the accepted recording")

        let rows = dismissedRows()
        XCTAssertEqual(rows.map { $0["reason"] as? String }, ["skipped", "timed_out_to_offer", "skipped", "accepted"])
        XCTAssertEqual(rows.first?["pointer_over"] as? Bool, true)
        XCTAssertEqual(rows.dropFirst().first?["pointer_over"] as? Bool, false)
        XCTAssertTrue(rows.allSatisfy { $0["bundle_id"] as? String == teams.bundleID })
        XCTAssertEqual(rows[2]["route"] as? String, "hotkey")
    }
}
