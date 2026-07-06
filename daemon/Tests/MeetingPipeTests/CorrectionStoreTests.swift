import XCTest
@testable import MeetingPipe

/// `CorrectionStore` is the on-disk contract the Phase 3 LoRA trainer
/// will read from. Tests cover the JSON round-trip (incl. the dropped
/// `corrected_summary` for non-edited verdicts), overwrite semantics
/// (re-correction replaces, doesn't append), and that read() tolerates
/// missing or unreadable files.
final class CorrectionStoreTests: XCTestCase {

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mp-corrections-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        return dir
    }

    private func sampleSummary() -> [String: Any] {
        return [
            "title": "Sprint planning",
            "summary": ["aligned roadmap", "agreed scope"],
            "decisions": ["ship cookies feature on Friday"],
            "actions": [[
                "task": "draft RFC",
                "owner": "alice",
                "due": NSNull(),
                "confidence": "high",
            ]],
            "questions": ["what's the rollout plan?"],
            "attendees": ["alice", "bob"],
            "detected_language": "en",
        ]
    }

    func test_writes_good_record_without_corrected_summary() throws {
        let dir = try makeTempDir()
        let timestamp = Date(timeIntervalSince1970: 1_715_000_000)

        let path = try CorrectionStore.write(
            stem: "20260508-1500",
            transcriptPath: "/abs/20260508-1500.md",
            summaryJsonPath: "/abs/20260508-1500.summary.json",
            modelId: "mlx-community/Qwen2.5-3B-Instruct-4bit",
            backend: "local",
            verdict: .good,
            originalSummary: sampleSummary(),
            timestamp: timestamp,
            directoryOverride: dir
        )

        XCTAssertEqual(path, dir.appendingPathComponent("20260508-1500.json"))
        let parsed = try parseJSON(at: path)
        XCTAssertEqual(parsed["verdict"] as? String, "good")
        XCTAssertEqual(parsed["backend"] as? String, "local")
        XCTAssertEqual(parsed["model_id"] as? String, "mlx-community/Qwen2.5-3B-Instruct-4bit")
        XCTAssertEqual(parsed["transcript_path"] as? String, "/abs/20260508-1500.md")
        XCTAssertEqual(parsed["summary_json_path"] as? String, "/abs/20260508-1500.summary.json")
        XCTAssertNotNil(parsed["original_summary"] as? [String: Any])
        XCTAssertNil(parsed["corrected_summary"], "good verdict must omit corrected_summary")
        XCTAssertNil(parsed["notes"])
        // 1_715_000_000 epoch seconds = 2024-05-06 12:53:20 UTC.
        // (Previous expected string had a typo from the original
        // commit — the formatter has always produced this value.)
        XCTAssertEqual(parsed["ts"] as? String, "2024-05-06T12:53:20Z")
    }

    func test_writes_edited_record_with_corrected_summary() throws {
        let dir = try makeTempDir()
        var corrected = sampleSummary()
        corrected["title"] = "Sprint planning (corrected)"

        let path = try CorrectionStore.write(
            stem: "20260508-1500",
            transcriptPath: "/abs/20260508-1500.md",
            summaryJsonPath: "/abs/20260508-1500.summary.json",
            modelId: "claude-sonnet-4-6",
            backend: "anthropic",
            verdict: .edited,
            originalSummary: sampleSummary(),
            correctedSummary: corrected,
            notes: "fixed the title typo",
            directoryOverride: dir
        )

        let parsed = try parseJSON(at: path)
        XCTAssertEqual(parsed["verdict"] as? String, "edited")
        XCTAssertEqual(parsed["notes"] as? String, "fixed the title typo")
        let storedCorrected = parsed["corrected_summary"] as? [String: Any]
        XCTAssertEqual(storedCorrected?["title"] as? String, "Sprint planning (corrected)")
    }

    func test_overwrite_replaces_previous_record(_ caller: StaticString = #function) throws {
        let dir = try makeTempDir()

        try CorrectionStore.write(
            stem: "stem-x",
            transcriptPath: "/x.md",
            summaryJsonPath: "/x.summary.json",
            modelId: "m",
            backend: "local",
            verdict: .bad,
            originalSummary: sampleSummary(),
            directoryOverride: dir
        )

        try CorrectionStore.write(
            stem: "stem-x",
            transcriptPath: "/x.md",
            summaryJsonPath: "/x.summary.json",
            modelId: "m",
            backend: "local",
            verdict: .good,
            originalSummary: sampleSummary(),
            directoryOverride: dir
        )

        // Single file, latest verdict.
        let entries = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasSuffix(".json") }
        XCTAssertEqual(entries.count, 1)
        let parsed = try parseJSON(at: entries[0])
        XCTAssertEqual(parsed["verdict"] as? String, "good")
    }

    func test_read_returns_nil_when_missing() throws {
        let dir = try makeTempDir()
        XCTAssertNil(CorrectionStore.read(stem: "absent", directoryOverride: dir))
    }

    func test_read_round_trips_written_record() throws {
        let dir = try makeTempDir()
        try CorrectionStore.write(
            stem: "rt",
            transcriptPath: "/rt.md",
            summaryJsonPath: "/rt.summary.json",
            modelId: "m",
            backend: "local",
            verdict: .good,
            originalSummary: sampleSummary(),
            directoryOverride: dir
        )
        let read = CorrectionStore.read(stem: "rt", directoryOverride: dir)
        XCTAssertNotNil(read)
        XCTAssertEqual(read?["verdict"] as? String, "good")
    }

    func test_editedStems_returns_only_edited_verdicts() throws {
        let dir = try makeTempDir()
        // Two edits, one good grade, one bad grade. Only the edits drive the
        // "Summary edited locally" marker (UX15); grades are not edits.
        for (stem, verdict) in [
            ("20260508-1500", CorrectionStore.Verdict.edited),
            ("20260508-1600", .good),
            ("20260508-1700", .edited),
            ("20260508-1800", .bad),
        ] {
            try CorrectionStore.write(
                stem: stem,
                transcriptPath: "/\(stem).md",
                summaryJsonPath: "/\(stem).summary.json",
                modelId: "m",
                backend: "local",
                verdict: verdict,
                originalSummary: sampleSummary(),
                directoryOverride: dir
            )
        }
        let edited = CorrectionStore.editedStems(directoryOverride: dir)
        XCTAssertEqual(edited, ["20260508-1500", "20260508-1700"])
    }

    func test_editedStems_is_empty_for_absent_directory() {
        let absent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mp-corrections-absent-\(UUID().uuidString)", isDirectory: true)
        XCTAssertTrue(CorrectionStore.editedStems(directoryOverride: absent).isEmpty)
    }

    func test_load_run_sidecar_round_trips() throws {
        let dir = try makeTempDir()
        let runURL = dir.appendingPathComponent("foo.run.json")
        let payload: [String: Any] = [
            "stem": "foo",
            "backend": "local",
            "model": "mlx-community/Qwen2.5-3B-Instruct-4bit",
            "transcript_path": "/abs/foo.md",
            "transcript_chars": 1234,
            "summary_json_path": "/abs/foo.summary.json",
            "ts": "2026-05-08T14:33:00Z",
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: runURL)
        let loaded = try CorrectionStore.loadRunSidecar(at: runURL)
        XCTAssertEqual(loaded["backend"] as? String, "local")
        XCTAssertEqual(loaded["transcript_chars"] as? Int, 1234)
    }

    func test_load_run_sidecar_throws_on_missing() {
        let url = URL(fileURLWithPath: "/tmp/definitely-not-here.run.json")
        XCTAssertThrowsError(try CorrectionStore.loadRunSidecar(at: url))
    }

    // MARK: helpers

    private func parseJSON(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw NSError(domain: "test", code: 1)
        }
        return parsed
    }
}
