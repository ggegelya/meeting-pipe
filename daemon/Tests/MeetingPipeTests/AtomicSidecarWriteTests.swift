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
/// T7 source fence (deliberate): test_no_sidecar_writer_removes_its_destination_before_replacing_it bans a `removeItem(at:` followed by a `moveItem(` in one function of any `*Store.swift` or `*Sidecar.swift` (T19 widened it from a four-file substring). Missing seam: none; the claim is about the source text itself.
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

    /// A failed save throws and the previous overlay survives. This cannot catch the remove-then-move
    /// shape by itself: the read-only directory that makes the save fail also stops that writer at
    /// its first step, before it removes anything (T19). The shape fence at the bottom is what does.
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
    /// hand-made edit the pipeline cannot regenerate: a failed save throws and the previous
    /// corrections survive. Like the overlay case it does not by itself catch the shape (T19).
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
    /// four writers, so the copy is the thing to fence. T19: by shape, not by a variable name, and
    /// across every `*Store.swift` and `*Sidecar.swift`, where it used to grep four named files
    /// for `moveItem(at: temp`, so the same dance with another variable name passed.
    func test_no_sidecar_writer_removes_its_destination_before_replacing_it() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("daemon/Sources/MeetingPipe")
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix("Store.swift") || $0.hasSuffix("Sidecar.swift") }
        XCTAssertGreaterThanOrEqual(files.count, 10, "the fence must actually be reading the stores")
        for name in files.sorted() {
            let source = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
            XCTAssertEqual(
                Self.removeThenMoveFunctions(in: source), [],
                "\(name) reinstated the remove-then-move write; use .atomic, which already does this safely"
            )
        }
    }

    /// The fence's own negative: the 2026-08 dance with a renamed temp, which the old substring
    /// check (`moveItem(at: temp`) passed, and a delete path beside a save path, which is fine.
    func test_the_shape_fence_catches_a_renamed_dance_and_spares_a_separate_delete() {
        let dance = """
            func save(_ data: Data) throws {
                let scratch = url.appendingPathExtension("partial")
                try data.write(to: scratch)
                try FileManager.default.removeItem(at: url)
                try FileManager.default.moveItem(at: scratch, to: url)
            }
            """
        XCTAssertEqual(Self.removeThenMoveFunctions(in: dance), ["save"])
        let separate = """
            func delete() throws {
                try FileManager.default.removeItem(at: url)
            }
            // A comment saying removeItem(at: url) then moveItem(at: x, to: url) is not code.
            func save(_ data: Data) throws {
                if FileManager.default.fileExists(atPath: url.path) {
                    _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
                } else {
                    try FileManager.default.moveItem(at: tmp, to: url)
                }
            }
            """
        XCTAssertEqual(Self.removeThenMoveFunctions(in: separate), [])
    }

    /// Names of the functions in `source` that call `removeItem(at:` and then `moveItem(` later in
    /// the same body. Comments are dropped first; a function runs from its `func` to the next one.
    static func removeThenMoveFunctions(in source: String) -> [String] {
        let code = source.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
            guard let slash = line.range(of: "//") else { return line }
            return line[..<slash.lowerBound]
        }.joined(separator: "\n")
        var hits: [String] = []
        for chunk in code.components(separatedBy: "func ").dropFirst() {
            guard let remove = chunk.range(of: "removeItem(at:"),
                  chunk.range(of: "moveItem(", range: remove.upperBound..<chunk.endIndex) != nil else { continue }
            hits.append(String(chunk.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" })))
        }
        return hits
    }
}
