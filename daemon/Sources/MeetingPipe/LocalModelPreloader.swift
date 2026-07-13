import Foundation

/// Optionally starts a persistent `mlx_lm.server` at app launch so the first
/// local-backend summary skips the model cold-start (TECH-A15). Owned by the
/// AppDelegate: `start(...)` spawns `mp serve-local` (which execs the server)
/// when the user opted in, the summarization backend is `local`, and the model
/// is already cached; `stop()` terminates it on app quit so a multi-GB process
/// is not leaked. Off by default because a warm model stays resident in RAM.
///
/// Reuse, not duplication: `LocalSummaryClient._ensure_running` health-checks
/// the endpoint before spawning, so a later `mp run-all` / `mp summarize`
/// reuses this warm server instead of starting its own, and (because it did not
/// spawn it) never shuts it down on idle.
final class LocalModelPreloader {

    private var process: Process?

    /// Pure gating decision, isolated for unit testing.
    ///
    /// Preload only when all hold:
    /// - the user opted in (`enabled`);
    /// - the backend is `local` (warming a model that the `auto` / `anthropic`
    ///   paths may never use would waste RAM);
    /// - the model is already on disk (`modelCached`) - otherwise the server
    ///   would block on or trigger a multi-GB download at launch; that download
    ///   stays owned by `ModelDownloadSupervisor`.
    static func shouldPreload(enabled: Bool, backend: String, modelCached: Bool) -> Bool {
        enabled && backend == "local" && modelCached
    }

    /// Spawn `mp serve-local` when gating passes. Idempotent: a running
    /// preloader is left in place.
    func start(enabled: Bool, backend: String, localModel: String) {
        if process?.isRunning == true { return }
        guard Self.shouldPreload(
            enabled: enabled,
            backend: backend,
            modelCached: ModelDownloadSupervisor.isCached(modelId: localModel)
        ) else { return }
        guard let mp = PipelineLauncher.findMP() else {
            Log.main.warning("local model preload: no `mp` binary found; skipping")
            return
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: mp.shell)
        p.arguments = mp.args + ["serve-local"]
        // SEC13/SEC5: the warm server is a local model server; it never speaks to a
        // cloud sink, so withhold both managed tokens rather than leak them into a
        // process that has no use for them (`mp serve-local` also declines to reload
        // them, and arms the egress guard under a regulated run).
        p.environment = PipelineLauncher.freshEnvironment(stripAnthropicKey: true, stripNotionToken: true)
        // The warm server runs for the daemon's lifetime; its own logs are not
        // useful in the daemon log, and a readabilityHandler on a long-lived
        // process would outlive the spawn. Discard both streams.
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice

        do {
            try p.run()
            process = p
            Log.main.info("local model preload: started mlx_lm.server for \(localModel)")
            Log.event(category: "main", action: "local_model_preload_started", attributes: [
                "model": localModel,
            ])
        } catch {
            Log.main.warning("local model preload: spawn failed: \(error.localizedDescription)")
        }
    }

    /// Terminate the warm server. Called on app quit so the resident model is freed.
    func stop() {
        guard let p = process else { return }
        process = nil
        guard p.isRunning else { return }
        p.terminate()
        Log.event(category: "main", action: "local_model_preload_stopped", attributes: [:])
    }
}
