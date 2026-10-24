import XCTest
@testable import MeetingPipe
@testable import MeetingPipeCore

/// END17 at the session spine: what a concluded hold does at stop (keep the tail and suggest the
/// cut, or cut it under regulated and NDA), and the way back from an end the same call outlives.
@MainActor
final class HeldEndSessionTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("end17-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private let teams = AppSource(bundleID: "com.microsoft.teams2", displayName: "Microsoft Teams")
    private let context = MeetingLifecycleContext(bundleID: "com.microsoft.teams2", kind: .native, pid: 635)

    private func makeController(workflows: [Workflow] = []) -> (MeetingSessionController, FakeSessionHost) {
        let host = FakeSessionHost(tempDir: tempDir, workflows: workflows)
        // The remote side was captured, so the stop path takes no coverage-warning branch.
        host.recorderSpy.lastSystemFires = 1
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

    private func meta(for file: URL) throws -> [String: Any] {
        let url = file.deletingPathExtension().appendingPathExtension("meta.json")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Record, open a hold ten minutes in, conclude it a lone dwell later, and stop: the shape of a
    /// weak-only leave confirmed by the engine.
    private func recordAndStopAfterAHeldEnd(
        _ controller: MeetingSessionController,
        _ host: FakeSessionHost,
        file: URL
    ) async {
        host.recorderSpy.fileToReturn = file
        controller.beginRecording(source: teams, summaryMode: .auto)
        await waitUntil({ host.stateMachine.current.isRecording }, "the meeting to record")
        host.recorderSpy.startedAt = Date().addingTimeInterval(-600)
        controller.beginTeardownHold(context: context)
        let openedAt = controller.teardownHold?.startedAt ?? Date()
        controller.concludeTeardownHold(now: openedAt.addingTimeInterval(PromotionEngine.defaultLoneDwell))
        controller.stopRecording(file: file, source: teams, summaryMode: .auto)
        await waitUntil({ host.stateMachine.current == .idle }, "the flush to finish")
    }

    // MARK: - Keep, then trim

    func test_a_lossless_capture_keeps_the_held_tail_and_suggests_the_trim() async throws {
        let (controller, host) = makeController()
        let file = tempDir.appendingPathComponent("20261024-100000.wav")

        await recordAndStopAfterAHeldEnd(controller, host, file: file)

        XCTAssertEqual(host.recorderSpy.lastStopLimitSeconds, .some(nil), "the WAV keeps the tail")
        let trim = try XCTUnwrap(meta(for: file)[HeldEndTrim.metaKey] as? Double)
        XCTAssertEqual(trim, 600, accuracy: 1, "the trim point is where the hold opened")
    }

    /// Under NDA (and regulated) ADR 0016 says post-call audio must not exist at rest, so the cut
    /// happens at stop exactly as before END17, and no suggestion is written.
    func test_an_nda_workflow_truncates_at_stop_as_before() async throws {
        var nda = Workflow(name: "Client NDA")
        nda.flags.ndaMode = true
        let (controller, host) = makeController(workflows: [nda])
        controller.pendingWorkflowOverride = nda.id
        let file = tempDir.appendingPathComponent("20261024-110000.wav")

        await recordAndStopAfterAHeldEnd(controller, host, file: file)

        let limit = try XCTUnwrap(host.recorderSpy.lastStopLimitSeconds ?? nil, "the tail is cut at stop")
        XCTAssertEqual(limit, 600, accuracy: 1)
        XCTAssertNil(try meta(for: file)[HeldEndTrim.metaKey])
    }

    /// A user Stop is definitive: with no hold concluded there is nothing to trim.
    func test_an_ordinary_stop_neither_cuts_nor_suggests() async throws {
        let (controller, host) = makeController()
        let file = tempDir.appendingPathComponent("20261024-120000.wav")
        host.recorderSpy.fileToReturn = file
        controller.beginRecording(source: teams, summaryMode: .auto)
        await waitUntil({ host.stateMachine.current.isRecording }, "the meeting to record")
        controller.stopRecording(file: file, source: teams, summaryMode: .auto)
        await waitUntil({ host.stateMachine.current == .idle }, "the flush to finish")

        XCTAssertEqual(host.recorderSpy.lastStopLimitSeconds, .some(nil))
        XCTAssertNil(try meta(for: file)[HeldEndTrim.metaKey])
    }

    // MARK: - Recovery

    /// PD-9. An end the same call outlives: inside the window the reprompt cooldown is bypassed, the
    /// recording resumes without a prompt, and the new stem names the one the end stopped.
    func test_a_call_back_inside_the_window_resumes_without_a_prompt_and_links_the_stems() async throws {
        let (controller, host) = makeController()
        let first = tempDir.appendingPathComponent("20261024-130000.wav")
        host.recorderSpy.fileToReturn = first
        controller.beginRecording(source: teams, summaryMode: .auto)
        await waitUntil({ host.stateMachine.current.isRecording }, "the meeting to record")

        controller.handleMeetingEnded(
            bundleID: teams.bundleID,
            reason: EndingReason(leadingSignal: "browser_tab_title_left_meet_pattern", confirmedBy: ["lone_dwell"])
        )
        await waitUntil({ host.stateMachine.current == .idle }, "the flush to finish")
        XCTAssertTrue(
            host.stateMachine.isCoolingDown(bundleID: teams.bundleID, cooldownSec: host.liveRepromptCooldownSec),
            "the cooldown is armed, which is what used to suppress the way back"
        )

        let second = tempDir.appendingPathComponent("20261024-130130.wav")
        host.recorderSpy.fileToReturn = second
        controller.handleMeetingStarted(source: teams)
        await waitUntil({ host.stateMachine.current.isRecording }, "the resumed recording")

        XCTAssertEqual(host.promptSpy.presentCount, 0, "a resume is not a prompt")
        XCTAssertNil(controller.resumeCandidate, "the way back is used once")
        controller.stopRecording(file: second, source: teams, summaryMode: .auto)
        await waitUntil({ host.stateMachine.current == .idle }, "the second flush")
        XCTAssertEqual(try meta(for: second)[ResumeAfterEnd.metaKey] as? String, "20261024-130000")
    }

    /// Outside the window the cooldown applies as it always did.
    func test_a_call_back_after_the_window_does_not_resume() async {
        let (controller, host) = makeController()
        host.stateMachine.recordCooldownEnd(bundleID: teams.bundleID)
        controller.resumeCandidate = ResumeAfterEnd(
            bundleID: teams.bundleID,
            stem: "20261024-130000",
            endedAt: Date().addingTimeInterval(-(ResumeAfterEnd.windowSec + 1)),
            workflowID: nil,
            summaryMode: .auto
        )

        controller.handleMeetingStarted(source: teams)
        await Task.yield()

        XCTAssertFalse(host.stateMachine.current.isRecording)
        XCTAssertEqual(host.recorderSpy.startCallCount, 0)
    }

    /// A different app's call inside the window is its own meeting.
    func test_another_apps_call_inside_the_window_does_not_resume() {
        let candidate = ResumeAfterEnd(
            bundleID: teams.bundleID, stem: "s", endedAt: Date(), workflowID: nil, summaryMode: .auto
        )
        XCTAssertTrue(candidate.applies(to: teams.bundleID, at: Date()))
        XCTAssertFalse(candidate.applies(to: "us.zoom.xos", at: Date()))
        XCTAssertFalse(candidate.applies(to: teams.bundleID, at: Date().addingTimeInterval(ResumeAfterEnd.windowSec + 1)))
    }
}

private extension AppState {
    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }
}
