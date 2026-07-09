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
