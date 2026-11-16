import XCTest
@testable import MeetingPipe
@testable import MeetingPipeCore

/// SEC39: a workflow picked for one meeting no longer outranks the next meeting's rule match. The
/// chip pick is keyed to its prompt's source and cleared on every prompt exit (F005), and a resume
/// re-runs the matcher instead of pinning the previous recording's workflow (F046).
@MainActor
final class PromptRoutingTests: XCTestCase {

    private var tempDir: URL!
    private var logs: URL!
    private var hosts: [FakeSessionHost] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sec39-\(UUID().uuidString)", isDirectory: true)
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
    private let zoom = AppSource(bundleID: "us.zoom.xos", displayName: "Zoom")

    /// General (default), Client (picked on the chip), and Zoom Calls (Zoom's rule).
    private func workflows() -> (general: Workflow, client: Workflow, zoomCalls: Workflow) {
        let general = Workflow(name: "General", isDefault: true)
        let client = Workflow(name: "Client")
        var zoomCalls = Workflow(name: "Zoom Calls")
        zoomCalls.matchingRules = [WorkflowMatchingRule(bundleID: zoom.bundleID)]
        return (general, client, zoomCalls)
    }

    private func makeController(_ workflows: [Workflow]) -> (MeetingSessionController, FakeSessionHost) {
        let host = FakeSessionHost(tempDir: tempDir, workflows: workflows)
        host.recorderSpy.lastSystemFires = 1
        hosts.append(host)
        return (MeetingSessionController(coordinator: host), host)
    }

