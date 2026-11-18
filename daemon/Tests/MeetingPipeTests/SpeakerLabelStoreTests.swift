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

    func test_reassigning_to_a_named_cluster_chains_to_the_name() throws {
        // FEAT3-SEGMENT: reassigning a segment to the THEM-A cluster (named Alice)
        // resolves to Alice, matching the Python resolution.
        _ = try SpeakerLabelStore.setLabel("THEM-A", to: "Alice", stem: "m", in: dir)
        let overlay = try SpeakerLabelStore.setSegment(5, to: "THEM-A", stem: "m", in: dir)
        XCTAssertEqual(SpeakerLabelStore.displayLabel(for: seg(5, speaker: "THEM-B"), using: overlay), "Alice")
        XCTAssertEqual(SpeakerLabelStore.assignedLabel(for: seg(5, speaker: "THEM-B"), using: overlay), "Alice")
    }

    func test_batch_set_and_remove_segments() throws {
        _ = try SpeakerLabelStore.setSegments([1, 2, 3], to: "Bob", stem: "m", in: dir)
        XCTAssertEqual(SpeakerLabelStore.read(stem: "m", in: dir).segments, [1: "Bob", 2: "Bob", 3: "Bob"])
        _ = try SpeakerLabelStore.removeSegments([1, 3], stem: "m", in: dir)
        XCTAssertEqual(SpeakerLabelStore.read(stem: "m", in: dir).segments, [2: "Bob"])
    }
}

// MARK: - STOR9: unreadable is not empty

extension SpeakerLabelStoreTests {
    private func stor9Dir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mp-stor9-labels-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// The defect: the malformed file read as empty and the naming saved "empty plus one" over it.
    func test_stor9_a_malformed_sidecar_is_quarantined_before_a_naming_writes() throws {
        let dir = try stor9Dir()
        let url = SpeakerLabelStore.path(stem: "m", in: dir)
        try StoreFiles.garbage.write(to: url)

        try SpeakerLabelStore.setLabel("THEM-A", to: "Alice", stem: "m", in: dir)

        let copies = StoreFiles.corruptCopies(of: url)
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(try Data(contentsOf: copies[0]), StoreFiles.garbage, "the owner's bytes are kept whole")
        XCTAssertEqual(SpeakerLabelStore.read(stem: "m", in: dir).labels, ["THEM-A": "Alice"])
    }

    func test_stor9_a_non_object_sidecar_is_unparseable_too() throws {
        let dir = try stor9Dir()
        let url = SpeakerLabelStore.path(stem: "m", in: dir)
        try Data("[1, 2]".utf8).write(to: url)
        try SpeakerLabelStore.setLabel("THEM-A", to: "Alice", stem: "m", in: dir)
        XCTAssertEqual(StoreFiles.corruptCopies(of: url).count, 1)
    }

    func test_stor9_an_unreadable_sidecar_refuses_every_writer_and_is_left_alone() throws {
        let dir = try stor9Dir()
        let url = SpeakerLabelStore.path(stem: "m", in: dir)
        let original = Data(#"{"schema_version": 1, "labels": {"THEM-A": "Alice", "THEM-B": "Bob"}}"#.utf8)
        try original.write(to: url)
        StoreFiles.lock(url, in: self)

        XCTAssertThrowsError(try SpeakerLabelStore.setLabel("THEM-C", to: "Carol", stem: "m", in: dir)) {
            XCTAssertTrue($0 is StoreRefusal)
        }
        // `removeLabel` over a fail-open empty read used to delete the whole sidecar.
        XCTAssertThrowsError(try SpeakerLabelStore.removeLabel("THEM-A", stem: "m", in: dir))
        XCTAssertThrowsError(try SpeakerLabelStore.replace(overlay: .empty, stem: "m", in: dir))
        StoreFiles.unlock(url)
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertTrue(StoreFiles.corruptCopies(of: url).isEmpty)
    }
}
