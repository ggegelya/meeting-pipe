import XCTest
@testable import MeetingPipe

/// Unit tests for the flagged-moment sidecar (FEAT8). `<stem>.markers.json` is
/// read by the pipeline (flagged excerpts) and the Library transcript tab
/// (anchor chips), so the round-trip, the snake_case on-disk keys, and the
/// empty-is-no-sidecar contract are what's under test. Plus the pure
/// marker-to-segment anchoring the chips rely on.
final class MarkerFileTests: XCTestCase {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp-markers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func test_round_trip_preserves_offsets_and_schema_version() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let final = dir.appendingPathComponent("rec.wav")

        MarkerFile.write(seconds: [1.5, 42.0, 900.25], forFinal: final)

        let parsed = try XCTUnwrap(MarkerFile.read(forFinal: final))
        XCTAssertEqual(parsed.schemaVersion, 1)
        XCTAssertEqual(parsed.markers.map(\.tSeconds), [1.5, 42.0, 900.25])
    }

    func test_write_is_noop_when_empty() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let final = dir.appendingPathComponent("rec.wav")

        MarkerFile.write(seconds: [], forFinal: final)

        XCTAssertFalse(FileManager.default.fileExists(atPath: MarkerFile.url(forFinal: final).path))
        XCTAssertNil(MarkerFile.read(forFinal: final))
    }

    func test_on_disk_uses_snake_case_keys() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let final = dir.appendingPathComponent("rec.wav")

        MarkerFile.write(seconds: [3.0], forFinal: final)

        let data = try Data(contentsOf: MarkerFile.url(forFinal: final))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["schema_version"] as? Int, 1)
        let markers = try XCTUnwrap(obj["markers"] as? [[String: Any]])
        XCTAssertEqual(markers.first?["t_seconds"] as? Double, 3.0)
    }

    func test_read_absent_returns_nil() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(MarkerFile.read(forFinal: dir.appendingPathComponent("missing.wav")))
    }

    // MARK: - Marker-to-segment anchoring

    private func seg(_ index: Int, _ start: Double, _ end: Double) -> TranscriptSegment {
        TranscriptSegment(index: index, start: start, end: end, text: "t", speakerID: "speaker_0")
    }

    func test_assign_anchors_marker_to_its_segment() {
        let segments = [seg(0, 0, 10), seg(1, 10, 20), seg(2, 20, 30)]
        let map = TranscriptMarkerLayout.assign(markers: [12.0, 25.0], to: segments)
        XCTAssertEqual(map[1], [12.0])
        XCTAssertEqual(map[2], [25.0])
        XCTAssertNil(map[0])
    }

    func test_assign_marker_before_first_segment_falls_to_first() {
        let segments = [seg(0, 5, 10), seg(1, 10, 20)]
        let map = TranscriptMarkerLayout.assign(markers: [1.0], to: segments)
        XCTAssertEqual(map[0], [1.0])
    }

    func test_assign_keys_by_stable_segment_index_not_array_position() {
        // Segment ids skip 1 (an empty segment was filtered upstream); the map
        // must key by the stable `.index`, not the array position.
        let segments = [seg(0, 0, 10), seg(2, 10, 20)]
        let map = TranscriptMarkerLayout.assign(markers: [15.0], to: segments)
        XCTAssertEqual(map[2], [15.0])
    }

    func test_assign_empty_segments_is_empty_map() {
        XCTAssertTrue(TranscriptMarkerLayout.assign(markers: [1.0], to: []).isEmpty)
    }
}
