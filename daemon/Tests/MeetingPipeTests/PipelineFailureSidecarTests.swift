import XCTest
@testable import MeetingPipe

/// Round-trip + resilience tests for `PipelineFailureSidecar` — the
/// durable record of why a meeting's pipeline run failed. The sidecar is
/// the only thing standing between a missed notification and a silently
/// lost meeting, so its read path must tolerate every malformed input
/// rather than throw.
final class PipelineFailureSidecarTests: XCTestCase {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp-failure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Naming

    func test_fileName_appends_the_error_suffix() {
        XCTAssertEqual(
            PipelineFailureSidecar.fileName(forStem: "20260522-103108"),
            "20260522-103108.error.json"
        )
    }

    func test_url_resolves_under_the_recordings_directory() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = PipelineFailureSidecar.url(forStem: "x", in: dir)
        XCTAssertEqual(url.lastPathComponent, "x.error.json")
        XCTAssertEqual(url.deletingLastPathComponent().path, dir.path)
    }

    // MARK: - Write + read round-trip

    func test_write_then_read_round_trips_every_field() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let when = Date(timeIntervalSince1970: 1_700_000_000)

        let written = PipelineFailureSidecar.write(
            stem: "x", in: dir,
            stage: .pipeline,
            reason: "pipeline exited 1: boom",
            timestamp: when
        )
        XCTAssertNotNil(written)

        let failure = PipelineFailureSidecar.read(stem: "x", in: dir)
        XCTAssertEqual(failure?.stage, .pipeline)
        XCTAssertEqual(failure?.reason, "pipeline exited 1: boom")
        XCTAssertEqual(failure?.ts, Self.expectedISO(when))
    }

    func test_write_emits_valid_json_with_the_expected_keys() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        PipelineFailureSidecar.write(
            stem: "x", in: dir, stage: .transcribe, reason: "ASR crashed"
        )

        let url = PipelineFailureSidecar.url(forStem: "x", in: dir)
        let data = try Data(contentsOf: url)
        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(obj["stem"] as? String, "x")
        XCTAssertEqual(obj["stage"] as? String, "transcribe")
        XCTAssertEqual(obj["reason"] as? String, "ASR crashed")
        XCTAssertNotNil(obj["ts"] as? String)
    }

    func test_write_overwrites_a_prior_sidecar() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        PipelineFailureSidecar.write(
            stem: "x", in: dir, stage: .transcribe, reason: "first failure"
        )
        PipelineFailureSidecar.write(
            stem: "x", in: dir, stage: .launch, reason: "second failure"
        )

        let failure = PipelineFailureSidecar.read(stem: "x", in: dir)
        XCTAssertEqual(failure?.stage, .launch)
        XCTAssertEqual(failure?.reason, "second failure")
    }

    func test_reason_with_newlines_round_trips() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A non-zero-exit reason carries a multi-line stderr tail.
        let tail = "Traceback (most recent call last):\n  File ...\nRuntimeError: x"

        PipelineFailureSidecar.write(
            stem: "x", in: dir, stage: .pipeline, reason: tail
        )
        XCTAssertEqual(PipelineFailureSidecar.read(stem: "x", in: dir)?.reason, tail)
    }

    // MARK: - Read resilience

    func test_read_of_a_missing_file_returns_nil() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(PipelineFailureSidecar.read(stem: "nope", in: dir))
    }

    func test_read_of_malformed_json_returns_nil() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = PipelineFailureSidecar.url(forStem: "x", in: dir)
        try Data("{not json".utf8).write(to: url)
        XCTAssertNil(PipelineFailureSidecar.read(stem: "x", in: dir))
    }

    func test_read_of_an_unknown_stage_returns_nil() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = PipelineFailureSidecar.url(forStem: "x", in: dir)
        let payload = #"{"stem":"x","stage":"bogus","reason":"r","ts":"t"}"#
        try Data(payload.utf8).write(to: url)
        XCTAssertNil(PipelineFailureSidecar.read(stem: "x", in: dir))
    }

    func test_read_of_a_record_missing_reason_returns_nil() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = PipelineFailureSidecar.url(forStem: "x", in: dir)
        let payload = #"{"stem":"x","stage":"pipeline","ts":"t"}"#
        try Data(payload.utf8).write(to: url)
        XCTAssertNil(PipelineFailureSidecar.read(stem: "x", in: dir))
    }

    // MARK: - Clear

    func test_clear_removes_an_existing_sidecar() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        PipelineFailureSidecar.write(
            stem: "x", in: dir, stage: .pipeline, reason: "boom"
        )
        XCTAssertNotNil(PipelineFailureSidecar.read(stem: "x", in: dir))

        PipelineFailureSidecar.clear(stem: "x", in: dir)
        XCTAssertNil(PipelineFailureSidecar.read(stem: "x", in: dir))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: PipelineFailureSidecar.url(forStem: "x", in: dir).path
        ))
    }

    func test_clear_of_a_missing_sidecar_is_a_no_op() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Must not throw or crash when there is nothing to remove.
        PipelineFailureSidecar.clear(stem: "never-failed", in: dir)
    }

    // MARK: - Helpers

    private static func expectedISO(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
