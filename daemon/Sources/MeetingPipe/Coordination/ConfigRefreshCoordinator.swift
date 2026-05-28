import Combine
import Foundation

/// Owns the daemon's response to configuration changes: the eager
/// local-model prefetch, the model-download status surface, and the
/// regulated-mode glyph. Subscribes to `ConfigStore.didPersist` (already
/// debounced 500 ms) so a Preferences save refreshes the affected
/// surfaces without a daemon restart.
///
/// Lifted out of `Coordinator` (TECH-H1-FINISH). The model-download and
/// regulated-mode side effects are pushed back to the status bar via
/// injected closures rather than a direct StatusBarController reference,
/// so the type composes cleanly and is unit-testable. None of this path
/// emits `Log.event` entries (the supervisor logs to the text log only),
/// so the events.jsonl trace is unchanged by the extraction.
///
/// Threading: `start()` and the persistence sink run on the main queue.
final class ConfigRefreshCoordinator {

    /// Pure decision for the model-prefetch branch: given the persisted
    /// backend and local-model id, what the supervisor should do.
    /// Extracted so the branching is testable without spawning a
    /// subprocess.
    enum PrefetchAction: Equatable {
        case ensure(modelId: String)
        case cancelAndIdle
        case noop
    }

    static func prefetchDecision(backend: String, modelId: String) -> PrefetchAction {
        // Non-local/auto backends (e.g. anthropic) cancel any in-flight prefetch.
        guard backend == "local" || backend == "auto" else { return .cancelAndIdle }
        guard !modelId.isEmpty else { return .noop }
        return .ensure(modelId: modelId)
    }

    private let configStore: ConfigStore?
    private let modelDownload: ModelDownloadSupervisor
    private let onModelDownloadState: (ModelDownloadSupervisor.State) -> Void
    private let onRegulatedMode: (Bool) -> Void
    private var configCancellable: AnyCancellable?

    init(
        configStore: ConfigStore?,
        modelDownload: ModelDownloadSupervisor = ModelDownloadSupervisor(),
        onModelDownloadState: @escaping (ModelDownloadSupervisor.State) -> Void,
        onRegulatedMode: @escaping (Bool) -> Void
    ) {
        self.configStore = configStore
        self.modelDownload = modelDownload
        self.onModelDownloadState = onModelDownloadState
        self.onRegulatedMode = onRegulatedMode
    }

    /// Wire the supervisor's state callback, seed the regulated-mode glyph
    /// and an eager prefetch, then subscribe to config persistence. Call
    /// once from `Coordinator.start()`.
    func start() {
        // Wired once so we don't re-subscribe if the supervisor restarts.
        modelDownload.onStateChange = { [weak self] state in
            self?.onModelDownloadState(state)
        }
        // Seed glyph at boot so the lock icon shows before the first config save.
        onRegulatedMode(configStore?.regulatedMode ?? false)
        // Eager prefetch on launch; no-op for backend=anthropic (typical first install).
        ensureModelPrefetchIfNeeded()
        // ConfigStore already debounces 500 ms, so rebuilds don't pile up while a slider is dragged.
        configCancellable = configStore?.didPersist
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.handleConfigPersisted() }
    }

    private func handleConfigPersisted() {
        ensureModelPrefetchIfNeeded()
        onRegulatedMode(configStore?.regulatedMode ?? false)
    }

    /// Spawn (or skip) a background `mp prefetch-model`. Idempotent; the supervisor short-circuits when the model is already cached or downloading.
    func ensureModelPrefetchIfNeeded() {
        guard let store = configStore else { return }
        switch Self.prefetchDecision(
            backend: store.summarizationBackend,
            modelId: store.summarizationLocalModel
        ) {
        case .cancelAndIdle:
            modelDownload.cancel()
            onModelDownloadState(.idle)
        case .ensure(let modelId):
            modelDownload.ensure(modelId: modelId)
        case .noop:
            break
        }
    }
}
