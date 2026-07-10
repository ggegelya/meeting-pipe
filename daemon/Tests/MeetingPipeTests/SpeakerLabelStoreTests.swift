import XCTest
@testable import MeetingPipe

/// FEAT3-UNDO: the reversible speaker-label overlay. The store never touches
/// `<stem>.json`, so these exercise the read/write round-trip, the empty-deletes
/// invariant, and the resolution precedence (segment override > cluster name > raw).
final class SpeakerLabelStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("slt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func seg(_ index: Int, speaker: String?) -> TranscriptSegment {
        TranscriptSegment(index: index, start: 0, end: 1, text: "x", speakerID: speaker)
    }

    func test_missing_sidecar_reads_empty() {
        XCTAssertEqual(SpeakerLabelStore.read(stem: "m", in: dir), .empty)
    }

    func test_set_and_read_label_roundtrips() throws {
        _ = try SpeakerLabelStore.setLabel("THEM-A", to: "Alice", stem: "m", in: dir)
        XCTAssertEqual(SpeakerLabelStore.read(stem: "m", in: dir).labels["THEM-A"], "Alice")
    }

    func test_remove_label_reverts_and_deletes_empty_sidecar() throws {
        _ = try SpeakerLabelStore.setLabel("THEM-A", to: "Alice", stem: "m", in: dir)
        _ = try SpeakerLabelStore.removeLabel("THEM-A", stem: "m", in: dir)
        XCTAssertEqual(SpeakerLabelStore.read(stem: "m", in: dir), .empty)
        // Emptying the overlay deletes the sidecar so the next load reads "no overrides".
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SpeakerLabelStore.path(stem: "m", in: dir).path))
    }

    func test_resolution_cluster_name_wins_over_raw_label() throws {
        let overlay = try SpeakerLabelStore.setLabel("THEM-A", to: "Alice", stem: "m", in: dir)
        XCTAssertEqual(SpeakerLabelStore.assignedLabel(for: seg(0, speaker: "THEM-A"), using: overlay), "Alice")
        XCTAssertEqual(SpeakerLabelStore.displayLabel(for: seg(0, speaker: "THEM-A"), using: overlay), "Alice")
        // An un-named cluster carries its raw diarization label unchanged.
        XCTAssertNil(SpeakerLabelStore.assignedLabel(for: seg(1, speaker: "THEM-B"), using: overlay))
        XCTAssertEqual(SpeakerLabelStore.displayLabel(for: seg(1, speaker: "THEM-B"), using: overlay), "THEM-B")
    }

    func test_segment_override_wins_over_cluster_name() throws {
        _ = try SpeakerLabelStore.setLabel("THEM-A", to: "Alice", stem: "m", in: dir)
        let overlay = try SpeakerLabelStore.setSegment(3, to: "Bob", stem: "m", in: dir)
        // Segment 3 (also in the THEM-A cluster) shows the per-segment Bob...
        XCTAssertEqual(SpeakerLabelStore.assignedLabel(for: seg(3, speaker: "THEM-A"), using: overlay), "Bob")
        // ...while other THEM-A segments still show the cluster name.
        XCTAssertEqual(SpeakerLabelStore.assignedLabel(for: seg(0, speaker: "THEM-A"), using: overlay), "Alice")
    }

    func test_labels_and_segments_persist_together() throws {
        _ = try SpeakerLabelStore.setLabel("THEM-A", to: "Alice", stem: "m", in: dir)
        _ = try SpeakerLabelStore.setSegment(3, to: "Bob", stem: "m", in: dir)
        let reread = SpeakerLabelStore.read(stem: "m", in: dir)
        XCTAssertEqual(reread.labels["THEM-A"], "Alice")
        XCTAssertEqual(reread.segments[3], "Bob")
    }
}
