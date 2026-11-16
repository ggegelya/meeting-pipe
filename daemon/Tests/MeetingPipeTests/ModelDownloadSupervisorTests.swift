import XCTest
@testable import MeetingPipe

/// LOCAL1/AUD-20: `isComplete` must reject a partially-downloaded model so the
/// daemon never reports an interrupted multi-GB download as ready (the old "any
/// non-empty snapshot dir" check did). Builds throwaway HuggingFace-cache
/// layouts under a temp hub root and asserts the verdict.
final class ModelDownloadSupervisorTests: XCTestCase {

    // A custom model: SEC27 pins the presets to one revision, and these tests are
    // about structural completeness, which is the rule an unpinned model keeps.
    private let modelId = "acme/Custom-3B-4bit"
    private let sanitized = "models--acme--Custom-3B-4bit"
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

    // MARK: - SEC27 pinned revision

    /// A whole snapshot of a preset at `revision`.
    private func buildPresetCache(_ preset: String, revision: String) throws {
        let dir = hubRoot.appendingPathComponent(
            "models--" + preset.replacingOccurrences(of: "/", with: "--"), isDirectory: true)
        let snapshot = dir.appendingPathComponent("snapshots/\(revision)", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data("config".utf8).write(to: snapshot.appendingPathComponent("config.json"))
    }

    func test_a_preset_cached_at_another_revision_is_not_complete() throws {
        let preset = "mlx-community/Qwen2.5-3B-Instruct-4bit"
        try buildPresetCache(preset, revision: "deadbeef")
        XCTAssertFalse(ModelDownloadSupervisor.isComplete(modelId: preset, hubRoot: hubRoot))
    }

    func test_a_preset_cached_at_its_pinned_revision_is_complete() throws {
        let preset = "mlx-community/Qwen2.5-3B-Instruct-4bit"
        let pin = try XCTUnwrap(ModelDownloadSupervisor.pinnedRevisions[preset])
        try buildPresetCache(preset, revision: pin)
        XCTAssertTrue(ModelDownloadSupervisor.isComplete(modelId: preset, hubRoot: hubRoot))
    }

    // MARK: - UX21 download-size estimate

    func test_download_size_label_parses_param_count() {
        // The default 7B at ~0.62 GB/B is the spec's "~4.3 GB".
        XCTAssertEqual(
            ModelDownloadSupervisor.downloadSizeLabel(forModelId: "mlx-community/Qwen2.5-7B-Instruct-4bit"),
            "~4.3 GB"
        )
        XCTAssertEqual(
            ModelDownloadSupervisor.downloadSizeLabel(forModelId: "mlx-community/Qwen2.5-3B-Instruct-4bit"),
            "~1.9 GB"
        )
    }

    func test_download_size_label_ignores_the_quant_suffix() {
        // "4bit" must not be read as a 4B parameter count; only the "-7B-" token.
        XCTAssertEqual(ModelDownloadSupervisor.estimatedDownloadGB(forModelId: "org/Model-7B-Instruct-4bit"), 4.3)
    }

    func test_download_size_label_falls_back_when_unparseable() {
        XCTAssertNil(ModelDownloadSupervisor.estimatedDownloadGB(forModelId: "org/mystery-model"))
        XCTAssertEqual(ModelDownloadSupervisor.downloadSizeLabel(forModelId: "org/mystery-model"), "several GB")
    }

    // MARK: CONC7 - the prefetch's pipe handlers do not outlive it

    /// The stderr handler used to stay installed after EOF and again after termination, so it re-fired on
    /// the closed pipe from the child's exit until the main-queue hop released the `Pipe`.
    func test_both_pipe_handlers_are_cleared_when_the_prefetch_terminates() throws {
        let supervisor = ModelDownloadSupervisor(invocation: {
            .init(shell: "/bin/sh", args: ["-c", "echo noise >&2; exit 1", "sh"])
        })
        let failed = expectation(description: "failed")
        supervisor.onStateChange = { state in
            if case .failed = state { failed.fulfill() }
        }

        supervisor.ensure(modelId: "conc7/Never-Cached-3B-4bit")
        let out = try XCTUnwrap(supervisor.stdoutHandle)
        let err = try XCTUnwrap(supervisor.stderrHandle)
        wait(for: [failed], timeout: 10)

        XCTAssertNil(out.readabilityHandler, "the stdout handler outlived the prefetch")
        XCTAssertNil(err.readabilityHandler, "the stderr handler outlived the prefetch")
        XCTAssertNil(supervisor.stderrHandle)
    }

    func test_cancel_clears_both_pipe_handlers() throws {
        let supervisor = ModelDownloadSupervisor(invocation: {
            .init(shell: "/bin/sh", args: ["-c", "sleep 30", "sh"])
        })
        supervisor.ensure(modelId: "conc7/Never-Cached-3B-4bit")
        let out = try XCTUnwrap(supervisor.stdoutHandle)
        let err = try XCTUnwrap(supervisor.stderrHandle)
        XCTAssertNotNil(out.readabilityHandler)
        XCTAssertNotNil(err.readabilityHandler)

        supervisor.cancel()

        XCTAssertNil(out.readabilityHandler)
        XCTAssertNil(err.readabilityHandler)
    }
}
