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
    /// True while a move plan is being measured (PERF13). The Move library button is disabled
    /// meanwhile, so a second pick cannot start a second walk of the library.
    @Published private(set) var isPlanningMove = false
    /// UX89: a folder the user picked under **Use another folder…**, waiting on the confirmation
    /// that says the current library stays where it is. Nothing is written until `confirmSwitch()`.
    @Published private(set) var pendingSwitch: URL?
    /// A measured move waiting on its confirmation. Here rather than on a view since UX89, because
    /// the Recording and Storage panes both offer **Move library…** over one store.
    @Published var pendingMove: LibraryMover.Plan?

    /// `LibraryMover.plan`, injectable so a test can see which thread runs it.
    typealias MovePlanner = @Sendable (_ source: URL, _ destinationParent: URL) throws -> LibraryMover.Plan

    private let workflowStore: WorkflowStore
    private let configStore: ConfigStore
    private let planner: MovePlanner
    private let hubRoot: URL

    init(
        configStore: ConfigStore,
        workflowStore: WorkflowStore,
        planner: @escaping MovePlanner = { source, destination in
            try LibraryMover.plan(source: source, destinationParent: destination)
        },
        hubRoot: URL = StorageScanner.hubRoot(home: FileManager.default.homeDirectoryForCurrentUser)
    ) {
        self.hubRoot = hubRoot
        self.configStore = configStore
        self.workflowStore = workflowStore
        self.planner = planner
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
        let hubRoot = self.hubRoot
        let activeModelID = configStore.summarizationLocalModel
        let retention = Dictionary(
            uniqueKeysWithValues: workflowStore.workflows.map { ($0.id, $0.retention.policy) }
        )
        let defaultPolicy = workflowStore.defaultWorkflow?.retention.policy

        stats = await Task.detached(priority: .userInitiated) {
            StorageScanner.scan(
                libraryDir: libraryDir,
                originalsDir: originalsDir,
                waveformCacheDir: waveformCacheDir,
                hubRoot: hubRoot,
                activeModelID: activeModelID,
                retentionByWorkflow: retention,
                defaultPolicy: defaultPolicy
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

    /// Delete the app's own preset models the config no longer points at (STOR15). Never the
    /// configured model, the search embedder, or another tool's model in the shared hub.
    /// Re-downloadable via `mp prefetch-model`, which the daemon already spawns
    /// when a chosen model is not cached.
    func evictUnusedModels() async {
        // Ownership was decided at the last scan. Re-check against the config as it is now, so a
        // switch to an already-cached preset (or a hand edit UX96 reloads live) since that scan
        // cannot delete the model that is in use.
        let nowConfigured = StorageScanner.hubDirectoryName(forRepo: configStore.summarizationLocalModel)
        guard let evictable = stats?.evictableModels
            .filter({ $0.directory.lastPathComponent.caseInsensitiveCompare(nowConfigured) != .orderedSame }),
            !evictable.isEmpty else { return }
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
    ///
    /// PERF13: off main, like `rescan()` and `executeMove(_:)`. `LibraryMover.plan` runs the
    /// in-flight check, the cloud-sync detection and an enumerator over every file in the
    /// library, which at tens of thousands of files (longer with iCloud-evicted ones) was a
    /// beachball straight after the folder picker. Returns nil, planning nothing, while a plan
    /// is already being measured.
    func planMove(to destinationParent: URL) async -> LibraryMover.Plan? {
        guard !isPlanningMove else { return nil }
        isPlanningMove = true
        defer { isPlanningMove = false }
        moveError = nil
        let source = libraryURL
        let planner = self.planner
        let result = await Task.detached(priority: .userInitiated) {
            Result { try planner(source, destinationParent) }
        }.value
        switch result {
        case .success(let plan):
            return plan
        case .failure(let error):
            moveError = error.localizedDescription
            return nil
        }
    }

    /// Plan a move to `destinationParent` and hold it for the confirmation dialog.
    func requestMove(to destinationParent: URL) async {
        pendingSwitch = nil
        if let plan = await planMove(to: destinationParent) { pendingMove = plan }
    }

    /// Execute a confirmed plan, then repoint `[recording] output_dir` at the new
    /// root. Config comes last: if the move fails, the daemon keeps writing where
    /// the recordings still are. A settings file that cannot be written refuses the move
    /// up front (UX89): a library moved with no config to follow it is a library nothing finds.
    func executeMove(_ plan: LibraryMover.Plan) async {
        if configStore.parseError != nil {
            moveError = LibraryRootChange.unwritableConfig
            return
        }
        do {
            try await Task.detached(priority: .userInitiated) {
                try LibraryMover.execute(plan)
            }.value
            LibraryRootChange.pointAt(plan.destination, configStore: configStore)
            moveError = nil
        } catch {
            moveError = error.localizedDescription
        }
        await rescan()
    }

    /// **Use another folder…** (UX89): check, then hold the pick for confirmation. Refused while a
    /// recording or a pipeline job is in flight, for the same reason a move is: either one is
    /// writing into the current root, and the rest of its life would look in the new one.
    func requestSwitch(to folder: URL) async {
        moveError = nil
        pendingSwitch = nil
        let source = libraryURL
        let reason = await Task.detached(priority: .userInitiated) {
            LibraryMover.inFlightReason(in: source)
        }.value
        if let reason {
            moveError = LibraryMover.MoveError.busy(reason).localizedDescription
            return
        }
        if folder.standardizedFileURL == source.standardizedFileURL {
            moveError = "That is already the recordings folder."
            return
        }
        pendingSwitch = folder
    }

    /// The confirmation's accept. The only place a switch writes `output_dir`.
    func confirmSwitch() async {
        guard let folder = pendingSwitch else { return }
        pendingSwitch = nil
        LibraryRootChange.pointAt(folder, configStore: configStore)
        await rescan()
    }

    func cancelSwitch() {
        pendingSwitch = nil
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

/// The one write of a changed library root (UX89). Saved at once rather than on the 0.5 s debounce:
/// after a completed move, a quit inside the debounce would relaunch onto a root that no longer exists.
@MainActor
enum LibraryRootChange {
    static let unwritableConfig =
        "Can't change the recordings folder: the settings file could not be read, so the change could not be saved."

    static func pointAt(_ folder: URL, configStore: ConfigStore) {
        configStore.outputDirPath = folder.path
        do {
            try configStore.saveNow()
        } catch {
            Log.writeLine("daemon", "WARN: library root changed but config.toml was not saved: \(error.localizedDescription)")
        }
    }
}
