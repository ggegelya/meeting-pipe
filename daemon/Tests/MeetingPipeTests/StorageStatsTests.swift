import XCTest
@testable import MeetingPipe

/// The Preferences Storage section's numbers (STOR1). Pure disk inspection, so it
/// runs against a temp tree with no app.
final class StorageStatsTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mp-storage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ relativePath: String, bytes: Int) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(repeating: 0, count: bytes).write(to: url)
    }

    func test_bytesOnDisk_sums_regular_files_and_skips_symlinks() throws {
        try write("tree/a.bin", bytes: 100)
        try write("tree/nested/b.bin", bytes: 50)
        // A HuggingFace snapshot links back into blobs/; counting both double-counts.
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("tree/link.bin"),
            withDestinationURL: root.appendingPathComponent("tree/a.bin")
        )
        XCTAssertEqual(StorageScanner.bytesOnDisk(root.appendingPathComponent("tree")), 150)
    }

    func test_bytesOnDisk_of_a_missing_directory_is_zero() {
        XCTAssertEqual(StorageScanner.bytesOnDisk(root.appendingPathComponent("nope")), 0)
    }

    func test_audioBreakdown_attributes_recordings_to_their_workflow_policy() throws {
        let compressing = UUID()
        let keeping = UUID()
        try write("raw/20260101-120000.wav", bytes: 300)
        try write("raw/20260101-120000.meta.json", bytes: 0)
        try #"{"workflow_id": "\#(compressing.uuidString)"}"#
            .write(to: root.appendingPathComponent("raw/20260101-120000.meta.json"),
                   atomically: true, encoding: .utf8)

        try write("raw/20260102-120000.flac", bytes: 100)
        try #"{"workflow_id": "\#(keeping.uuidString)"}"#
            .write(to: root.appendingPathComponent("raw/20260102-120000.meta.json"),
                   atomically: true, encoding: .utf8)

        // No meta sidecar at all: a manual recording, always keep-forever.
        try write("raw/20260103-120000.wav", bytes: 70)

        let result = StorageScanner.audioBreakdown(
            in: root.appendingPathComponent("raw"),
            retentionByWorkflow: [compressing: .compress, keeping: .keep]
        )
        XCTAssertEqual(result.byPolicy[.compress], 300)
        XCTAssertEqual(result.byPolicy[.keep], 100)
        XCTAssertEqual(result.unassigned, 70)
        XCTAssertEqual(result.wavBytes, 370)
        XCTAssertEqual(result.flacBytes, 100)
    }

    func test_audioBreakdown_counts_a_deleted_workflow_as_unassigned() throws {
        try write("raw/20260101-120000.wav", bytes: 40)
        try #"{"workflow_id": "\#(UUID().uuidString)"}"#
            .write(to: root.appendingPathComponent("raw/20260101-120000.meta.json"),
                   atomically: true, encoding: .utf8)
        let result = StorageScanner.audioBreakdown(
            in: root.appendingPathComponent("raw"), retentionByWorkflow: [:]
        )
        XCTAssertEqual(result.unassigned, 40, "a workflow that no longer exists never reaps")
    }

    // MARK: REC20

    func test_audioBreakdown_puts_a_manual_recording_under_the_default_policy() throws {
        try write("raw/20260101-120000.wav", bytes: 70)
        try write("raw/20260102-120000.wav", bytes: 40)
        try #"{"workflow_id": "\#(UUID().uuidString)"}"#
            .write(to: root.appendingPathComponent("raw/20260102-120000.meta.json"),
                   atomically: true, encoding: .utf8)
        let result = StorageScanner.audioBreakdown(
            in: root.appendingPathComponent("raw"), retentionByWorkflow: [:], defaultPolicy: .compress
        )
        XCTAssertEqual(result.byPolicy[.compress], 70, "no workflow follows the default")
        XCTAssertEqual(result.unassigned, 40, "a deleted workflow is still never reaped")
    }

    func test_growth_counts_the_window_only_and_projects_the_free_space() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let day: TimeInterval = 24 * 60 * 60
        let files: [(startedAt: Date, bytes: Int)] = [
            (now.addingTimeInterval(-1 * day), 200),
            (now.addingTimeInterval(-29 * day), 100),
            (now.addingTimeInterval(-31 * day), 5_000),   // outside the window
            (now.addingTimeInterval(1 * day), 9_000),     // a clock in the future is not growth
        ]
        let projection = LibraryGrowth.project(files: files, freeBytes: 3_000, now: now)
        XCTAssertEqual(projection.bytesInWindow, 300)
        XCTAssertEqual(projection.bytesPerDay, 10)
        XCTAssertEqual(projection.daysOfFreeSpace, 300)
    }

    func test_growth_has_no_projection_without_a_rate_or_a_free_space() {
        XCTAssertNil(LibraryGrowth.Projection(bytesInWindow: 0, freeBytes: 10).daysOfFreeSpace)
        XCTAssertNil(LibraryGrowth.Projection(bytesInWindow: 10, freeBytes: 0).daysOfFreeSpace)
        XCTAssertEqual(
            LibraryGrowth.sentence(.init(bytesInWindow: 0, freeBytes: 10)),
            "No meetings in the last 30 days, so there is no rate to project."
        )
        XCTAssertEqual(
            LibraryGrowth.sentence(.init(bytesInWindow: 30 * 100, freeBytes: 2_000)),
            "At this rate the free space lasts about 20 days."
        )
        XCTAssertEqual(
            LibraryGrowth.sentence(.init(bytesInWindow: 30, freeBytes: 90)),
            "At this rate the free space lasts about 3 months."
        )
    }

    func test_growth_files_date_by_stem_prefix_and_skip_everything_else() throws {
        try write("raw/20260101-120000.wav", bytes: 10)
        try write("raw/20260101-120000.summary.json", bytes: 5)
        try write("raw/20260722-140312 Export.wav", bytes: 7)
        try write("raw/notes.txt", bytes: 99)
        try write("raw/sub/20260101-120000.wav", bytes: 99)
        // A recording in progress: its intermediates and merge are not growth.
        try write("raw/20260101-130000.mic.wav", bytes: 99)
        try write("raw/20260101-130000.system.wav", bytes: 99)
        try write("raw/20260101-130000.merging.wav", bytes: 99)
        let files = StorageScanner.stemDatedFiles(in: root.appendingPathComponent("raw"))
        XCTAssertEqual(files.map(\.bytes).sorted(), [5, 7, 10])
    }

    func test_models_marks_only_the_configured_model_in_use() throws {
        try write("hub/models--mlx-community--Qwen2.5-7B-Instruct-4bit/blobs/x", bytes: 200)
        try write("hub/models--mlx-community--Qwen2.5-3B-Instruct-4bit/blobs/x", bytes: 100)
        try write("hub/not-a-model/x", bytes: 999)

        let models = StorageScanner.models(
            in: root.appendingPathComponent("hub"),
            activeModelID: "mlx-community/Qwen2.5-7B-Instruct-4bit"
        )
        XCTAssertEqual(models.count, 2, "only `models--` entries count")
        XCTAssertEqual(models[0].repoID, "mlx-community/Qwen2.5-7B-Instruct-4bit")
        XCTAssertTrue(models[0].inUse)
        XCTAssertEqual(models[0].bytes, 200)
        XCTAssertFalse(models[1].inUse)
    }

    func test_repoID_unsanitizes_the_hub_directory_name() {
        XCTAssertEqual(
            StorageScanner.repoID(fromDirectoryName: "models--mlx-community--Qwen2.5-7B"),
            "mlx-community/Qwen2.5-7B"
        )
    }
}
