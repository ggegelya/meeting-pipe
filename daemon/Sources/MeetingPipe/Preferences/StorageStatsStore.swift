import Foundation
import SwiftUI

/// Drives the Preferences Storage section (STOR1). Shaped like `DoctorRunner`: a
/// main-actor `ObservableObject` whose one job is to hop expensive work onto a
/// detached task and publish the result. Scanning a library can walk thousands of
/// files, so it never happens on the main queue.
@MainActor
final class StorageStatsStore: ObservableObject {
    @Published private(set) var stats: StorageStats?
    @Published private(set) var isScanning = false
    /// The cloud-sync client that owns the library, if any (SEC12). Refreshed on
    /// every scan, so it follows an assisted move without a restart.
    @Published private(set) var syncProvider: CloudSyncDetector.SyncProvider?
    /// True when this Mac promises zero egress (regulated mode, or any NDA
    /// workflow), which turns a synced library from a warning into a contradiction.
    @Published private(set) var promisesZeroEgress = false
    @Published var moveError: String?

    private let workflowStore: WorkflowStore
    private let configStore: ConfigStore

    init(configStore: ConfigStore, workflowStore: WorkflowStore) {
        self.configStore = configStore
        self.workflowStore = workflowStore
    }

    var libraryURL: URL {
        URL(fileURLWithPath: (configStore.outputDirPath as NSString).expandingTildeInPath)
    }

    func rescan() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        let libraryDir = libraryURL
        promisesZeroEgress = configStore.regulatedMode
            || workflowStore.workflows.contains { $0.flags.ndaMode }
        syncProvider = await Task.detached(priority: .userInitiated) {
            CloudSyncDetector.detect(path: libraryDir)
        }.value
        let originalsDir = MuteRedactor.originalsDirectory()
        let waveformCacheDir = WaveformPeaksLoader.cacheDirectory()
        let hubRoot = StorageScanner.hubRoot(home: FileManager.default.homeDirectoryForCurrentUser)
        let activeModelID = configStore.summarizationLocalModel
        let retention = Dictionary(
            uniqueKeysWithValues: workflowStore.workflows.map { ($0.id, $0.retention.policy) }
        )

        stats = await Task.detached(priority: .userInitiated) {
            StorageScanner.scan(
                libraryDir: libraryDir,
                originalsDir: originalsDir,
                waveformCacheDir: waveformCacheDir,
                hubRoot: hubRoot,
                activeModelID: activeModelID,
                retentionByWorkflow: retention
            )
        }.value
    }

    /// Delete the waveform peaks cache. Rebuildable: the next time a meeting's
    /// Audio tab opens, its peaks are recomputed from the recording.
    func clearWaveformCache() async {
        let dir = WaveformPeaksLoader.cacheDirectory()
        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: []
            ) else { return }
            for url in entries where url.pathExtension == "peaks" {
                try? fm.removeItem(at: url)
            }
        }.value
        Log.event(category: "coordinator", action: "waveform_cache_cleared", attributes: [:])
        await rescan()
    }

    /// Delete every HuggingFace hub entry the current config does not point at.
    /// Re-downloadable via `mp prefetch-model`, which the daemon already spawns
    /// when a chosen model is not cached.
    func evictUnusedModels() async {
        guard let evictable = stats?.models.filter({ !$0.inUse }), !evictable.isEmpty else { return }
        let directories = evictable.map(\.directory)
        let bytes = evictable.reduce(0) { $0 + $1.bytes }
        await Task.detached(priority: .userInitiated) {
            for dir in directories {
                try? FileManager.default.removeItem(at: dir)
            }
        }.value
        Log.event(category: "coordinator", action: "models_evicted", attributes: [
            "count": directories.count,
            "bytes_freed": bytes,
        ])
        await rescan()
    }

    /// Build the move plan for a user-chosen destination, or surface why not.
    /// Never moves anything: the caller confirms the returned plan first.
    func planMove(to destinationParent: URL) -> LibraryMover.Plan? {
        do {
            moveError = nil
            return try LibraryMover.plan(source: libraryURL, destinationParent: destinationParent)
        } catch {
            moveError = error.localizedDescription
            return nil
        }
    }

    /// Execute a confirmed plan, then repoint `[recording] output_dir` at the new
    /// root. Config comes last: if the move fails, the daemon keeps writing where
    /// the recordings still are.
    func executeMove(_ plan: LibraryMover.Plan) async {
        do {
            try await Task.detached(priority: .userInitiated) {
                try LibraryMover.execute(plan)
            }.value
            configStore.outputDirPath = plan.destination.path
            moveError = nil
        } catch {
            moveError = error.localizedDescription
        }
        await rescan()
    }

    /// `ByteCountFormatter`, matching the Raw files tab's readout so two surfaces
    /// never disagree on what "1.2 GB" means.
    static func format(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