    private func waitUntil(_ predicate: () -> Bool, _ what: String, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if predicate() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 500_000)
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
    }

    private func isRecording(_ host: FakeSessionHost) -> Bool {
        if case .recording = host.stateMachine.current { return true }
        return false
    }

    private func rows(_ action: String) -> [[String: Any]] {
        let text = (try? String(contentsOf: logs.appendingPathComponent("events.jsonl"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }.filter { $0["action"] as? String == action }
    }

    /// A chip pick on a Teams prompt, then `exit`; then an auto-consented Zoom call records under
    /// Zoom's rule, not the stale pick.
    private func assertExitDiscardsThePick(_ exit: String, file: StaticString = #filePath, line: UInt = #line,
                                          _ leave: (MeetingSessionController, FakeSessionHost) async -> Void) async {
        let wf = workflows()
        let (controller, host) = makeController([wf.general, wf.client, wf.zoomCalls])
        controller.handleMeetingStarted(source: teams)
        controller.setPendingWorkflowOverride(wf.client.id)
        XCTAssertNotNil(controller.pendingWorkflowOverride, file: file, line: line)

        await leave(controller, host)
        XCTAssertNil(controller.pendingWorkflowOverride, "the \(exit) exit clears the pick", file: file, line: line)
        XCTAssertEqual(rows("override_discarded").last?["exit"] as? String, exit, file: file, line: line)

        host.stateMachine.clearSuppression(bundleID: zoom.bundleID)
        host.liveAutoConsentApps = [zoom.bundleID]
        controller.promptBackoff = nil
        controller.handleMeetingStarted(source: zoom)
        await waitUntil({ self.isRecording(host) }, "the auto-consented start", file: file, line: line)
        XCTAssertEqual(controller.activeWorkflow?.id, wf.zoomCalls.id, file: file, line: line)
    }

    func test_aSkip_discardsThePick() async {
        await assertExitDiscardsThePick("skip") { controller, _ in
            controller.resolvePromptPick(.skip, source: self.teams)
        }
    }

    func test_aTimeout_discardsThePick() async {
        await assertExitDiscardsThePick("timeout") { controller, host in
            host.livePromptTimeoutSec = 0.01
            controller.startPromptTimeout(for: self.teams)
            await self.waitUntil({ host.stateMachine.current == .idle }, "the timeout")
        }
    }

    func test_anEndDuringThePrompt_discardsThePick() async {
        await assertExitDiscardsThePick("ended") { controller, _ in
            controller.handleMeetingEnded(
                bundleID: self.teams.bundleID,
                reason: EndingReason(leadingSignal: PrimarySignalKind.workspaceAppTerminated.rawValue)
            )
        }
    }

    func test_aForceStop_discardsThePick() async {
        await assertExitDiscardsThePick("force_stop") { controller, _ in
            controller.forceStop(reason: "hotkey")
        }
    }

    /// A pick made on one prompt is not the next prompt's chip for another source.
    func test_aPickIsNotTheNextPromptsChip() {
        let wf = workflows()
        let (controller, _) = makeController([wf.general, wf.client, wf.zoomCalls])
        controller.handleMeetingStarted(source: teams)
        controller.setPendingWorkflowOverride(wf.client.id)
        XCTAssertEqual(controller.workflowForPrompt(source: teams)?.id, wf.client.id, "its own prompt shows it")
        XCTAssertEqual(controller.workflowForPrompt(source: zoom)?.id, wf.zoomCalls.id)
    }

    /// A manual start with no source never consumes a pick made for a prompt.
    func test_aManualStartAfterAnUnrecordedPick_resolvesTheDefault() async {
        let wf = workflows()
        let (controller, host) = makeController([wf.general, wf.client, wf.zoomCalls])
        controller.handleMeetingStarted(source: teams)
        controller.setPendingWorkflowOverride(wf.client.id)
        host.stateMachine.setIdle()
        controller.beginRecording(source: nil, summaryMode: .auto)
        await waitUntil({ self.isRecording(host) }, "the manual start")
        XCTAssertEqual(controller.activeWorkflow?.id, wf.general.id)
    }

    func test_aPickWithNoPromptUp_isIgnored() {
        let wf = workflows()
        let (controller, _) = makeController([wf.general, wf.client])
        controller.setPendingWorkflowOverride(wf.client.id)
        XCTAssertNil(controller.pendingWorkflowOverride)
    }

    func test_aPickFollowedByRecord_recordsUnderThePick() async {
        let wf = workflows()
        let (controller, host) = makeController([wf.general, wf.client, wf.zoomCalls])
        controller.handleMeetingStarted(source: zoom)
        controller.setPendingWorkflowOverride(wf.client.id)
        controller.resolvePromptPick(.record, source: zoom)
        await waitUntil({ self.isRecording(host) }, "the recording")
        XCTAssertEqual(controller.activeWorkflow?.id, wf.client.id)
    }

    // MARK: - Resume

    private func resume(_ controller: MeetingSessionController, _ host: FakeSessionHost, previous: Workflow?) async {
        controller.resumeCandidate = ResumeAfterEnd(
            bundleID: teams.bundleID, stem: "20261116-100000",
            endedAt: Date().addingTimeInterval(-30), endedUptime: ProcessInfo.processInfo.systemUptime + (-30), workflowID: previous?.id, summaryMode: .auto
        )
        host.recorderSpy.fileToReturn = tempDir.appendingPathComponent("20261116-100100.wav")
        controller.handleMeetingStarted(source: teams)
        await waitUntil({ self.isRecording(host) }, "the resumed recording")
    }

    func test_aResumeWhoseCallMatchesAnNDARule_recordsUnderIt_behindTheGate() async {
        let general = Workflow(name: "General", isDefault: true)
        var nda = Workflow(name: "Client NDA")
        nda.flags.ndaMode = true
        nda.matchingRules = [WorkflowMatchingRule(bundleID: teams.bundleID)]
        let (controller, host) = makeController([general, nda])
        await resume(controller, host, previous: general)

        XCTAssertEqual(controller.activeWorkflow?.id, nda.id)
        XCTAssertEqual(controller.activeCaptureMode, .regulatedGate)
        XCTAssertEqual(rows("recording_resumed_after_end").last?["workflow_source"] as? String, "rule")
        XCTAssertEqual(rows("recording_resumed_after_end").last?["workflow_changed"] as? Bool, true)
        let meta = MeetingMetaSidecar.build(source: teams, workflow: controller.activeWorkflow)
        XCTAssertEqual(meta["workflow_nda_mode"] as? Bool, true)
    }

    func test_aResumeWithNoRuleMatch_keepsThePreviousWorkflow() async {
        let general = Workflow(name: "General", isDefault: true)
        let client = Workflow(name: "Client")
        let (controller, host) = makeController([general, client])
        await resume(controller, host, previous: client)
        XCTAssertEqual(controller.activeWorkflow?.id, client.id)
        XCTAssertEqual(rows("recording_resumed_after_end").last?["workflow_source"] as? String, "previous")
        XCTAssertEqual(rows("recording_resumed_after_end").last?["workflow_changed"] as? Bool, false)
    }

    func test_aResumeAfterAnNDARecording_keepsNDA() async {
        let general = Workflow(name: "General", isDefault: true)
        var nda = Workflow(name: "Client NDA")
        nda.flags.ndaMode = true
        let (controller, host) = makeController([general, nda])
        await resume(controller, host, previous: nda)
        XCTAssertEqual(controller.activeWorkflow?.id, nda.id)
        XCTAssertEqual(controller.activeCaptureMode, .regulatedGate)
    }

    func test_theResumeRoutingTable() {
        let general = Workflow(name: "General", isDefault: true)
        var ndaDefault = Workflow(name: "NDA default", isDefault: true)
        ndaDefault.flags.ndaMode = true
        let client = Workflow(name: "Client")
        typealias M = WorkflowMatcher
        XCTAssertEqual(M.resumeWorkflow(matched: client, reason: .matched(score: 2), previous: general).source, "rule")
        XCTAssertEqual(M.resumeWorkflow(matched: general, reason: .fallback, previous: client).source, "previous")
        XCTAssertEqual(M.resumeWorkflow(matched: ndaDefault, reason: .fallback, previous: client).source, "nda_floor")
        XCTAssertEqual(M.resumeWorkflow(matched: general, reason: .fallback, previous: nil).source, "default")
    }
}
