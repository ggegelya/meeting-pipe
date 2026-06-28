import XCTest
@testable import MeetingPipe

/// LOCAL1/AUD-20: `isComplete` must reject a partially-downloaded model so the
/// daemon never reports an interrupted multi-GB download as ready (the old "any
/// non-empty snapshot dir" check did). Builds throwaway HuggingFace-cache
/// layouts under a temp hub root and asserts the verdict.
final class ModelDownloadSupervisorTests: XCTestCase {

    private let modelId = "mlx-community/Qwen2.5-3B-Instruct-4bit"
    private let sanitized = "models--mlx-community--Qwen2.5-3B-Instruct-4bit"
    private var hubRoot: URL!

    override func setUpWithError() throws {
        hubRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("local1-hub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: hubRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let hubRoot { try? FileManager.default.removeItem(at: hubRoot) }
    }

    private var modelDir: URL {
        hubRoot.appendingPathComponent(sanitized, isDirectory: true)
    }

    /// Build a structurally-complete snapshot: two real blobs + a snapshot dir
    /// whose entries symlink to them (the standard hf layout). Returns the
    /// snapshot commit dir so a test can mutate it.
    @discardableResult
    private func buildCompleteCache() throws -> URL {
        let fm = FileManager.default
        let blobs = modelDir.appendingPathComponent("blobs", isDirectory: true)
        try fm.createDirectory(at: blobs, withIntermediateDirectories: true)
        let blobA = blobs.appendingPathComponent("aaaa")
        let blobB = blobs.appendingPathComponent("bbbb")
        try Data("config".utf8).write(to: blobA)
        try Data("weights".utf8).write(to: blobB)

        let snapshot = modelDir.appendingPathComponent("snapshots/deadbeef", isDirectory: true)
        try fm.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            at: snapshot.appendingPathComponent("config.json"), withDestinationURL: blobA)
        try fm.createSymbolicLink(
            at: snapshot.appendingPathComponent("model.safetensors"), withDestinationURL: blobB)
        return snapshot
    }

    func test_missing_model_dir_is_not_complete() {
        XCTAssertFalse(ModelDownloadSupervisor.isComplete(modelId: modelId, hubRoot: hubRoot))
    }

    func test_empty_snapshots_dir_is_not_complete() throws {
        try FileManager.default.createDirectory(
            at: modelDir.appendingPathComponent("snapshots", isDirectory: true),
            withIntermediateDirectories: true)
        XCTAssertFalse(ModelDownloadSupervisor.isComplete(modelId: modelId, hubRoot: hubRoot))
    }

    func test_fully_cached_is_complete() throws {
        try buildCompleteCache()
        XCTAssertTrue(ModelDownloadSupervisor.isComplete(modelId: modelId, hubRoot: hubRoot))
    }

    func test_incomplete_blob_is_not_complete() throws {
        try buildCompleteCache()
        // The canonical interrupted-download signature: an `<etag>.incomplete` blob.
        let incomplete = modelDir.appendingPathComponent("blobs/cccc.incomplete")
        try Data("half".utf8).write(to: incomplete)
        XCTAssertFalse(ModelDownloadSupervisor.isComplete(modelId: modelId, hubRoot: hubRoot))
    }

    func test_dangling_snapshot_symlink_is_not_complete() throws {
        let snapshot = try buildCompleteCache()
        // A snapshot symlink whose blob the download never finished.
        try FileManager.default.createSymbolicLink(
            at: snapshot.appendingPathComponent("tokenizer.json"),
            withDestinationURL: modelDir.appendingPathComponent("blobs/missing"))
        XCTAssertFalse(ModelDownloadSupervisor.isComplete(modelId: modelId, hubRoot: hubRoot))
    }

    func test_real_files_without_blobs_layer_are_complete() throws {
        // Some download paths store real files in the snapshot (no blobs/symlinks);
        // a structurally-whole snapshot is still complete.
        let snapshot = modelDir.appendingPathComponent("snapshots/cafef00d", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data("config".utf8).write(to: snapshot.appendingPathComponent("config.json"))
        XCTAssertTrue(ModelDownloadSupervisor.isComplete(modelId: modelId, hubRoot: hubRoot))
    }
}
