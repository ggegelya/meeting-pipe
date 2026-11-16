import XCTest
@testable import MeetingPipe
@testable import MeetingPipeCore

/// END22 at the session layer: a sleep neither closes nor spends the resume window and the
/// reprompt cooldown (both on `systemUptime` now), and an overnight lid-close does not turn the next
/// morning's call into a resume. The idle backstop's side is `IdleStopBackstopTests`.
@MainActor
final class SleepWakeSessionTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("end22-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private let teams = AppSource(bundleID: "com.microsoft.teams2", displayName: "Microsoft Teams")

    private func waitUntil(_ predicate: () -> Bool, _ what: String, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if predicate() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
    }

    /// The spec's acceptance: an end, a 200 s sleep, then the same app's call; it still resumes.
    func test_a_call_back_after_a_200s_sleep_still_resumes() async throws {
        let host = FakeSessionHost(tempDir: tempDir)
        host.recorderSpy.lastSystemFires = 1
        let controller = MeetingSessionController(coordinator: host)
        var uptime: TimeInterval = 5000
        controller.sessionUptime = { uptime }
        host.recorderSpy.fileToReturn = tempDir.appendingPathComponent("20261117-090000.wav")
        controller.beginRecording(source: teams, summaryMode: .auto)
        await waitUntil({ { if case .recording = host.stateMachine.current { return true }; return false }() }, "the recording")
        controller.handleMeetingEnded(
            bundleID: teams.bundleID,
            reason: EndingReason(leadingSignal: "ax_leave_button_invalid", confirmedBy: ["lone_dwell"])
        )
        await waitUntil({ host.stateMachine.current == .idle }, "the flush")
        let candidate = try XCTUnwrap(controller.resumeCandidate)
        // 200 s of wall time asleep, 5 s of it awake.
        controller.resumeCandidate = ResumeAfterEnd(
            bundleID: candidate.bundleID, stem: candidate.stem,
            endedAt: candidate.endedAt.addingTimeInterval(-200), endedUptime: candidate.endedUptime,
            workflowID: candidate.workflowID, summaryMode: candidate.summaryMode
        )
        uptime += 5

        host.recorderSpy.fileToReturn = tempDir.appendingPathComponent("20261117-090400.wav")
        controller.handleMeetingStarted(source: teams)
        await waitUntil({ { if case .recording = host.stateMachine.current { return true }; return false }() }, "the resumed recording")
        XCTAssertEqual(host.promptSpy.presentCount, 0, "a resume, not a prompt")
        XCTAssertNil(controller.resumeCandidate)
    }

    func test_the_resume_window_counts_awake_time_and_is_capped_on_the_wall() {
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        let candidate = ResumeAfterEnd(
            bundleID: teams.bundleID, stem: "s", endedAt: end, endedUptime: 1000, workflowID: nil, summaryMode: .auto
        )
        XCTAssertTrue(candidate.applies(to: teams.bundleID, at: end.addingTimeInterval(300), uptime: 1010), "a 5 min lid-close")
        XCTAssertFalse(candidate.applies(to: teams.bundleID, at: end.addingTimeInterval(130), uptime: 1130), "120 s awake spent")
        XCTAssertFalse(
            candidate.applies(to: teams.bundleID, at: end.addingTimeInterval(9 * 3600), uptime: 1010),
            "an overnight sleep: the morning's call is not yesterday's"
        )
    }

    func test_a_sleep_does_not_spend_the_reprompt_cooldown() {
        var uptime: TimeInterval = 0
        let machine = DetectionStateMachine(uptime: { uptime })
        machine.recordCooldownEnd(bundleID: teams.bundleID)
        uptime += 10 // an hour asleep moves the wall clock, not this one
        XCTAssertTrue(machine.isCoolingDown(bundleID: teams.bundleID, cooldownSec: 60))
        uptime += 60
        XCTAssertFalse(machine.isCoolingDown(bundleID: teams.bundleID, cooldownSec: 60))
    }
}
