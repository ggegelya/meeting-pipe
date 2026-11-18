import XCTest
@testable import MeetingPipe
@testable import MeetingPipeCore

/// UX106: the Record click is answered before the recorder is up, a start that fails takes the
/// Starting state back down, and a press that meets a start or a stop in flight says why it did
/// nothing.
@MainActor
final class StartingStateUX106Tests: XCTestCase {

    private var tempDir: URL!
    private var logs: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ux106-\(UUID().uuidString)", isDirectory: true)
        logs = tempDir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        setenv("MEETINGPIPE_LOGS_DIR", logs.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("MEETINGPIPE_LOGS_DIR")
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private let zoom = AppSource(bundleID: "us.zoom.xos", displayName: "Zoom")

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

    private func isRecording(_ host: FakeSessionHost) -> Bool {
        if case .recording = host.stateMachine.current { return true }
        return false
    }

    /// Fence A: with a start that never resolves, the Starting state is already up when
    /// `beginRecording` returns, and nothing reads as recording.
    func test_starting_is_shown_before_the_recorder_answers() async {
        let host = FakeSessionHost(tempDir: tempDir)
        host.recorderSpy.startBehaviour = .hang
        let controller = MeetingSessionController(coordinator: host)
        controller.beginRecording(source: zoom, summaryMode: .auto)

        XCTAssertEqual(host.statusBarSpy.startingSources.count, 1)
        XCTAssertEqual(host.statusBarSpy.startingSources.first??.bundleID, zoom.bundleID)
        XCTAssertEqual(host.hudSpy.startingPresentCount, 1)
        XCTAssertTrue(host.statusBarSpy.recordings.isEmpty)
        XCTAssertEqual(host.hudSpy.presentCount, 0)

        host.recorderSpy.releaseHang()
        await waitUntil({ host.statusBarSpy.idleCount > 0 }, "the hung start to resolve")
    }

    func test_a_start_that_succeeds_promotes_starting_to_recording_on_one_panel() async {
        let host = FakeSessionHost(tempDir: tempDir)
        let controller = MeetingSessionController(coordinator: host)
        controller.beginRecording(source: zoom, summaryMode: .auto)
        await waitUntil({ isRecording(host) }, "the recording")
        XCTAssertEqual(host.hudSpy.startingPresentCount, 1)
        XCTAssertEqual(host.hudSpy.presentCount, 1)
        XCTAssertEqual(host.hudSpy.dismissCount, 0, "promoted in place, never taken down between")
        XCTAssertEqual(host.statusBarSpy.recordings.count, 1)
        controller.forceStop(reason: "hotkey")
        await waitUntil({ host.stateMachine.current == .idle }, "the stop")
    }

    func test_a_start_that_throws_takes_starting_down_before_the_error() async {
        let host = FakeSessionHost(tempDir: tempDir)
        host.recorderSpy.startBehaviour = .fail(MeetingRecorder.RecorderError.engineStartFailed("boom"))
        let controller = MeetingSessionController(coordinator: host)
        controller.beginRecording(source: nil, summaryMode: .auto)
        await waitUntil({ !host.notifierSpy.errors.isEmpty }, "the error")
        XCTAssertEqual(host.hudSpy.startingPresentCount, 1)
        XCTAssertEqual(host.hudSpy.dismissCount, 1, "the Starting HUD is dismissed")
        XCTAssertEqual(host.statusBarSpy.idleCount, 1)
        XCTAssertEqual(host.hudSpy.presentCount, 0)
    }

    /// Item 2, through END20's latch: the HUD's Stop during Starting is the toggle, which cancels the
    /// start, and the fresh recording is stopped as soon as it commits. Never a running recording.
    func test_a_stop_during_starting_never_leaves_a_recording_running() async {
        let host = FakeSessionHost(tempDir: tempDir)
        host.recorderSpy.startBehaviour = .park
        let controller = MeetingSessionController(coordinator: host)
        controller.beginRecording(source: nil, summaryMode: .auto)
        await waitUntil({ host.recorderSpy.startCallCount == 1 }, "the start")
        controller.toggleManual(surface: .hud)
        host.recorderSpy.releasePark()
        await waitUntil({ host.recorderSpy.stopCallCount == 1 }, "the fresh recording to stop")
        await waitUntil({ host.stateMachine.current == .idle }, "the flush")
        XCTAssertTrue(host.statusBarSpy.recordings.isEmpty)
    }

    func test_a_press_during_a_start_or_a_stop_says_why_it_did_nothing() async {
        let host = FakeSessionHost(tempDir: tempDir)
        host.recorderSpy.startBehaviour = .park
        let controller = MeetingSessionController(coordinator: host)
        controller.beginRecording(source: nil, summaryMode: .auto)
        await waitUntil({ host.recorderSpy.startCallCount == 1 }, "the start")
        controller.beginRecording(source: zoom, summaryMode: .auto)
        XCTAssertEqual(rows("record_press_ignored").first?["state"] as? String, "starting")
        XCTAssertEqual(host.statusBarSpy.flashes, ["Already starting"])
        host.recorderSpy.releasePark()
        await waitUntil({ isRecording(host) }, "the recording")

        host.recorderSpy.stopBehaviourHangs = true
        controller.toggleManual(surface: .menu)
        await waitUntil({ if case .stopping = host.stateMachine.current { return true }; return false }, "the stop")
        controller.toggleManual(surface: .hotkey)
        let stopping = rows("record_press_ignored").last
        XCTAssertEqual(stopping?["state"] as? String, "stopping")
        XCTAssertEqual(stopping?["trigger"] as? String, "hotkey")
        XCTAssertEqual(host.statusBarSpy.flashes.last, "Still saving the last recording")
        host.recorderSpy.stopBehaviourHangs = false
        await waitUntil({ host.stateMachine.current == .idle }, "the flush")
    }

    // MARK: - Presentation

    func test_record_and_skip_get_different_first_frames() {
        XCTAssertEqual(PromptChoice.look(for: .record), .starting)
        XCTAssertEqual(PromptChoice.look(for: .recordBYO), .starting)
        XCTAssertEqual(PromptChoice.look(for: .always), .starting)
        XCTAssertEqual(PromptChoice.look(for: .skip), .fadeOut)
        XCTAssertNotEqual(PromptChoice.look(for: .record), PromptChoice.look(for: .skip))
    }

    func test_the_hud_label_reads_starting_until_the_recording_commits() {
        XCTAssertEqual(HUDStateLabel.resolve(micCaptureLost: false, lowSpace: nil, offRecord: false, confirmingEnd: false, starting: true).text, "Starting…")
        XCTAssertEqual(HUDStateLabel.resolve(micCaptureLost: false, lowSpace: nil, offRecord: false, confirmingEnd: false).text, "Recording")
    }

    func test_the_status_item_reads_starting_and_offers_no_record_row() {
        let inputs = StatusBarModel.Inputs(state: .idle, startingRecording: true)
        XCTAssertEqual(StatusBarModel.title(inputs), " Starting…")
        XCTAssertEqual(StatusBarModel.headerLabel(inputs), "MeetingPipe: Starting…")
        let rows = StatusBarModel.rows(inputs)
        XCTAssertFalse(rows.contains(.startRecording))
        XCTAssertTrue(StatusBarModel.rows(StatusBarModel.Inputs(state: .idle)).contains(.startRecording))
    }
}
