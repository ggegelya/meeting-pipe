import AppKit
import XCTest
@testable import MeetingPipe

/// MIC17: the quiet-mic tier. A mic that carried something but almost never reached a speech level
/// over a long un-muted span, under a live far side, warns; the dead tier still wins, and the
/// thresholds are the provisional ones `scripts/mic_level_probe.py` checked on the home Mac.
final class MicVeryQuietMIC17Tests: XCTestCase {

    private func evaluate(
        seconds: Double = 2116, system: Bool = true, unmuted: Double = 2114,
        peak: Float = -26.5, loud: Double = 1.7
    ) -> MicCoverageWarning {
        MicCoverageWarning.evaluate(
            recordingSeconds: seconds, systemAudioPresentWholeCall: system,
            unmutedSeconds: unmuted, peakUnmutedRmsDb: peak, loudUnmutedSeconds: loud
        )
    }

    // MARK: - The stop-time tier

    /// The 2026-10-16 built-in-mic call, by the probe's numbers.
    func test_fires_on_a_long_unmuted_span_with_almost_no_loud_seconds() {
        XCTAssertEqual(evaluate(), .micVeryQuiet)
    }

    func test_the_dead_tier_wins() {
        XCTAssertEqual(evaluate(peak: -74.9, loud: 0), .micRecordedNothing)
    }

    func test_not_under_the_unmuted_floor() {
        XCTAssertEqual(evaluate(unmuted: 299.9, loud: 0), .none)
    }

    func test_not_without_the_far_side() {
        XCTAssertEqual(evaluate(system: false), .none)
    }

    func test_not_for_a_short_recording() {
        XCTAssertEqual(evaluate(seconds: 59, unmuted: 59), .none)
    }

    func test_the_boundaries() {
        XCTAssertEqual(evaluate(unmuted: 300, loud: 4.99), .micVeryQuiet, "the floor is inclusive")
        XCTAssertEqual(evaluate(unmuted: 300, loud: 5), .none, "five loud seconds is enough speech")
    }

    /// The September AirPods calls do not fire.
    func test_not_on_a_mic_that_carried_speech() {
        XCTAssertEqual(evaluate(seconds: 476, unmuted: 475, peak: -9.7, loud: 185), .none)
        XCTAssertEqual(evaluate(seconds: 1219, unmuted: 67.9, peak: -9.7, loud: 11.4), .none)
    }

    /// D053's shape: a dead in-call stretch, then a few loud seconds in the teardown. The single
    /// whole-file peak passes it; the loud-seconds count does not.
    func test_a_dead_stretch_followed_by_a_few_loud_seconds_fires() {
        XCTAssertEqual(evaluate(seconds: 1810, unmuted: 1800, peak: -12, loud: 4), .micVeryQuiet)
    }

    /// A snapshot with no loud-seconds measurement (the pre-MIC17 default) never reads as quiet.
    func test_an_unmeasured_snapshot_is_never_quiet() {
        XCTAssertEqual(
            MicCoverageWarning.evaluate(
                recordingSeconds: 2000, systemAudioPresentWholeCall: true,
                unmutedSeconds: 2000, peakUnmutedRmsDb: -30
            ),
            .none
        )
    }

    // MARK: - The tally

    func test_the_tally_counts_loud_unmuted_seconds_only() {
        var tally = MicCoverageTally()
        let buf = 4096.0 / 48_000
        for _ in 0..<100 { tally.add(rmsDb: -55, seconds: buf, muted: false) }   // quiet speech
        for _ in 0..<10 { tally.add(rmsDb: -39.9, seconds: buf, muted: false) }  // loud
        for _ in 0..<10 { tally.add(rmsDb: -40, seconds: buf, muted: false) }    // at the bar counts
        for _ in 0..<50 { tally.add(rmsDb: -10, seconds: buf, muted: true) }     // muted, never counts
        let snap = tally.snapshot
        XCTAssertEqual(snap.recordingSeconds, 170 * buf, accuracy: 1e-9)
        XCTAssertEqual(snap.unmutedSeconds, 120 * buf, accuracy: 1e-9)
        XCTAssertEqual(snap.loudUnmutedSeconds, 20 * buf, accuracy: 1e-9)
        XCTAssertEqual(snap.peakUnmutedRmsDb, -39.9, accuracy: 1e-6)
    }

    // MARK: - The live check

    private func coverage(unmuted: Double, loud: Double) -> MicCoverageSnapshot {
        MicCoverageSnapshot(recordingSeconds: unmuted, unmutedSeconds: unmuted, peakUnmutedRmsDb: -30, loudUnmutedSeconds: loud)
    }

    func test_the_live_check_fires_once_at_the_floor() {
        var check = MicQuietLiveCheck()
        XCTAssertFalse(check.shouldNotify(coverage: coverage(unmuted: 270, loud: 0), systemLive: true), "before the floor")
        XCTAssertFalse(check.shouldNotify(coverage: coverage(unmuted: 300, loud: 1), systemLive: false), "no far side")
        XCTAssertTrue(check.shouldNotify(coverage: coverage(unmuted: 300, loud: 1), systemLive: true))
        XCTAssertFalse(check.shouldNotify(coverage: coverage(unmuted: 330, loud: 1), systemLive: true), "once per recording")
    }

