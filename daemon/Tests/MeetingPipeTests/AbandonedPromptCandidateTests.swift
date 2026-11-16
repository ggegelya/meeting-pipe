import XCTest
@testable import MeetingPipe
@testable import MeetingPipeCore

/// DET13's 2026-11-13 amendment (D098): a hand start seconds after a prompt leaves the screen
/// attaches to the prompt's call. Of the 4 source-less recordings on the work laptop, 3 began
/// within 10.4 s of a prompt disappearing; 20261021-103054 started 10 s after a Skip and ran 315 s
/// past the last speech, because nothing had written the candidate slot yet.
@MainActor
final class AbandonedPromptCandidateTests: XCTestCase {

    private var tempDir: URL!
    private var logs: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("det13-\(UUID().uuidString)", isDirectory: true)
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

    private func makeController() -> (MeetingSessionController, FakeSessionHost) {
        let host = FakeSessionHost(tempDir: tempDir)
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

    /// The attached start, with the lifecycle engaged for it, and no source-less fallback.
    private func assertAttached(_ host: FakeSessionHost, file: StaticString = #filePath, line: UInt = #line) async {
        // The engage lands with the record start's AX build, bounded by its deadline.
        await waitUntil({ !rows("lifecycle_engage_explicit_start").isEmpty }, "the explicit-start engage", file: file, line: line)
        XCTAssertEqual(host.statusBarSpy.recordings.last?.source, teams, file: file, line: line)
        XCTAssertEqual(rows("record_attached").last?["bundle_id"] as? String, teams.bundleID, file: file, line: line)
        XCTAssertEqual(
            rows("lifecycle_engage_explicit_start").last?["bundle_id"] as? String, teams.bundleID,
            "the attached start engages end detection", file: file, line: line
        )
    }

    func test_aHandStartJustAfterASkip_attachesToTheSkippedCall() async {
        let (controller, host) = makeController()
        controller.handleMeetingStarted(source: teams)
        controller.resolvePromptPick(.skip, source: teams)
        // No discovery sighting in between: the slot is seeded by the skip itself.
        controller.startManual(summaryMode: .auto, trigger: "manual")
        await waitUntil({ isRecording(host) }, "the hand start")
        await assertAttached(host)
    }

    func test_aHandStartJustAfterATimeout_attachesToTheOfferedCall() async {
        let (controller, host) = makeController()
        host.livePromptTimeoutSec = 0.01
        controller.handleMeetingStarted(source: teams)
        await waitUntil({ host.stateMachine.current == .idle }, "the timeout")
        controller.startManual(summaryMode: .auto, trigger: "manual")
        await waitUntil({ isRecording(host) }, "the hand start")
        await assertAttached(host)
    }

    func test_aHandStartJustAfterAForceStopWhilePrompting_attaches() async {
        let (controller, host) = makeController()
        controller.handleMeetingStarted(source: teams)
        controller.forceStop(reason: "hotkey")
        controller.startManual(summaryMode: .auto, trigger: "manual")
        await waitUntil({ isRecording(host) }, "the hand start")
        await assertAttached(host)
    }

    /// DET14's rule: a prompt withdrawn because the meeting ended leaves nothing to attach to.
    func test_aHandStartAfterAPromptWithdrawnByAnEnd_staysSourceless() async {
        let (controller, host) = makeController()
        controller.handleMeetingStarted(source: teams)
        controller.handleMeetingEnded(
            bundleID: teams.bundleID,
            reason: EndingReason(leadingSignal: PrimarySignalKind.workspaceAppTerminated.rawValue)
        )
        XCTAssertEqual(host.stateMachine.current, .idle)
        controller.startManual(summaryMode: .auto, trigger: "manual")
        await waitUntil({ isRecording(host) }, "the hand start")
        XCTAssertNil(host.statusBarSpy.recordings.last?.source)
        XCTAssertTrue(rows("record_attached").isEmpty)
    }
}
