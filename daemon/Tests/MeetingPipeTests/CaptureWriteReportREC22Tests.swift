import AppKit
import XCTest
@testable import MeetingPipe

/// REC22: the stop-time totals and the HUD state for a writer that fell behind (F155).
final class CaptureWriteReportREC22Tests: XCTestCase {

    private func tracker(_ outcomes: [WriteFailureTracker.FailureCode?]) -> WriteFailureTracker {
        var t = WriteFailureTracker()
        for o in outcomes { _ = t.record(o) }
        return t
    }

    private let enospc = WriteFailureTracker.FailureCode(domain: NSPOSIXErrorDomain, code: 28)

    private func report(
        wedged: Bool = false, mic: [WriteFailureTracker] = [], system: [WriteFailureTracker] = [],
        micPeak: Int = 0, systemPeak: Int = 0
    ) -> CaptureWriteReport {
        CaptureWriteReport.make(
            writerWedged: wedged, mic: mic, system: system,
            micBacklogPeakBytes: micPeak, systemBacklogPeakBytes: systemPeak,
            micBytesPerSecond: 192_000, systemBytesPerSecond: 384_000
        )
    }

    // MARK: - The stopping line and the event

    func test_a_clean_recording_emits_no_event_and_says_zero() {
        let r = report(mic: [tracker([nil, nil])], system: [tracker([nil])])
        XCTAssertNil(r.event)
        XCTAssertTrue(r.stoppingFields.contains("mic_write_failures=0 system_write_failures=0"), r.stoppingFields)
    }

    func test_failures_go_on_the_line_and_into_one_event() throws {
        let r = report(mic: [tracker([nil, enospc, nil, enospc])], system: [tracker([nil])])
        XCTAssertTrue(r.stoppingFields.contains("mic_write_failures=2 system_write_failures=0"), r.stoppingFields)
        let event = try XCTUnwrap(r.event)
        XCTAssertEqual(event["mic_write_failures"] as? Int, 2)
        XCTAssertEqual(event["system_write_failures"] as? Int, 0)
        XCTAssertEqual(event["mic_first_domain"] as? String, NSPOSIXErrorDomain)
        XCTAssertEqual(event["mic_first_code"] as? Int, 28)
        XCTAssertNil(event["system_first_domain"] as? String)
    }

    /// A wedged drain leaves the writer queue owning the tracker: unknown, never a racy read.
    func test_a_wedged_drain_says_unknown_and_emits_nothing() {
        let r = report(wedged: true, mic: [tracker([enospc])])
        XCTAssertNil(r.mic)
        XCTAssertNil(r.event)
        XCTAssertTrue(r.stoppingFields.hasSuffix("write_failures=unknown (writer wedged)"), r.stoppingFields)
        XCTAssertFalse(r.stoppingFields.contains("mic_write_failures"))
    }

    /// A system file opened fresh mid-recording has its own writer; the recording's total is both.
    func test_every_writer_of_a_channel_is_summed_and_the_first_failure_is_the_earliest() {
        let early = WriteFailureTracker.FailureCode(domain: NSCocoaErrorDomain, code: 640)
        let r = report(system: [tracker([early, nil]), tracker([enospc, enospc])])
        XCTAssertEqual(r.system, .init(failures: 3, first: early))
    }

    /// F155: the backlog peak goes on the same line, in bytes and in seconds of that channel.
    func test_the_backlog_peaks_are_on_the_line_in_seconds() {
        let r = report(mic: [], system: [], micPeak: 192_000 * 31, systemPeak: 384_000 / 2)
        XCTAssertEqual(r.micBacklogPeakSec, 31)
        XCTAssertEqual(r.systemBacklogPeakSec, 0.5)
        XCTAssertTrue(r.stoppingFields.contains("mic_backlog_peak_bytes=5952000 system_backlog_peak_bytes=192000"), r.stoppingFields)
        XCTAssertTrue(r.stoppingFields.contains("mic_backlog_peak_sec=31.0 system_backlog_peak_sec=0.5"), r.stoppingFields)
    }

    func test_an_unknown_rate_reads_as_zero_seconds() {
        let r = CaptureWriteReport.make(
            writerWedged: false, mic: [], system: [], micBacklogPeakBytes: 1000, systemBacklogPeakBytes: 0,
            micBytesPerSecond: 0, systemBytesPerSecond: 0
        )
        XCTAssertEqual(r.micBacklogPeakSec, 0)
    }

    // MARK: - The ledger (the writer-queue side)

