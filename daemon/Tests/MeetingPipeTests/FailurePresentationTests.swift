import AppKit
import XCTest
@testable import MeetingPipe

final class FailurePresentationTests: XCTestCase {
    func test_generated_python_metadata_uses_the_swift_contract() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "failure-metadata-golden", withExtension: "json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let cases = try XCTUnwrap(object["cases"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 12)
        for item in cases {
            let payload = try JSONSerialization.data(withJSONObject: try XCTUnwrap(item["payload"]))
            let metadata = try XCTUnwrap(FailureMetadata.decode(payload))
            XCTAssertEqual(metadata.cause.rawValue, item["cause"] as? String)
            XCTAssertEqual(metadata.operation, .summary)
        }
    }

    func test_five_synthetic_legacy_incidents_load_without_rewriting() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "failure-legacy-incidents", withExtension: "json"))
        let cases = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        XCTAssertEqual(cases.count, 5)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingStore(recordingsDir: dir)
        for item in cases {
            let sidecar = try XCTUnwrap(item["sidecar"] as? [String: Any])
            let stem = try XCTUnwrap(sidecar["stem"] as? String)
            let payload = try JSONSerialization.data(withJSONObject: sidecar)
            let path = dir.appendingPathComponent(stem + ".error.json")
            try payload.write(to: path)
            let failure = try XCTUnwrap(PipelineFailureSidecar.read(at: path))
            let notice = FailurePresentation(diagnostics: failure.reason, operation: .summary, metadata: failure.metadata)
            XCTAssertEqual(notice.title, item["title"] as? String)
            let meeting = try XCTUnwrap(store.performScan(directory: dir).first { $0.stem == stem })
            XCTAssertEqual(meeting.status, .failed)
            XCTAssertEqual(FailurePresentation(diagnostics: meeting.failureReason ?? "", operation: .summary,
                metadata: meeting.failureMetadata).title, item["title"] as? String)
            XCTAssertEqual(try Data(contentsOf: path), payload)
        }
    }

    func test_notification_routes_open_only_the_failure_surface() {
        for action in [NotificationRouter.actionOpenFailure, "default"] {
            XCTAssertEqual(NotificationRouter.route(id: "failure-synthetic", action: action,
                isDefault: action == "default", doneEntry: nil).routes, [.openFailure])
        }
        XCTAssertTrue(NotificationRouter.route(id: "failure-synthetic", action: "dismiss", isDefault: false, doneEntry: nil).routes.isEmpty)
    }
    func test_legacy_billing_is_distinct_from_generic_400_and_expired_keys() {
        let billing = FailurePresentation(diagnostics: "anthropic.BadRequestError: Error code: 400 - Your credit balance is too low to access the Anthropic API.", operation: .summary)
        XCTAssertEqual(billing.title, "Insufficient Anthropic credits")
        XCTAssertFalse(billing.explanation.contains("expired"))
        XCTAssertEqual(FailurePresentation(diagnostics: "HTTP 400 invalid_request_error", operation: .summary).title, "Couldn't create the summary")
        XCTAssertEqual(FailurePresentation(diagnostics: "HTTP 401", operation: .summary).metadata.cause, .unknown)
    }

    func test_report_is_an_allowlist_and_copy_matches_preview() {
        let secrets = "Bearer sk-test-fake\nAuthorization: secret\n/Users/private\nPrivate Meeting Title\nTranscript secret\nUnrelated event"
        let metadata = FailureMetadata.decode(Data("""
        {"schema_version":1,"cause":"credits","provider":"anthropic","operation":"summary","remedy":"billing","http_status":400,"request_id":"req_0123456789abcdef","body":"sk-test-fake"}
        """.utf8))
        let failure = FailurePresentation(diagnostics: secrets, operation: .summary, metadata: metadata,
                                          timestamp: "2026-09-08T13:30:51Z")
        let report = failure.report(appVersion: "1.2.3")
        for secret in secrets.components(separatedBy: "\n") { XCTAssertFalse(report.contains(secret)) }
        XCTAssertEqual(report, """
        MeetingPipe failure report
        App version: 1.2.3
        Timestamp: 2026-09-08T13:30:51Z
        Operation: summary
        Cause: credits
        Provider: anthropic
        HTTP status: 400
        Request ID: req_0123456789abcdef
        """)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        FailureReport.copy(report, to: board)
        XCTAssertEqual(board.string(forType: .string), report)
    }

    func test_malformed_metadata_falls_back_without_exposing_its_fields() {
        for raw in ["{}", "[]", "null", "{\"schema_version\":1,\"cause\":\"unknown-secret\"}"] {
            let problem = FailurePresentation(diagnostics: "a secret traceback", operation: .ask,
                                              metadata: FailureMetadata.decode(Data(raw.utf8)))
            XCTAssertEqual(problem.title, "Couldn't answer the question")
            XCTAssertFalse(problem.report(appVersion: "1.0").contains("secret"))
        }
    }

    func test_sidecar_keeps_metadata_across_restart_without_rewriting_legacy_records() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let metadata = FailureMetadata(cause: .credits, operation: .summary, provider: "anthropic")
        let url = try XCTUnwrap(PipelineFailureSidecar.write(stem: "synthetic", in: dir, stage: .pipeline,
                                                           reason: "original diagnostics", metadata: metadata))
        let original = try Data(contentsOf: url)
        XCTAssertEqual(PipelineFailureSidecar.read(at: url)?.metadata, metadata)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func test_saved_artifact_copy_only_claims_existing_artifacts_and_cancellation_is_separate() {
        let failure = FailurePresentation(diagnostics: "MeetingPipe restarted before this meeting finished processing. Retry to resume.", operation: .summary, savedRecording: true, savedTranscript: true)
        XCTAssertEqual(failure.title, "Processing interrupted")
        XCTAssertTrue(failure.explanation.contains("Your recording and transcript are saved."))
        let cancelled = FailurePresentation(diagnostics: SinkDispatcher.cancelledReason, operation: .summary)
        XCTAssertEqual(cancelled.title, "Processing cancelled")
        XCTAssertFalse(cancelled.explanation.contains("saved"))
    }

    func test_failed_publish_keeps_summary_and_destination_details_after_library_reload() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stem = "20260908-163051"
        let summary = Data("{}".utf8)
        try summary.write(to: dir.appendingPathComponent(stem + ".summary.json"))
        let metadata = FailureMetadata(cause: .rejectedKey, operation: .publish, provider: "notion", httpStatus: 401)
        PipelineFailureSidecar.write(stem: stem, in: dir, stage: .publish, reason: "original publish diagnostics", metadata: metadata)
        let row = try XCTUnwrap(MeetingStore(recordingsDir: dir).performScan(directory: dir).first)
        XCTAssertEqual(row.failureStage, "publish")
        XCTAssertEqual(row.failureMetadata, metadata)
        XCTAssertEqual(row.failureReason, "original publish diagnostics")
        XCTAssertTrue(row.hasSummaryJSON)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(stem + ".summary.json")), summary)
    }

    func test_regeneration_failure_preserves_the_previous_summary_until_a_new_summary_supersedes_it() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stem = "20260908-163051"
        let summary = dir.appendingPathComponent(stem + ".summary.json")
        try Data("{}".utf8).write(to: summary)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: summary.path)
        let error = try XCTUnwrap(PipelineFailureSidecar.write(stem: stem, in: dir, stage: .pipeline, reason: "new failure",
            metadata: FailureMetadata(cause: .unknown, operation: .summary)))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: error.path)
        let store = MeetingStore(recordingsDir: dir)
        let failed = try XCTUnwrap(store.performScan(directory: dir).first)
        XCTAssertEqual(failed.status, .failed)
        XCTAssertTrue(failed.hasSummaryJSON)
        XCTAssertEqual(failed.failureReason, "new failure")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 300)], ofItemAtPath: summary.path)
        let recovered = try XCTUnwrap(store.performScan(directory: dir).first)
        XCTAssertEqual(recovered.status, .done)
        XCTAssertNil(recovered.failureReason)
    }
}
