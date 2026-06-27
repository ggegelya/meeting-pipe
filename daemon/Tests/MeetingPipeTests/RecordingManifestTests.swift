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

        let parsed = RecordingManifest.read(forStem: "rec", in: dir)
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

        let parsed = RecordingManifest.read(forStem: "rec", in: dir)
        XCTAssertEqual(parsed?.summaryMode, .auto)
        XCTAssertTrue(parsed?.meta.isEmpty ?? false)
    }

    func test_read_absent_returns_nil() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(
            RecordingManifest.read(forStem: "missing", in: dir),
            "a pre-REC2 orphan has no manifest; recovery must fall back to its legacy default"
        )
    }

    func test_read_malformed_returns_nil() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("{ not json".utf8).write(to: RecordingManifest.url(forStem: "rec", in: dir))
        XCTAssertNil(RecordingManifest.read(forStem: "rec", in: dir))
    }

    func test_unknown_summary_mode_token_defaults_to_auto() {
        // Fail-closed: only the explicit "byo" token is BYO. A torn or future
        // token must never silently flip an auto meeting to a paste bundle, nor
        // a missing one leave recovery undecided.
        XCTAssertEqual(RecordingManifest.summaryMode(fromToken: "byo"), .byo)
        XCTAssertEqual(RecordingManifest.summaryMode(fromToken: "auto"), .auto)
        XCTAssertEqual(RecordingManifest.summaryMode(fromToken: "weird"), .auto)
        XCTAssertEqual(RecordingManifest.summaryMode(fromToken: nil), .auto)
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
