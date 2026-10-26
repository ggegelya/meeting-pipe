import XCTest
@testable import MeetingPipe

/// SEC25: `<stem>.meta.json` is the only home of a meeting's per-workflow NDA posture, and every
/// Swift reader used to treat a file it could not read exactly like one that was not there, which
/// is "no workflow", which is cloud. `MeetingMetaRead` keeps the three outcomes apart, and the
/// third one fails closed everywhere a privacy decision reads it.
final class MeetingMetaReadTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sec25-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ text: String, stem: String) throws {
        try Data(text.utf8).write(to: dir.appendingPathComponent("\(stem).meta.json"))
    }

    // MARK: - The three outcomes

    func test_a_missing_sidecar_is_absent_and_not_zero_egress() {
        let read = MeetingMetaRead.load(stem: "20261026-090000", in: dir)
        guard case .absent = read else { return XCTFail("expected absent, got \(read)") }
        XCTAssertFalse(read.isZeroEgress)
        XCTAssertNil(read.dictionary)
    }

    func test_a_readable_sidecar_is_loaded_and_answers_from_its_keys() throws {
        try write(#"{"workflow_name": "General", "workflow_nda_mode": false}"#, stem: "a")
        let plain = MeetingMetaRead.load(stem: "a", in: dir)
        XCTAssertEqual(plain.dictionary?["workflow_name"] as? String, "General")
        XCTAssertFalse(plain.isZeroEgress)

        try write(#"{"workflow_nda_mode": true}"#, stem: "b")
        XCTAssertTrue(MeetingMetaRead.load(stem: "b", in: dir).isZeroEgress)
        try write(#"{"regulated_mode": true}"#, stem: "c")
        XCTAssertTrue(MeetingMetaRead.load(stem: "c", in: dir).isZeroEgress)
    }

    func test_unparseable_bytes_are_unreadable_parse_and_zero_egress() throws {
        try write("{not json", stem: "d")
        let read = MeetingMetaRead.load(stem: "d", in: dir)
        guard case .unreadable(let kind, _, _) = read else { return XCTFail("expected unreadable, got \(read)") }
        XCTAssertEqual(kind, .parse)
        XCTAssertTrue(read.isZeroEgress)
        XCTAssertNil(read.dictionary)
    }

    func test_json_that_is_not_an_object_is_unreadable_parse() throws {
        try write(#"["workflow_nda_mode"]"#, stem: "e")
        guard case .unreadable(.parse, _, _) = MeetingMetaRead.load(stem: "e", in: dir) else {
            return XCTFail("a top-level array is not a sidecar")
        }
    }

    func test_a_file_that_cannot_be_read_is_unreadable_io_and_zero_egress() throws {
        // A directory in the sidecar's place: the read fails the way the 2026-10-16 EDEADLK
        // on a dataless iCloud file did, with the file present and its bytes out of reach.
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("f.meta.json"), withIntermediateDirectories: true)
        let read = MeetingMetaRead.load(stem: "f", in: dir)
        guard case .unreadable(let kind, _, _) = read else { return XCTFail("expected unreadable, got \(read)") }
        XCTAssertEqual(kind, .io)
        XCTAssertTrue(read.isZeroEgress)
    }

    // MARK: - The Library row

    /// The row reads the same file, so an unreadable sidecar shows the Local only badge and counts
    /// as local-only in the batch pane and the merge posture check, which all read `isZeroEgress`.
    func test_the_library_row_reads_an_unreadable_sidecar_as_zero_egress() throws {
        let stem = "20261026-091500"
        try Data().write(to: dir.appendingPathComponent("\(stem).wav"))
        try write("{not json", stem: stem)
        let row = try XCTUnwrap(MeetingStore(recordingsDir: dir).performScan(directory: dir).first)
        XCTAssertTrue(row.isZeroEgress)
        XCTAssertTrue(row.metaUnreadable)
    }

    func test_the_library_row_without_a_sidecar_stays_unrestricted() throws {
        let stem = "20261026-091600"
        try Data().write(to: dir.appendingPathComponent("\(stem).wav"))
        let row = try XCTUnwrap(MeetingStore(recordingsDir: dir).performScan(directory: dir).first)
        XCTAssertFalse(row.isZeroEgress)
        XCTAssertFalse(row.metaUnreadable)
    }

    // MARK: - Held on a failed write

    func test_only_a_private_workflow_holds_the_job_on_a_failed_write() {
        XCTAssertFalse(MetaWriteFailure.holdsJob(workflow: nil))
        XCTAssertFalse(MetaWriteFailure.holdsJob(workflow: Workflow(name: "General")))

        var nda = Workflow(name: "Client NDA")
        nda.flags.ndaMode = true
        XCTAssertTrue(MetaWriteFailure.holdsJob(workflow: nda))

        var local = Workflow(name: "On device")
        local.backend = .local
        XCTAssertTrue(MetaWriteFailure.holdsJob(workflow: local))

        var apple = Workflow(name: "Apple")
        apple.backend = .appleIntelligence
        XCTAssertTrue(MetaWriteFailure.holdsJob(workflow: apple))

        var cloud = Workflow(name: "Cloud")
        cloud.backend = .anthropic
        XCTAssertFalse(MetaWriteFailure.holdsJob(workflow: cloud))
    }

    /// The held row explains itself rather than showing the generic "Retry when you are ready".
    func test_the_held_reason_is_presented_as_written() {
        let failure = FailurePresentation(diagnostics: MetaWriteFailure.heldReason, operation: .processing)
        XCTAssertTrue(failure.explanation.contains(MetaWriteFailure.heldReason))
    }
}