    func test_the_live_check_stays_quiet_once_the_owner_is_audible() {
        var check = MicQuietLiveCheck()
        XCTAssertFalse(check.shouldNotify(coverage: coverage(unmuted: 600, loud: 40), systemLive: true))
    }

    // MARK: - The HUD state

    func test_the_quiet_state_ranks_below_the_losses_and_above_the_deliberate_states() {
        typealias L = HUDStateLabel
        XCTAssertEqual(L.resolve(micCaptureLost: false, lowSpace: nil, writerBehind: true, micVeryQuiet: true, offRecord: false, confirmingEnd: false).text, L.writerBehindText)
        let alone = L.resolve(micCaptureLost: false, lowSpace: nil, micVeryQuiet: true, offRecord: true, confirmingEnd: true)
        XCTAssertEqual(alone.text, MicCoverageCopy.hudLabel)
        XCTAssertEqual(alone.tone, .alert)
    }

    func test_the_quiet_state_fits_the_pill() {
        let label = NSTextField(labelWithString: MicCoverageCopy.hudLabel)
        label.font = .systemFont(ofSize: 10, weight: MPType.medium)
        XCTAssertGreaterThan(HUDPanelGeometry.pillWidth, 8 + 5 + label.intrinsicContentSize.width)
    }

    func test_the_copy_names_the_device_and_allows_for_a_silent_owner() {
        let body = MicCoverageCopy.quietBody(device: "MacBook Pro Microphone")
        XCTAssertTrue(body.hasPrefix("If you spoke in this meeting, MacBook Pro Microphone is recording you very quietly."))
        XCTAssertTrue(body.contains("System Settings, Sound, Input"))
        XCTAssertTrue(MicCoverageCopy.quietBody(device: nil).contains("Your microphone is"))
    }

    /// The click path on a presented HUD: the label really is the clickable subclass, the quiet
    /// state puts the device in its tooltip, and a click clears it.
    @MainActor
    func test_a_click_on_the_presented_label_dismisses_the_quiet_state() throws {
        let hud = RecordingHUDWindow()
        hud.present(source: nil, workflow: nil, startedAt: Date(), levelProvider: nil)
        defer { hud.dismiss(animated: false) }
        let label = try XCTUnwrap(hud.recordingLabel, "the state label is a HUDClickableLabel")
        XCTAssertNil(label.onClick, "nothing to dismiss yet")

        hud.setMicVeryQuiet(true, device: "MacBook Pro Microphone")
        XCTAssertEqual(label.stringValue, MicCoverageCopy.hudLabel)
        XCTAssertTrue(label.toolTip?.contains("MacBook Pro Microphone") ?? false)

        let click = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        label.mouseDown(with: click)
        XCTAssertFalse(hud.micVeryQuiet)
        XCTAssertEqual(label.stringValue, "Recording")
        XCTAssertNil(label.toolTip)
        XCTAssertNil(label.onClick)
    }

    @MainActor
    func test_the_quiet_state_does_not_leak_into_the_next_recording() {
        let hud = RecordingHUDWindow()
        hud.setMicVeryQuiet(true, device: "Mic")
        XCTAssertTrue(hud.micVeryQuiet)
        hud.dismiss(animated: false)
        XCTAssertFalse(hud.micVeryQuiet)
    }
}

