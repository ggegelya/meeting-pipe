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
    /// `LibraryMover.execute`, injectable so a test can see whether it ran (STOR16).
    typealias MoveExecutor = @Sendable (_ plan: LibraryMover.Plan) throws -> Void
    /// The file-heuristic fallback re-checked at execute (STOR16): work no owner reports.
    typealias InFlightCheck = @Sendable (_ source: URL) -> String?

    /// Where a confirmed move is going, from the moment `executeMove` starts until the post-move
    /// scan has published (UX105; STOR16 set the flag only around the executor and cleared it
    /// before the rescan). The Storage pane shows a progress row naming it.
    @Published private(set) var movingTo: URL?
    /// True while a confirmed move runs (STOR16, widened by UX105). Back up now and Restore are
    /// disabled meanwhile, and so are both root actions.
    var isMoving: Bool { movingTo != nil }
    let moveGuard: LibraryMoveGuard

    /// UX105: which cache a Clear or Evict unused is emptying, from the click until the scan
    /// taken after the delete has published. The row shows a spinner in place of its size and
    /// disables its button meanwhile, so the old size never sits beside a live button.
    enum CacheKind: Equatable { case waveformPeaks, unusedModels }
    @Published private(set) var clearingCache: CacheKind?

    /// Everything a scan reads, gathered on main and handed off main as one value.
    struct ScanInputs: Sendable {
        let libraryDir: URL
        let originalsDir: URL
        let waveformCacheDir: URL
        let hubRoot: URL
        let activeModelID: String
        let retentionByWorkflow: [UUID: RetentionPolicy]
        let defaultPolicy: RetentionPolicy?
    }
    /// `StorageScanner.scan`, injectable so a test can hold a scan in flight (UX105).
    typealias Scanner = @Sendable (ScanInputs) -> StorageStats
    /// Deletes the `.peaks` files in the waveform cache. Injectable for UX105's tests.
    typealias PeaksClearer = @Sendable (_ cacheDir: URL) -> Void
    /// Removes one evictable model directory. Injectable for UX105's tests.
    typealias ModelRemover = @Sendable (_ directory: URL) throws -> Void

    /// The scan running now, if any. A second `rescan()` waits on it rather than starting a
    /// parallel walk; `rescanAfterChange()` waits on it and then scans again.
    private var inFlightScan: Task<Void, Never>?

    private let workflowStore: WorkflowStore
    private let configStore: ConfigStore
    private let planner: MovePlanner
    private let executor: MoveExecutor
    private let inFlightCheck: InFlightCheck
    private let hubRoot: URL
    private let scanner: Scanner
    private let peaksClearer: PeaksClearer
    private let modelRemover: ModelRemover

    init(
        configStore: ConfigStore,
        workflowStore: WorkflowStore,
        planner: @escaping MovePlanner = { source, destination in
            try LibraryMover.plan(source: source, destinationParent: destination)
        },
        hubRoot: URL = StorageScanner.hubRoot(home: FileManager.default.homeDirectoryForCurrentUser),
        moveGuard: LibraryMoveGuard = LibraryMoveGuard(),
        executor: @escaping MoveExecutor = { plan in try LibraryMover.execute(plan) },
        inFlightCheck: @escaping InFlightCheck = { source in LibraryMover.inFlightReason(in: source) },
        scanner: @escaping Scanner = { inputs in
            StorageScanner.scan(
                libraryDir: inputs.libraryDir,
                originalsDir: inputs.originalsDir,
                waveformCacheDir: inputs.waveformCacheDir,
                hubRoot: inputs.hubRoot,
                activeModelID: inputs.activeModelID,
                retentionByWorkflow: inputs.retentionByWorkflow,
                defaultPolicy: inputs.defaultPolicy
            )
        },
        peaksClearer: @escaping PeaksClearer = { dir in
            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: []
            ) else { return }
            for url in entries where url.pathExtension == "peaks" {
                try? fm.removeItem(at: url)
            }
        },
        modelRemover: @escaping ModelRemover = { try FileManager.default.removeItem(at: $0) }
    ) {
        self.scanner = scanner
        self.peaksClearer = peaksClearer
        self.modelRemover = modelRemover
        self.hubRoot = hubRoot
        self.moveGuard = moveGuard
        self.executor = executor
        self.inFlightCheck = inFlightCheck
        self.configStore = configStore
        self.workflowStore = workflowStore
        self.planner = planner
    }

    var libraryURL: URL {
        URL(fileURLWithPath: (configStore.outputDirPath as NSString).expandingTildeInPath)
    }

    /// Take a fresh reading. While a scan is already running this waits for it rather than
    /// starting a second walk, which is what the pane's `.task` and Rescan want; a caller that has
    /// just changed the disk wants `rescanAfterChange()` instead.
    func rescan() async {
        if let running = inFlightScan {
            await running.value
            return
        }
        let task = Task { await self.performScan() }
        inFlightScan = task
        await task.value
    }

    /// A scan that starts after the caller's change, even when one was already in flight (UX105).
    /// The running scan may have measured the disk before the delete or the move, and `rescan()`
    /// used to return at `guard !isScanning`, which left the pre-clear size on screen.
    func rescanAfterChange() async {
        if let running = inFlightScan { await running.value }
        await rescan()
    }

    private func performScan() async {
        isScanning = true
        // Cleared here, inside the task, so no waiter resuming later can clear a newer scan's handle.
        defer {
            isScanning = false
            inFlightScan = nil
        }

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
        let inputs = ScanInputs(
            libraryDir: libraryDir, originalsDir: originalsDir, waveformCacheDir: waveformCacheDir,
            hubRoot: hubRoot, activeModelID: activeModelID,
            retentionByWorkflow: retention, defaultPolicy: defaultPolicy
        )
        let scanner = self.scanner
        stats = await Task.detached(priority: .userInitiated) { scanner(inputs) }.value
    }

    /// Delete the waveform peaks cache. Rebuildable: the next time a meeting's
    /// Audio tab opens, its peaks are recomputed from the recording.
    func clearWaveformCache() async {
        guard clearingCache == nil else { return }
        clearingCache = .waveformPeaks
        defer { clearingCache = nil }
        let dir = WaveformPeaksLoader.cacheDirectory()
        let clearer = peaksClearer
        await Task.detached(priority: .userInitiated) { clearer(dir) }.value
        Log.event(category: "coordinator", action: "waveform_cache_cleared", attributes: [:])
        await rescanAfterChange()
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
            !evictable.isEmpty, clearingCache == nil else { return }
        clearingCache = .unusedModels
        defer { clearingCache = nil }
        let remover = modelRemover
        let candidates = evictable.map { (directory: $0.directory, bytes: $0.bytes) }
        // STOR7 (SW-18): count what was actually removed. This logged every candidate's bytes as
        // freed before any removal, over a `try?` loop.
        let removed: [(directory: URL, bytes: Int)] = await Task.detached(priority: .userInitiated) {
            candidates.filter { candidate in
                do {
                    try remover(candidate.directory)
                    return true
                } catch {
                    Log.failure(category: "coordinator", action: "model_evict_failed", error: error, describe: false)
                    return false
                }
            }
        }.value
        Log.event(category: "coordinator", action: "models_evicted", attributes: [
            "count": removed.count,
            "bytes_freed": removed.reduce(0) { $0 + $1.bytes },
            "failed": candidates.count - removed.count,
        ])
        await rescanAfterChange()
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
        // STOR16: the owners first, so a busy library never gets as far as a confirmation.
        if let reason = moveGuard.currentBusyReason {
            moveError = LibraryMover.MoveError.busy(reason).localizedDescription
            return
        }
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
        // UX105: busy from here, the execute-time check included, until the scan after the move
        // has published, so Move library is never live again while the pane still shows the old root.
        movingTo = plan.destination
        defer { movingTo = nil }
        // STOR16: the plan's check ran when the dialog opened, and the dialog waits for as long as
        // the owner does. Re-check now: the files first (off main, the fallback for work nothing
        // owns), then the owners and the claim in one main-actor turn, so nothing can start a
        // recording or a job between the answer and the move.
        let source = plan.source
        let inFlightCheck = self.inFlightCheck
        let fileReason = await Task.detached(priority: .userInitiated) { inFlightCheck(source) }.value
        if let reason = fileReason ?? moveGuard.begin() {
            moveError = LibraryMover.MoveError.busy(reason).localizedDescription
            return
        }
        let executor = self.executor
        do {
            try await Task.detached(priority: .userInitiated) {
                try executor(plan)
            }.value
            LibraryRootChange.pointAt(plan.destination, configStore: configStore)
            moveError = nil
        } catch {
            moveError = error.localizedDescription
        }
        moveGuard.end()
        await rescanAfterChange()
    }

    /// **Use another folder…** (UX89): check, then hold the pick for confirmation. Refused while a
    /// recording or a pipeline job is in flight, for the same reason a move is: either one is
    /// writing into the current root, and the rest of its life would look in the new one.
    func requestSwitch(to folder: URL) async {
        moveError = nil
        pendingSwitch = nil
        let source = libraryURL
        let inFlightCheck = self.inFlightCheck
        let fileReason = await Task.detached(priority: .userInitiated) {
            inFlightCheck(source)
        }.value
        if let reason = fileReason ?? moveGuard.currentBusyReason {
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
        // STOR16: the confirmation may have waited; ask the owners again before re-pointing.
        if let reason = moveGuard.currentBusyReason {
            moveError = LibraryMover.MoveError.busy(reason).localizedDescription
            return
        }
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