    func test_the_ledger_counts_and_warns_once_and_escalates_once() {
        var outcomes: [WriteFailureTracker.Outcome] = []
        let ledger = WriteFailureLedger(channel: .mic, threshold: 3) { outcome, _ in outcomes.append(outcome) }
        ledger.record(NSError(domain: NSPOSIXErrorDomain, code: 28))
        ledger.record(nil)
        for _ in 0..<4 { ledger(false) }
        XCTAssertEqual(outcomes.filter { $0 == .firstFailure }.count, 1)
        XCTAssertEqual(outcomes.filter { $0 == .escalate }.count, 1)
        XCTAssertEqual(ledger.summary.totalFailures, 5)
        XCTAssertEqual(ledger.summary.firstFailure, enospc)
    }

    // MARK: - The HUD state (F155)

    func test_the_writer_state_ranks_below_the_two_losses_and_above_the_deliberate_states() {
        typealias L = HUDStateLabel
        let behind = L.writerBehindText
        XCTAssertEqual(L.resolve(micCaptureLost: true, lowSpace: nil, writerBehind: true, offRecord: false, confirmingEnd: false).text, "Mic lost")
        XCTAssertEqual(L.resolve(micCaptureLost: false, lowSpace: "Disk: 5m left", writerBehind: true, offRecord: false, confirmingEnd: false).text, "Disk: 5m left")
        let alone = L.resolve(micCaptureLost: false, lowSpace: nil, writerBehind: true, offRecord: false, confirmingEnd: false)
        XCTAssertEqual(alone.text, behind)
        XCTAssertEqual(alone.tone, .alert)
        XCTAssertEqual(L.resolve(micCaptureLost: false, lowSpace: nil, writerBehind: true, offRecord: true, confirmingEnd: true).text, behind)
    }

    func test_the_writer_state_fits_the_pill() {
        let label = NSTextField(labelWithString: HUDStateLabel.writerBehindText)
        label.font = .systemFont(ofSize: 10, weight: MPType.medium)
        XCTAssertGreaterThan(HUDPanelGeometry.pillWidth, 8 + 5 + label.intrinsicContentSize.width)
    }

    @MainActor
    func test_the_writer_state_does_not_leak_into_the_next_recording() {
        let hud = RecordingHUDWindow()
        hud.setWriterBehind(true)
        XCTAssertTrue(hud.writerBehind)
        hud.dismiss(animated: false)
        XCTAssertFalse(hud.writerBehind)
    }
}

/// REC22 at the session spine: a backlog warning sets the HUD state on a live recording only.
@MainActor
final class WriterBacklogSessionREC22Tests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rec22-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        setenv("MEETINGPIPE_LOGS_DIR", tempDir.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("MEETINGPIPE_LOGS_DIR")
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    func test_a_backlog_warning_sets_the_hud_state_without_a_banner() {
        let host = FakeSessionHost(tempDir: tempDir)
        let controller = MeetingSessionController(coordinator: host)
        host.stateMachine.setRecording(
            file: tempDir.appendingPathComponent("20261116-120000.wav"), source: nil, summaryMode: .auto
        )
        controller.handleWriterBacklog()
        XCTAssertEqual(host.hudSpy.writerBehindStates, [true])
        XCTAssertTrue(host.notifierSpy.errors.isEmpty)
        XCTAssertEqual(host.recorderSpy.stopCallCount, 0)
    }

    func test_nothing_happens_when_no_recording_is_live() {
        let host = FakeSessionHost(tempDir: tempDir)
        let controller = MeetingSessionController(coordinator: host)
        controller.handleWriterBacklog()
        XCTAssertTrue(host.hudSpy.writerBehindStates.isEmpty)
    }

    /// The Coordinator is not constructible headless, so its one line of wiring is pinned here.
    func test_the_coordinator_routes_the_recorders_warning_to_the_session() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let coordinator = try String(contentsOf: root.appendingPathComponent("Sources/MeetingPipe/Coordinator.swift"), encoding: .utf8)
        XCTAssertTrue(coordinator.contains("recorder.onWriterBacklog = { [weak self] in\n            self?.session.handleWriterBacklog()"))
        let recorder = try String(contentsOf: root.appendingPathComponent("Sources/MeetingPipe/MeetingRecorder.swift"), encoding: .utf8)
        let warn = try XCTUnwrap(recorder.components(separatedBy: "case .warn(let pendingSec):").dropFirst().first?
            .components(separatedBy: "case .stop:").first)
        XCTAssertTrue(warn.contains("onWriterBacklog?()"))
    }
}
