import XCTest
@testable import MeetingPipe

/// PERF8 (0): a failed save must leave the previous file intact.
///
/// Four sidecar writers shared this shape: write a `.tmp`, `removeItem` the destination, then
/// `moveItem` the temp into place. Between the remove and the move the real file **did not exist**,
/// and the only copy of the data sat in a `.tmp` that nothing in either tree reads or sweeps. The
/// readers are all fail-open, so a missing file reads as empty. A process death in that window
/// therefore did not lose the edit being saved: it silently lost **every** hand-made entry the file
/// ever held, unrecoverably.
///
/// That is the wrong failure direction, and it is not theoretical for this app: four `.ips` reports
/// landed on 2026-08-13 and 08-14, and REC12 is a confirmed uncatchable ObjC abort that runs no
/// termination handler at all.
///
/// `data.write(to:options:.atomic)` already writes to a temporary file and renames it into place,
/// so the manual dance was both redundant and strictly less safe than the one-liner it wrapped.
final class AtomicSidecarWriteTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("perf8-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir {
            // A test that made the directory unwritable has to hand it back before removal.
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: - The reported defect

    /// The load-bearing one. A save that cannot complete must leave the previous overlay readable.
    /// Against the old shape the destination was already deleted by the time anything could fail.
    func test_a_failed_overlay_write_leaves_the_previous_overlay_intact() throws {
        let stem = "20260814-163455"
        _ = try SpeakerLabelStore.setLabel("THEM-A", to: "Sudip", stem: stem, in: dir)
        _ = try SpeakerLabelStore.setLabel("THEM-B", to: "Anisha", stem: stem, in: dir)
        XCTAssertEqual(SpeakerLabelStore.read(stem: stem, in: dir).labels.count, 2)

        // Make the write fail the only way a filesystem reliably can on demand.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        XCTAssertThrowsError(
            try SpeakerLabelStore.setLabel("THEM-C", to: "Rana", stem: stem, in: dir),
            "a read-only directory must surface as a write failure, not a silent success"
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)

        let after = SpeakerLabelStore.read(stem: stem, in: dir)
        XCTAssertEqual(after.labels["THEM-A"], "Sudip", "the failed save destroyed a name it was not writing")
        XCTAssertEqual(after.labels["THEM-B"], "Anisha")
        XCTAssertEqual(after.labels.count, 2, "the previous overlay must survive a failed save whole")
    }

    /// A successful save replaces cleanly and leaves no `.tmp` behind for a later reader or a
    /// backup sweep to trip over.
    func test_a_successful_write_leaves_no_temp_sibling() throws {
        let stem = "20260814-163455"
        _ = try SpeakerLabelStore.setLabel("THEM-A", to: "Sudip", stem: stem, in: dir)
        _ = try SpeakerLabelStore.setLabel("THEM-A", to: "Sudip Kumar", stem: stem, in: dir)

        XCTAssertEqual(SpeakerLabelStore.read(stem: stem, in: dir).labels["THEM-A"], "Sudip Kumar")
        let leftovers = try FileManager.default
            .contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".tmp") }
        XCTAssertEqual(leftovers, [], "a .tmp sibling nothing reads or sweeps is what the old shape stranded")
    }

    /// The same guarantee for the transcript corrections store, which holds the other class of
    /// hand-made edit the pipeline cannot regenerate.
    func test_a_failed_correction_write_leaves_the_previous_corrections_intact() throws {
        let stem = "20260814-163455"
        _ = try TranscriptCorrectionStore.upsert(segmentIndex: 4, pipelineOriginal: "DMS one two three four", edited: "DMS-1234", stem: stem, in: dir)
        XCTAssertEqual(TranscriptCorrectionStore.read(stem: stem, in: dir)[4]?.editedText, "DMS-1234")

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        XCTAssertThrowsError(
            try TranscriptCorrectionStore.upsert(segmentIndex: 9, pipelineOriginal: "spark", edited: "Spark", stem: stem, in: dir)
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)

        XCTAssertEqual(
            TranscriptCorrectionStore.read(stem: stem, in: dir)[4]?.editedText, "DMS-1234",
            "a failed save destroyed a correction it was not writing"
        )
    }

    // MARK: - The regression that recurs

    /// The shape, not just its effect. Every model-level test above stays green if a later edit
    /// reinstates remove-then-move somewhere else, and this defect was already copy-pasted into
    /// four writers, so the copy is the thing to fence.
    func test_no_sidecar_writer_removes_its_destination_before_replacing_it() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("daemon/Sources/MeetingPipe")

        for name in ["SpeakerLabelStore", "TranscriptCorrectionStore", "CorrectionStore", "PipelineFailureSidecar"] {
            let source = try String(
                contentsOf: root.appendingPathComponent("\(name).swift"), encoding: .utf8
            )
            XCTAssertFalse(
                source.contains("moveItem(at: temp"),
                "\(name) reinstated the remove-then-move write; use .atomic, which already does this safely"
            )
        }
    }
}