/// MIC17 at the session spine: the 30 s tick raises the HUD notice and one `phase: live` row, once.
@MainActor
final class MicVeryQuietSessionMIC17Tests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mic17-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        setenv("MEETINGPIPE_LOGS_DIR", tempDir.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("MEETINGPIPE_LOGS_DIR")
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private func liveRows() throws -> [[String: Any]] {
        let url = tempDir.appendingPathComponent("events.jsonl")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            .filter { $0["action"] as? String == "mic_very_quiet" }
    }

    func test_the_tick_raises_the_notice_once_and_logs_the_live_phase() throws {
        let host = FakeSessionHost(tempDir: tempDir)
        let controller = MeetingSessionController(coordinator: host)
        host.stateMachine.setRecording(
            file: tempDir.appendingPathComponent("20261118-100000.wav"), source: nil, summaryMode: .auto
        )
        controller.armMicQuietCheck()
        defer { controller.disarmMicQuietCheck() }

        host.recorderSpy.liveMicCoverage = MicCoverageSnapshot(
            recordingSeconds: 200, unmutedSeconds: 200, peakUnmutedRmsDb: -30, loudUnmutedSeconds: 0.5
        )
        controller.checkMicQuiet()
        XCTAssertTrue(host.hudSpy.micVeryQuietStates.isEmpty, "under the floor")

        host.recorderSpy.liveMicCoverage = MicCoverageSnapshot(
            recordingSeconds: 330, unmutedSeconds: 330, peakUnmutedRmsDb: -30, loudUnmutedSeconds: 0.5
        )
        controller.checkMicQuiet()
        controller.checkMicQuiet()
        XCTAssertEqual(host.hudSpy.micVeryQuietStates.count, 1)
        XCTAssertEqual(host.hudSpy.micVeryQuietStates.first?.on, true)

        let rows = try liveRows()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["phase"] as? String, "live")
        XCTAssertEqual(rows.first?["loud_seconds"] as? Double, 0.5)
        XCTAssertEqual(rows.first?["category"] as? String, "recorder")
    }

    func test_the_notice_comes_down_once_the_owner_is_audible() {
        let host = FakeSessionHost(tempDir: tempDir)
        let controller = MeetingSessionController(coordinator: host)
        host.stateMachine.setRecording(
            file: tempDir.appendingPathComponent("20261118-120000.wav"), source: nil, summaryMode: .auto
        )
        controller.armMicQuietCheck()
        defer { controller.disarmMicQuietCheck() }
        host.recorderSpy.liveMicCoverage = MicCoverageSnapshot(
            recordingSeconds: 330, unmutedSeconds: 330, peakUnmutedRmsDb: -30, loudUnmutedSeconds: 1
        )
        controller.checkMicQuiet()
        host.recorderSpy.liveMicCoverage = MicCoverageSnapshot(
            recordingSeconds: 360, unmutedSeconds: 360, peakUnmutedRmsDb: -12, loudUnmutedSeconds: 9
        )
        controller.checkMicQuiet()
        controller.checkMicQuiet()
        XCTAssertEqual(host.hudSpy.micVeryQuietStates.map(\.on), [true, false], "raised once, cleared once")
    }

    private func waitUntil(_ predicate: () -> Bool, _ what: String) async {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if predicate() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 500_000)
        }
        XCTFail("timed out waiting for \(what)")
    }

    /// Through the real start and stop: the check is armed by a start, stood down by the stop, and
    /// the stop-time tier reaches the notifier and the event log with `phase: stop`.
    func test_a_real_start_arms_the_check_and_a_quiet_stop_notifies() async throws {
        let host = FakeSessionHost(tempDir: tempDir)
        host.recorderSpy.lastSystemFires = 1
        host.recorderSpy.lastMicCoverage = MicCoverageSnapshot(
            recordingSeconds: 2116, unmutedSeconds: 2114, peakUnmutedRmsDb: -26.5, loudUnmutedSeconds: 1.7
        )
        let controller = MeetingSessionController(coordinator: host)
        let file = tempDir.appendingPathComponent("20261118-130000.wav")
        host.recorderSpy.fileToReturn = file
        let zoom = AppSource(bundleID: "us.zoom.xos", displayName: "Zoom")
        controller.beginRecording(source: zoom, summaryMode: .auto)
        await waitUntil({ if case .recording = host.stateMachine.current { return true }; return false }, "the meeting to record")
        await waitUntil({ controller.isMicQuietCheckArmed }, "the start to arm the quiet check")

        controller.stopRecording(file: file, source: zoom, summaryMode: .auto)
        await waitUntil({ host.stateMachine.current == .idle }, "the stop to finish")
        XCTAssertFalse(controller.isMicQuietCheckArmed)
        XCTAssertEqual(host.notifierSpy.micVeryQuiet.map(\.file), [file])
        XCTAssertTrue(host.notifierSpy.micRecordedNothing.isEmpty, "the dead tier did not fire")
        let rows = try liveRows()
        XCTAssertEqual(rows.compactMap { $0["phase"] as? String }, ["stop"])
        XCTAssertEqual(rows.first?["loud_seconds"] as? Double, 1.7)
    }

    func test_the_tick_does_nothing_when_no_recording_is_live() {
        let host = FakeSessionHost(tempDir: tempDir)
        let controller = MeetingSessionController(coordinator: host)
        host.recorderSpy.liveMicCoverage = MicCoverageSnapshot(
            recordingSeconds: 900, unmutedSeconds: 900, peakUnmutedRmsDb: -30, loudUnmutedSeconds: 0
        )
        controller.checkMicQuiet()
        XCTAssertTrue(host.hudSpy.micVeryQuietStates.isEmpty)
    }

    func test_a_new_recording_can_warn_again() {
        let host = FakeSessionHost(tempDir: tempDir)
        let controller = MeetingSessionController(coordinator: host)
        host.stateMachine.setRecording(
            file: tempDir.appendingPathComponent("20261118-110000.wav"), source: nil, summaryMode: .auto
        )
        host.recorderSpy.liveMicCoverage = MicCoverageSnapshot(
            recordingSeconds: 400, unmutedSeconds: 400, peakUnmutedRmsDb: -30, loudUnmutedSeconds: 0
        )
        controller.armMicQuietCheck()
        controller.checkMicQuiet()
        controller.armMicQuietCheck()
        controller.checkMicQuiet()
        controller.disarmMicQuietCheck()
        XCTAssertEqual(host.hudSpy.micVeryQuietStates.count, 2)
    }
}
