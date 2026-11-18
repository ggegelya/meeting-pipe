import XCTest
@testable import MeetingPipe

/// REC30: the per-channel coverage verdict at stop, against the field's cases and baselines.
final class ChannelCoverageTests: XCTestCase {

    private func input(
        span: Double = 1_000, mic: Double? = 1_000, system: Double? = 999.5, head: Double = 0.5,
        micDelivery: ChannelCoverage.Delivery? = .init(firstSec: 0.05, lastSec: 999.9, deliveredSec: 1_000),
        systemDelivery: ChannelCoverage.Delivery? = .init(firstSec: 0.5, lastSec: 999.9, deliveredSec: 999.5)
    ) -> ChannelCoverage.Input {
        .init(spanSec: span, micAudioSec: mic, systemAudioSec: system, headOffsetSec: head,
              mic: micDelivery, system: systemDelivery)
    }

    private func verdict(_ i: ChannelCoverage.Input) throws -> ChannelCoverage.Verdict {
        try XCTUnwrap(ChannelCoverage.evaluate(i))
    }

    func test_a_system_channel_that_starts_15_s_late_is_started_late() throws {
        let v = try verdict(input(system: 985, head: 15,
                                  systemDelivery: .init(firstSec: 15, lastSec: 999.9, deliveredSec: 985)))
        XCTAssertTrue(v.isShort)
        XCTAssertEqual(v.systemCause, .startedLate)
        XCTAssertEqual(v.headOffsetSec, 15)
        XCTAssertEqual(v.noticeMissingSeconds, 15)
    }

    func test_a_system_channel_that_stops_15_s_early_is_stopped_early() throws {
        let v = try verdict(input(system: 984.5,
                                  systemDelivery: .init(firstSec: 0.5, lastSec: 985, deliveredSec: 984.5)))
        XCTAssertEqual(v.systemCause, .stoppedEarly)
        XCTAssertEqual(try XCTUnwrap(v.systemTailSec), 15, accuracy: 0.01)
        XCTAssertEqual(v.noticeMissingSeconds, 16, "the 0.5 s head offset plus the 15 s short after it")
    }

    func test_delivered_seconds_15_s_below_the_live_span_are_gaps_mid_call() throws {
        let v = try verdict(input(system: 984.5,
                                  systemDelivery: .init(firstSec: 0.5, lastSec: 999.9, deliveredSec: 984.5)))
        XCTAssertEqual(v.systemCause, .gapsMidCall)
    }

    func test_audio_delivered_but_missing_from_the_file_is_not_written() throws {
        let v = try verdict(input(system: 984.5,
                                  systemDelivery: .init(firstSec: 0.5, lastSec: 999.9, deliveredSec: 999.5)))
        XCTAssertEqual(v.systemCause, .notWritten)
        XCTAssertEqual(try XCTUnwrap(v.systemUnwrittenSec), 15, accuracy: 0.01)
    }

    /// `20261015-170719`: the mic held 2,013.8 s against 2,024.5 s from start to stop.
    func test_the_field_mic_shortfall_is_reported() throws {
        let v = try verdict(input(span: 2_024.5, mic: 2_013.8, system: 1_964.72, head: 33.21,
                                  micDelivery: .init(firstSec: 0.05, lastSec: 2_024.4, deliveredSec: 2_013.8),
                                  systemDelivery: .init(firstSec: 33.21, lastSec: 2_024.4, deliveredSec: 1_964.72)))
        XCTAssertEqual(try XCTUnwrap(v.micShortfallSec), 10.7, accuracy: 0.01)
        XCTAssertNotNil(v.micCause)
        XCTAssertEqual(try XCTUnwrap(v.channelGapSec), 15.87, accuracy: 0.01)
        XCTAssertEqual(v.noticeMissingSeconds, 49, "33.21 s head plus 15.87 s short after it")
    }

    func test_the_field_baselines_return_nothing() throws {
        // gap -0.06 s, shortfall -0.02 s, offset 0.53 s
        let v = try verdict(input(span: 1_000, mic: 1_000.02, system: 999.55, head: 0.53))
        XCTAssertFalse(v.isShort)
        XCTAssertNil(v.micCause)
        XCTAssertNil(v.systemCause)
        XCTAssertNil(v.noticeMissingSeconds)
    }

    /// REC33's suspected over-delay of the head stamp stays under both thresholds.
    func test_a_rec33_shaped_head_offset_returns_nothing() throws {
        let v = try verdict(input(system: 998, head: 2.0))
        XCTAssertFalse(v.isShort)
        XCTAssertNil(v.noticeMissingSeconds)
    }

    /// The 2.0 to 3.7 s field cases: logged, no notice.
    func test_a_3_s_gap_is_an_event_and_no_notice() throws {
        let v = try verdict(input(system: 996.5,
                                  systemDelivery: .init(firstSec: 0.5, lastSec: 997, deliveredSec: 996.5)))
        XCTAssertTrue(v.isShort)
        XCTAssertNil(v.noticeMissingSeconds)
    }

    func test_a_mic_only_recording_has_no_far_side_verdict() throws {
        let v = try verdict(input(system: nil, head: 0, systemDelivery: nil))
        XCTAssertFalse(v.isShort)
        XCTAssertEqual(v.farSideMissingSec, 0)
    }

