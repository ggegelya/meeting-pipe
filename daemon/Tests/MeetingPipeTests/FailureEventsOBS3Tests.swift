import XCTest
@testable import MeetingPipe

/// OBS3: failure rows say how the run ended (exit status or signal, stage, typed cause), a foreign
/// signal is never read as an exit code, and three daemon paths stop swapping the real error for a
/// guess.
final class FailureEventsOBS3Tests: XCTestCase {

    private typealias LaunchError = PipelineLauncher.LaunchError

    // MARK: - A signal is not an exit code

    func test_a_sigquit_is_an_uncaught_signal_and_never_the_publish_stage() {
        guard case .failure(let error) = PipelineLauncher.outcome(
            status: 3, reason: .uncaughtSignal, cancelled: false, stderr: "tail"
        ) else { return XCTFail("a signal is a failure") }
        guard case LaunchError.uncaughtSignal(3, "tail") = error else { return XCTFail("got \(error)") }
        XCTAssertEqual(SinkDispatcher.stage(for: error), .pipeline, "the SIGQUIT collision with exit 3")
        XCTAssertTrue(error.localizedDescription.contains("signal 3 (SIGQUIT)"), error.localizedDescription)
    }

    func test_an_exit_3_is_still_the_publish_stage() {
        guard case .failure(let error) = PipelineLauncher.outcome(
            status: 3, reason: .exit, cancelled: false, stderr: ""
        ) else { return XCTFail("exit 3 is a failure") }
        XCTAssertEqual(SinkDispatcher.stage(for: error), .publish)
    }

    func test_a_sigkill_is_not_called_memory() {
        let error = LaunchError.uncaughtSignal(SIGKILL, "")
        XCTAssertEqual(SinkDispatcher.stage(for: error), .pipeline)
        XCTAssertFalse(error.localizedDescription.lowercased().contains("memory"))
    }

    func test_the_apps_own_cancel_still_wins_over_a_signal() {
        guard case .failure(let error) = PipelineLauncher.outcome(
            status: 15, reason: .uncaughtSignal, cancelled: true, stderr: ""
        ) else { return XCTFail("a cancel completes as a failure") }
        XCTAssertTrue(PipelineLauncher.isCancellation(error))
    }

    // MARK: - One builder for the failure rows

    func test_a_bare_nonzero_exit_names_its_exit_and_stage() {
        let error = LaunchError.nonZeroExit(1, "Traceback ... Placeholder Topic")
        let attrs = PipelineOutcomeLog.failureAttributes(error, stage: .pipeline)
        XCTAssertEqual(attrs["exit_code"] as? Int, 1)
        XCTAssertEqual(attrs["termination_reason"] as? String, "exit")
        XCTAssertEqual(attrs["error_type"] as? String, "non_zero_exit")
        XCTAssertEqual(attrs["stage"] as? String, "pipeline")
        XCTAssertNil(attrs["error"], "SEC38: never the text")
        let line = PipelineOutcomeLog.failureLine(error, stage: .pipeline)
        XCTAssertTrue(line.contains("exit=1"), line)
        XCTAssertTrue(line.contains("stage=pipeline"), line)
    }

    func test_a_reported_failure_carries_cause_operation_and_provider() {
        let metadata = FailureMetadata(cause: .timeout, operation: .summary, provider: "anthropic")
        let attrs = PipelineOutcomeLog.failureAttributes(LaunchError.reportedFailure(1, metadata, ""), stage: .pipeline)
        XCTAssertEqual(attrs["cause"] as? String, "timeout")
        XCTAssertEqual(attrs["operation"] as? String, "summary")
        XCTAssertEqual(attrs["provider"] as? String, "anthropic")
        XCTAssertEqual(attrs["error_type"] as? String, "reported_failure")
    }

    func test_a_signal_row_names_the_signal() {
        let error = LaunchError.uncaughtSignal(SIGKILL, "")
        let attrs = PipelineOutcomeLog.failureAttributes(error, stage: .pipeline)
        XCTAssertEqual(attrs["signal"] as? Int, Int(SIGKILL))
        XCTAssertEqual(attrs["termination_reason"] as? String, "signal")
        XCTAssertEqual(attrs["error_type"] as? String, "uncaught_signal")
        XCTAssertNil(attrs["exit_code"])
        XCTAssertTrue(PipelineOutcomeLog.failureLine(error, stage: .pipeline).contains("signal=9"))
    }

    func test_the_library_failure_rows_use_the_builder() throws {
        let service = try String(contentsOf: Self.sources.appendingPathComponent("Library/MeetingLibraryService.swift"), encoding: .utf8)
        // regenerate_failed, retranscribe_failed and republish_failed.
        XCTAssertEqual(service.components(separatedBy: "PipelineOutcomeLog.failureAttributes(").count - 1, 3)
        let regenerate = try XCTUnwrap(service.range(of: "action: \"regenerate_failed\""))
        XCTAssertFalse(service[regenerate.lowerBound...].prefix(300).contains("localizedDescription"),
                       "no caption text in the regenerate row (SEC38)")
    }

    // MARK: - The held-end trim says what it removed

    func test_held_end_excluded_carries_the_segment_counts() {
        let attrs = SinkDispatcher.heldEndExcludedAttributes(
            file: URL(fileURLWithPath: "/x/20260511-143110.wav"), trimAt: 61, audioSeconds: 61,
            segmentsBefore: 12, segmentsAfter: 9
        )
        XCTAssertEqual(attrs["segments_before"] as? Int, 12)
        XCTAssertEqual(attrs["segments_after"] as? Int, 9)
        XCTAssertEqual(attrs["file"] as? String, "20260511-143110.wav")
    }

    // MARK: - SW-19: the real error, not a guess

    func test_an_unreadable_transcript_is_not_called_empty() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mp-obs3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let missing = dir.appendingPathComponent("absent.md")
        XCTAssertThrowsError(try AppleIntelligenceSummarizer.readTranscript(at: missing)) { error in
            guard case AppleIntelligenceError.transcriptUnreadable = error else { return XCTFail("got \(error)") }
        }
        let blank = dir.appendingPathComponent("blank.md")
        try "  \n".write(to: blank, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try AppleIntelligenceSummarizer.readTranscript(at: blank)) { error in
            guard case AppleIntelligenceError.emptyTranscript = error else { return XCTFail("got \(error)") }
        }
    }

    func test_an_unreadable_library_is_not_safe_to_move() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mp-obs3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir.path)
        XCTAssertNotNil(LibraryMover.inFlightReason(in: dir))
        let absent = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mp-obs3-absent-\(UUID().uuidString)")
        XCTAssertNil(LibraryMover.inFlightReason(in: absent), "absent is not busy")
    }

    func test_the_last_write_error_is_kept_for_the_escalation() {
        var tracker = WriteFailureTracker(threshold: 3)
        _ = tracker.record(.init(domain: "NSPOSIXErrorDomain", code: 28))
        _ = tracker.record(.init(domain: "NSPOSIXErrorDomain", code: 5))
        XCTAssertEqual(tracker.firstFailure, .init(domain: "NSPOSIXErrorDomain", code: 28))
        XCTAssertEqual(tracker.lastFailure, .init(domain: "NSPOSIXErrorDomain", code: 5))
    }

    private static var sources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MeetingPipe")
    }
}
