import XCTest
@testable import MeetingPipe
@testable import MeetingPipeCore

/// DET14's 2026-11-13 amendment (D049): END13's stop-time retention re-added the candidate DET14's
/// end clear had just dropped, so the menu offered "Record this <app> meeting" for 24 s after every
/// lifecycle-ended recording. It is now skipped after a definitive end only. A weak-signal end keeps
/// it, because that is what the owner's 20261022-150025 rescue attached to.
@MainActor
final class StopCandidateRetentionTests: XCTestCase {

    private var tempDir: URL!
    private var logs: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("det14-\(UUID().uuidString)", isDirectory: true)
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

    private func rows(_ action: String) -> [[String: Any]] {
        let text = (try? String(contentsOf: logs.appendingPathComponent("events.jsonl"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }.filter { $0["action"] as? String == action }
    }

    /// A Teams recording ended by `reason`; returns the host to read the candidate from.
    private func recordingEnded(by reason: EndingReason) -> FakeSessionHost {
        let host = FakeSessionHost(tempDir: tempDir)
        let controller = MeetingSessionController(coordinator: host)
        host.stateMachine.setRecording(file: tempDir.appendingPathComponent("rec.wav"), source: teams, summaryMode: .auto)
        controller.handleMeetingEnded(bundleID: teams.bundleID, reason: reason)
        return host
    }

    func test_a_teardown_confirmed_end_leaves_no_candidate() {
        let host = recordingEnded(by: EndingReason(
            leadingSignal: "ax_leave_button_invalid", confirmedBy: [PromotionEngine.teardownEvidence]
        ))
        XCTAssertNil(host.stateMachine.liveSuppressedCandidate())
        XCTAssertTrue(rows("stopped_candidate_retained").isEmpty)
        XCTAssertEqual(rows("stopped_candidate_not_retained").first?["reason"] as? String, "definitive_end")
    }

    func test_an_app_quit_end_leaves_no_candidate() {
        let host = recordingEnded(by: EndingReason(leadingSignal: PrimarySignalKind.workspaceAppTerminated.rawValue))
        XCTAssertNil(host.stateMachine.liveSuppressedCandidate())
        XCTAssertTrue(rows("stopped_candidate_retained").isEmpty)
    }

    /// The 20261022-150025 shape: a weak-signal end the owner rescued by pressing Record 22.9 s on.
    func test_a_pair_dwell_end_still_retains_the_candidate_for_the_rescue() {
        let host = recordingEnded(by: EndingReason(
            leadingSignal: "ax_leave_button_invalid", confirmedBy: ["process_audio_is_running_input_false"]
        ))
        XCTAssertEqual(host.stateMachine.liveSuppressedCandidate(), teams)
        XCTAssertEqual(host.stateMachine.liveSuppressedCandidate(now: Date().addingTimeInterval(22.9)), teams)
        XCTAssertEqual(rows("stopped_candidate_retained").count, 1)
    }

    func test_a_lone_dwell_end_still_retains_the_candidate() {
        let host = recordingEnded(by: EndingReason(
            leadingSignal: "shareable_content_window_gone", confirmedBy: [PromotionEngine.loneDwellEvidence]
        ))
        XCTAssertEqual(host.stateMachine.liveSuppressedCandidate(), teams)
    }

    func test_a_user_stop_and_a_backstop_stop_still_retain_it() {
        for route in ["toggle", "idle_backstop"] {
            let host = FakeSessionHost(tempDir: tempDir)
            let controller = MeetingSessionController(coordinator: host)
            let file = tempDir.appendingPathComponent("\(route).wav")
            host.stateMachine.setRecording(file: file, source: teams, summaryMode: .auto)
            controller.stopRecording(file: file, source: teams, summaryMode: .auto, stopRoute: route)
            XCTAssertEqual(host.stateMachine.liveSuppressedCandidate(), teams, route)
        }
    }

    func test_the_definitive_rule_matches_end17() {
        let teams2 = teams.bundleID
        XCTAssertTrue(EndingReason(leadingSignal: "workspace_app_terminated").isDefinitive(forBundleID: teams2))
        XCTAssertTrue(EndingReason(leadingSignal: "shareable_content_window_gone", confirmedBy: ["workspace_app_terminated"]).isDefinitive(forBundleID: "us.zoom.xos"))
        XCTAssertTrue(EndingReason(leadingSignal: "ax_leave_button_invalid", confirmedBy: ["call_teardown_observed"]).isDefinitive(forBundleID: teams2))
        XCTAssertFalse(EndingReason(leadingSignal: "ax_leave_button_invalid", confirmedBy: ["lone_dwell"]).isDefinitive(forBundleID: teams2))
        XCTAssertFalse(EndingReason(leadingSignal: "process_audio_is_running_input_false").isDefinitive(forBundleID: teams2))
    }

    /// The review's catch: the host's teardown consult used to read Teams' log for any native hold,
    /// so a Teams call ending during a Zoom hold could confirm it. END16's gate now stops that at
    /// the consult; this pins the second check behind it: such an end is not a definitive Zoom end,
    /// and the candidate is what the owner would rescue the cut Zoom recording with.
    func test_a_teardown_confirm_of_a_non_teams_recording_still_retains_the_candidate() {
        let zoom = AppSource(bundleID: "us.zoom.xos", displayName: "Zoom")
        let host = FakeSessionHost(tempDir: tempDir)
        let controller = MeetingSessionController(coordinator: host)
        host.stateMachine.setRecording(file: tempDir.appendingPathComponent("zoom.wav"), source: zoom, summaryMode: .auto)
        controller.handleMeetingEnded(bundleID: zoom.bundleID, reason: EndingReason(
            leadingSignal: "ax_leave_button_invalid", confirmedBy: [PromotionEngine.teardownEvidence]
        ))
        XCTAssertEqual(host.stateMachine.liveSuppressedCandidate(), zoom)
    }
}