    func test_no_span_measures_nothing() {
        XCTAssertNil(ChannelCoverage.evaluate(input(span: 0)))
    }

    func test_the_event_names_both_causes_and_the_missing_seconds() throws {
        let v = try verdict(input(system: 985, head: 15,
                                  systemDelivery: .init(firstSec: 15, lastSec: 999.9, deliveredSec: 985)))
        let a = ChannelCoverage.eventAttributes(v)
        XCTAssertEqual(a["system_cause"] as? String, "started_late")
        XCTAssertEqual(a["far_side_missing_sec"] as? Double, 15)
        XCTAssertNotNil(a["span_sec"] as? Double)
    }

    // MARK: - The stop notice

    func test_the_remote_audio_warning_names_the_missing_seconds_after_the_two_old_cases() {
        typealias C = MeetingSessionController
        XCTAssertEqual(C.remoteAudioWarning(systemFires: 0, degraded: false, farSideMissingSeconds: 30), .micOnly)
        XCTAssertEqual(C.remoteAudioWarning(systemFires: 9, degraded: true, farSideMissingSeconds: 30), .interrupted)
        XCTAssertEqual(C.remoteAudioWarning(systemFires: 9, degraded: false, farSideMissingSeconds: 30), .partlyMissing(seconds: 30))
        XCTAssertEqual(C.remoteAudioWarning(systemFires: 9, degraded: false, farSideMissingSeconds: nil), .none)
    }

    // MARK: - The capture-stop clock (source fence: `stop()` cannot run headless, REC27's class doc)

    func test_the_parity_and_the_durations_use_the_capture_stop_span_not_a_post_merge_date() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let code = String(SwiftSourceScan.codeOnly(try String(
            contentsOf: root.appendingPathComponent("Sources/MeetingPipe/MeetingRecorder.swift"), encoding: .utf8
        )))
        let persist = try XCTUnwrap(code.components(separatedBy: "private func persistAfterMerge(final: URL, producedUsableFinal: Bool, spanSec: Double) {")
            .dropFirst().first?.components(separatedBy: "\n    }\n").first)
        XCTAssertFalse(persist.contains("Date()"), "the parity wallclock must not include the merge")
        XCTAssertTrue(persist.contains("checkDurationParity(file: final, recordedFor: spanSec)"))
        let merge = try XCTUnwrap(code.components(separatedBy: "private func mergeIntermediates(").dropFirst().first?
            .components(separatedBy: "\n    }\n").first)
        XCTAssertTrue(merge.contains("let wallclockSec = session.spanSec"))
        XCTAssertTrue(merge.contains("noteChannelCoverage(session: session"))
        let end = try XCTUnwrap(code.components(separatedBy: "private func endSession() -> StopSnapshot {").dropFirst().first?
            .components(separatedBy: "\n    }\n").first)
        XCTAssertTrue(end.contains("spanSec: max(0, captureStop - startedAtUptime)"))
    }
}

/// REC30 at the session spine: the stop notice fires from the recorder's verdict.
@MainActor
final class ChannelCoverageSessionREC30Tests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rec30-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        setenv("MEETINGPIPE_LOGS_DIR", tempDir.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("MEETINGPIPE_LOGS_DIR")
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
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

    private func recordAndStop(coverage: ChannelCoverage.Verdict?) async -> FakeSessionHost {
        let host = FakeSessionHost(tempDir: tempDir)
        host.recorderSpy.lastSystemFires = 1
        host.recorderSpy.lastChannelCoverage = coverage
        let controller = MeetingSessionController(coordinator: host)
        let file = tempDir.appendingPathComponent("20261116-130000.wav")
        host.recorderSpy.fileToReturn = file
        let zoom = AppSource(bundleID: "us.zoom.xos", displayName: "Zoom")
        controller.beginRecording(source: zoom, summaryMode: .auto)
        await waitUntil({ if case .recording = host.stateMachine.current { return true }; return false }, "the meeting to record")
        controller.stopRecording(file: file, source: zoom, summaryMode: .auto, cause: .lifecycleEnd)
        await waitUntil({ host.stateMachine.current == .idle }, "the stop to finish")
        return host
    }

    private func verdict(head: Double, systemAudio: Double) -> ChannelCoverage.Verdict? {
        ChannelCoverage.evaluate(.init(
            spanSec: 600, micAudioSec: 600, systemAudioSec: systemAudio, headOffsetSec: head,
            mic: nil, system: .init(firstSec: head, lastSec: 599.9, deliveredSec: systemAudio)
        ))
    }

    func test_a_far_side_15_s_late_posts_the_partly_missing_notice() async {
        let host = await recordAndStop(coverage: verdict(head: 15, systemAudio: 585))
        XCTAssertEqual(host.notifierSpy.remotePartlyMissing.map(\.seconds), [15])
        XCTAssertTrue(host.notifierSpy.remoteInterrupted.isEmpty)
    }

    func test_a_3_s_gap_posts_nothing() async {
        let host = await recordAndStop(coverage: verdict(head: 3, systemAudio: 597))
        XCTAssertTrue(host.notifierSpy.remotePartlyMissing.isEmpty)
    }
}
