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

    private let configured = "mlx-community/Qwen2.5-7B-Instruct-4bit"

    /// STOR15: a hub holding the configured model, another preset, the search embedder and a repo
    /// some other tool downloaded.
    private func writeHub() throws {
        try write("hub/models--mlx-community--Qwen2.5-7B-Instruct-4bit/blobs/x", bytes: 400)
        try write("hub/models--mlx-community--Qwen2.5-3B-Instruct-4bit/blobs/x", bytes: 100)
        try write("hub/models--mlx-community--multilingual-e5-small-mlx/blobs/x", bytes: 241)
        try write("hub/models--someone--other-model/blobs/x", bytes: 900)
        try write("hub/not-a-model/x", bytes: 999)
    }

    func test_models_classifies_each_repo_by_who_owns_it() throws {
        try writeHub()
        let models = StorageScanner.models(in: root.appendingPathComponent("hub"), activeModelID: configured)
        XCTAssertEqual(models.count, 4, "only `models--` entries count")
        let byRepo = Dictionary(uniqueKeysWithValues: models.map { ($0.repoID, $0) })
        XCTAssertEqual(byRepo[configured]?.ownership, .inUse)
        XCTAssertEqual(byRepo["mlx-community/Qwen2.5-3B-Instruct-4bit"]?.ownership, .evictable)
        XCTAssertEqual(byRepo[EmbedderModel.id]?.ownership, .embedder)
        XCTAssertEqual(byRepo["someone/other-model"]?.ownership, .foreign)
        XCTAssertEqual(byRepo[configured]?.bytes, 400)
    }

    func test_only_the_apps_other_preset_models_are_evictable() throws {
        try writeHub()
        var stats = StorageStats()
        stats.models = StorageScanner.models(in: root.appendingPathComponent("hub"), activeModelID: configured)
        XCTAssertEqual(stats.evictableModelBytes, 100)
        XCTAssertEqual(stats.modelCacheBytes, 400 + 100 + 241 + 900)
        XCTAssertEqual(stats.foreignModelBytes, 900)
    }

    func test_a_config_spelled_in_another_case_still_marks_the_cached_model_in_use() throws {
        try write("hub/models--mlx-community--Qwen2.5-7B-Instruct-4bit/blobs/x", bytes: 10)
        let models = StorageScanner.models(
            in: root.appendingPathComponent("hub"), activeModelID: "mlx-community/qwen2.5-7b-instruct-4bit"
        )
        XCTAssertEqual(models.first?.ownership, .inUse, "a model in use must never read as deletable over a case difference")
    }

    @MainActor
    func test_a_switch_to_a_cached_preset_since_the_scan_is_not_evicted() async throws {
        try writeHub()
        let hub = root.appendingPathComponent("hub")
        let config = ConfigStore(configURL: root.appendingPathComponent("config.toml"))
        config.outputDirPath = root.appendingPathComponent("library").path
        let store = StorageStatsStore(
            configStore: config,
            workflowStore: WorkflowStore(directory: root.appendingPathComponent("workflows", isDirectory: true)),
            hubRoot: hub
        )
        await store.rescan()  // 3B is evictable here
        config.summarizationLocalModel = "mlx-community/Qwen2.5-3B-Instruct-4bit"  // switched before the click
        await store.evictUnusedModels()
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: hub.appendingPathComponent("models--mlx-community--Qwen2.5-3B-Instruct-4bit").path),
            "the model that is configured now survives a stale scan")
    }

    func test_the_confirm_has_a_sentence_for_nothing_left() {
        XCTAssertFalse(ModelEviction.confirmMessage(for: []).contains("deletes ,"))
    }

    func test_a_configured_custom_model_is_in_use_and_not_evictable() throws {
        try write("hub/models--me--custom-model/blobs/x", bytes: 50)
        let models = StorageScanner.models(in: root.appendingPathComponent("hub"), activeModelID: "me/custom-model")
        XCTAssertEqual(models.first?.ownership, .inUse)
    }

    func test_the_embedder_id_matches_the_pipeline_default() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("pipeline/src/mp/embed_index.py"), encoding: .utf8)
        let match = source.range(of: #"DEFAULT_EMBED_MODEL\s*=\s*"([^"]+)""#, options: .regularExpression)
        let line = try XCTUnwrap(match.map { String(source[$0]) })
        XCTAssertTrue(line.contains("\"\(EmbedderModel.id)\""),
                      "EmbedderModel.id drifted from embed_index.DEFAULT_EMBED_MODEL: \(line). Change both together (STOR15).")
    }

    func test_the_confirm_names_each_repo_it_will_delete_and_leaves_the_rest_alone() throws {
        try writeHub()
        try write("hub/models--mlx-community--Qwen2.5-14B-Instruct-4bit/blobs/x", bytes: 300)
        let models = StorageScanner.models(in: root.appendingPathComponent("hub"), activeModelID: configured)
        let message = ModelEviction.confirmMessage(for: models.filter { $0.ownership == .evictable })
        XCTAssertTrue(message.contains("mlx-community/Qwen2.5-3B-Instruct-4bit"))
        XCTAssertTrue(message.contains("mlx-community/Qwen2.5-14B-Instruct-4bit"))
        XCTAssertFalse(message.contains("someone/other-model"))
        XCTAssertFalse(message.contains(EmbedderModel.id))
        XCTAssertFalse(message.contains(configured))
        XCTAssertTrue(message.localizedCaseInsensitiveContains("other tools"))
        XCTAssertTrue(message.localizedCaseInsensitiveContains("search"))
    }

    @MainActor
    func test_evicting_deletes_only_the_evictable_repo() async throws {
        try writeHub()
        let hub = root.appendingPathComponent("hub")
        let config = ConfigStore(configURL: root.appendingPathComponent("config.toml"))
        // Hermetic: the default library path is the owner's real, synced one.
        config.outputDirPath = root.appendingPathComponent("library").path
        let store = StorageStatsStore(
            configStore: config,
            workflowStore: WorkflowStore(directory: root.appendingPathComponent("workflows", isDirectory: true)),
            hubRoot: hub
        )
        await store.rescan()
        XCTAssertEqual(store.stats?.evictableModelBytes, 100)
        let message = ModelEviction.confirmMessage(for: store.stats?.evictableModels ?? [])
        XCTAssertTrue(message.contains("mlx-community/Qwen2.5-3B-Instruct-4bit"), "the dialog names what the store will delete")
        await store.evictUnusedModels()
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: hub.appendingPathComponent("models--mlx-community--Qwen2.5-3B-Instruct-4bit").path))
        XCTAssertTrue(fm.fileExists(atPath: hub.appendingPathComponent("models--mlx-community--Qwen2.5-7B-Instruct-4bit").path), "the configured model")
        XCTAssertTrue(fm.fileExists(atPath: hub.appendingPathComponent("models--mlx-community--multilingual-e5-small-mlx").path), "the search embedder")
        XCTAssertTrue(fm.fileExists(atPath: hub.appendingPathComponent("models--someone--other-model").path), "another tool's model")
    }

    /// STOR7 (SW-18): `models_evicted` logged every candidate's bytes as freed before removing
    /// anything. A directory that will not go is now reported as failed and its bytes excluded.
    @MainActor
    func test_a_failed_eviction_is_counted_and_its_bytes_are_not_reported_freed() async throws {
        try writeHub()
        let hub = root.appendingPathComponent("hub")
        let logs = root.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        setenv("MEETINGPIPE_LOGS_DIR", logs.path, 1)
        defer { unsetenv("MEETINGPIPE_LOGS_DIR") }
        let config = ConfigStore(configURL: root.appendingPathComponent("config.toml"))
        config.outputDirPath = root.appendingPathComponent("library").path
        let store = StorageStatsStore(
            configStore: config,
            workflowStore: WorkflowStore(directory: root.appendingPathComponent("workflows", isDirectory: true)),
            hubRoot: hub
        )
        await store.rescan()
        let blobs = hub.appendingPathComponent("models--mlx-community--Qwen2.5-3B-Instruct-4bit/blobs")
        XCTAssertEqual(chmod(blobs.path, 0o500), 0)
        defer { chmod(blobs.path, 0o700) }

        await store.evictUnusedModels()

        let rows = try String(contentsOf: logs.appendingPathComponent("events.jsonl"), encoding: .utf8)
            .split(separator: "\n")
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        let row = try XCTUnwrap(rows.last { $0["action"] as? String == "models_evicted" })
        XCTAssertEqual(row["count"] as? Int, 0)
        XCTAssertEqual(row["bytes_freed"] as? Int, 0)
        XCTAssertEqual(row["failed"] as? Int, 1)
    }

    func test_repoID_unsanitizes_the_hub_directory_name() {
        XCTAssertEqual(
            StorageScanner.repoID(fromDirectoryName: "models--mlx-community--Qwen2.5-7B"),
            "mlx-community/Qwen2.5-7B"
        )
    }
}
