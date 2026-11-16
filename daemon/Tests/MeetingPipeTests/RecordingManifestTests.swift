import XCTest
@testable import MeetingPipe

/// Unit tests for the start-time recovery manifest (REC2 / AUD-6). The manifest
/// is what lets orphan recovery route a crash-interrupted recording by the
/// privacy + summary intent it was started with, so the round-trip and the
/// fail-closed token mapping are the contract under test.
final class RecordingManifestTests: XCTestCase {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp-manifest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func test_round_trip_byo_preserves_summary_mode_and_meta() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let meta: [String: Any] = [
            "workflow_nda_mode": true,
            "workflow_sinks": ["filesystem"],
            "meeting_title": "Sprint planning",
        ]
        RecordingManifest.write(summaryMode: .byo, meta: meta, forStem: "rec", in: dir)

        let parsed = RecordingManifest.load(forStem: "rec", in: dir).parsed
        XCTAssertEqual(parsed?.summaryMode, .byo)
        XCTAssertEqual(
            parsed,
            RecordingManifest.Parsed(summaryMode: .byo, meta: meta),
            "the meta payload must survive the round-trip for the recovery sidecar rebuild"
        )
    }

    func test_round_trip_auto_with_empty_meta() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        RecordingManifest.write(summaryMode: .auto, meta: [:], forStem: "rec", in: dir)

        let parsed = RecordingManifest.load(forStem: "rec", in: dir).parsed
        XCTAssertEqual(parsed?.summaryMode, .auto)
        XCTAssertTrue(parsed?.meta.isEmpty ?? false)
    }

    func test_read_absent_returns_nil() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(
            RecordingManifest.load(forStem: "missing", in: dir).parsed,
            "a pre-REC2 orphan has no manifest; recovery must fall back to its legacy default"
        )
    }

    func test_read_malformed_returns_nil() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("{ not json".utf8).write(to: RecordingManifest.url(forStem: "rec", in: dir))
        XCTAssertNil(RecordingManifest.load(forStem: "rec", in: dir).parsed)
    }

    func test_only_the_two_written_tokens_map_to_a_summary_mode() {
        // REC21 (F148): an unknown token used to map to `.auto`, the cloud path, for a BYO meeting.
        // Now it maps to nothing and `load` reads the manifest as unreadable.
        XCTAssertEqual(RecordingManifest.summaryMode(fromToken: "byo"), .byo)
        XCTAssertEqual(RecordingManifest.summaryMode(fromToken: "auto"), .auto)
        XCTAssertNil(RecordingManifest.summaryMode(fromToken: "weird"))
        XCTAssertNil(RecordingManifest.summaryMode(fromToken: "BYO"))
    }

    // MARK: - REC21: the redaction facts and the three-outcome read

    func test_round_trip_capture_mode_and_off_record() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        RecordingManifest.write(
            summaryMode: .auto, meta: [:], captureMode: .captureFirstRedact, offRecord: true, forStem: "rec", in: dir
        )
        let parsed = try XCTUnwrap(RecordingManifest.load(forStem: "rec", in: dir).parsed)
        XCTAssertEqual(parsed.captureMode, .captureFirstRedact)
        XCTAssertTrue(parsed.offRecord)
        XCTAssertTrue(parsed.owesRedaction)

        RecordingManifest.write(summaryMode: .byo, meta: [:], captureMode: .captureFirst, forStem: "plain", in: dir)
        let plain = try XCTUnwrap(RecordingManifest.load(forStem: "plain", in: dir).parsed)
        XCTAssertEqual(plain.captureMode, .captureFirst)
        XCTAssertFalse(plain.offRecord)
        XCTAssertFalse(plain.owesRedaction)
    }

    func test_a_manifest_written_before_rec21_still_parses() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeRaw(#"{"schema_version": 1, "summary_mode": "byo", "meta": {"meeting_title": "x"}}"#, in: dir)
        let parsed = try XCTUnwrap(RecordingManifest.load(forStem: "rec", in: dir).parsed)
        XCTAssertEqual(parsed.summaryMode, .byo)
        XCTAssertNil(parsed.captureMode)
        XCTAssertFalse(parsed.offRecord)
        XCTAssertEqual(parsed.meta["meeting_title"] as? String, "x")
    }

    func test_missing_is_absent_and_unparseable_is_unreadable() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(RecordingManifest.load(forStem: "rec", in: dir), .absent)
        try writeRaw("{ not json", in: dir)
        XCTAssertEqual(RecordingManifest.load(forStem: "rec", in: dir), .unreadable)
    }

    func test_a_summary_mode_that_is_not_exactly_auto_or_byo_is_unreadable() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for body in [
            #"{"schema_version": 1, "meta": {}}"#,
            #"{"schema_version": 1, "summary_mode": "BYO", "meta": {}}"#,
            #"{"schema_version": 1, "summary_mode": "cloud", "meta": {}}"#,
            #"{"schema_version": 1, "summary_mode": 7, "meta": {}}"#,
        ] {
            try writeRaw(body, in: dir)
            XCTAssertEqual(RecordingManifest.load(forStem: "rec", in: dir), .unreadable, body)
        }
    }

    func test_a_meta_that_is_not_an_object_is_unreadable() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for meta in [#""nda""#, "[1, 2]"] {
            try writeRaw(#"{"schema_version": 1, "summary_mode": "auto", "meta": "# + meta + "}", in: dir)
            XCTAssertEqual(RecordingManifest.load(forStem: "rec", in: dir), .unreadable, meta)
        }
        for mode in ["auto", "byo"] {
            try writeRaw(#"{"schema_version": 1, "summary_mode": ""# + mode + #"", "meta": {"a": 1}}"#, in: dir)
            XCTAssertNotNil(RecordingManifest.load(forStem: "rec", in: dir).parsed, mode)
        }
    }

    func test_a_wrong_typed_or_unknown_redaction_fact_is_unreadable() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for extra in [
            #""capture_mode": "lossless""#,
            #""capture_mode": 1"#,
            #""off_record": 1"#,
            #""off_record": "true""#,
        ] {
            try writeRaw(#"{"schema_version": 1, "summary_mode": "auto", "meta": {}, "# + extra + "}", in: dir)
            XCTAssertEqual(RecordingManifest.load(forStem: "rec", in: dir), .unreadable, extra)
        }
    }

    private func writeRaw(_ body: String, in dir: URL) throws {
        try Data(body.utf8).write(to: RecordingManifest.url(forStem: "rec", in: dir))
    }

    func test_remove_deletes_the_manifest() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        RecordingManifest.write(summaryMode: .auto, meta: [:], forStem: "rec", in: dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: RecordingManifest.url(forStem: "rec", in: dir).path))

        RecordingManifest.remove(forStem: "rec", in: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: RecordingManifest.url(forStem: "rec", in: dir).path))
    }
}
