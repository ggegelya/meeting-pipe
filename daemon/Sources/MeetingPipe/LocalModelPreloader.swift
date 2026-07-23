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
///
/// That reuse is also why `refresh(...)` exists (LOCAL11). The warm server pins
/// one model and one adapter for the daemon's whole lifetime, so before LOCAL11 a
/// Preferences change to either one left the *old* weights answering every
/// summary until the app was quit, with nothing on screen saying so. Python
/// detects the mismatch and reports what really served, but it deliberately will
/// not kill a server it did not spawn: this type owns that one, so restarting it
/// on a config save is the fix.
final class LocalModelPreloader {

    /// What a warm server is serving. `nil` desired identity means "nothing should
    /// be running" (opted out, non-local backend, or model not cached yet).
    struct Identity: Equatable {
        var backend: String
        var model: String
        var adapterPath: String
    }

    /// What a config change should do to the preloader, given what is running.
    enum Action: Equatable {
        case noop
        case start
        case stop
        case restart
    }

    private var process: Process?
    /// The identity the running process was started with, so a later refresh can
    /// tell a real change from a save that touched some unrelated key. `nil`
    /// whenever nothing is running.
    private var runningIdentity: Identity?

    /// A terminated server needs a moment to release the port before its
    /// replacement can bind it. We never block the main thread waiting (that is
    /// the freeze class the audio and AX paths already learned), so the restart is
    /// a delayed hop instead. If the rebind still loses the race the warm path is
    /// simply cold until the next launch: `LocalSummaryClient` spawns its own
    /// correctly-identified server, so the failure mode is latency, never wrong
    /// weights.
    static let restartSettleSeconds: TimeInterval = 2.0

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

    /// Pure: what to do when the desired identity meets the running one (LOCAL11).
    /// Kept separate from the gating above so "should anything run" and "is what
    /// runs still right" stay independently testable.
    static func decide(running: Identity?, desired: Identity?) -> Action {
        switch (running, desired) {
        case (nil, nil): return .noop
        case (nil, .some): return .start
        case (.some, nil): return .stop
        case let (.some(r), .some(d)): return r == d ? .noop : .restart
        }
    }

    /// Spawn `mp serve-local` when gating passes. Idempotent: a running
    /// preloader is left in place.
    func start(enabled: Bool, backend: String, localModel: String, adapterPath: String = "") {
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
            // `mp serve-local` reads the same config we just read, so this is what
            // it will exec into; Python re-reads the truth from the server's argv.
            runningIdentity = Identity(backend: backend, model: localModel, adapterPath: adapterPath)
            Log.main.info("local model preload: started mlx_lm.server for \(localModel)")
            Log.event(category: "main", action: "local_model_preload_started", attributes: [
                "model": localModel,
                "adapter_path": adapterPath,
            ])
        } catch {
            Log.main.warning("local model preload: spawn failed: \(error.localizedDescription)")
        }
    }

    /// Re-evaluate against the persisted config and act on a real change (LOCAL11).
    /// Wired to `ConfigStore.didPersist`, which already debounces 500 ms, so a
    /// slider drag in Preferences cannot thrash a multi-GB model load. A save that
    /// leaves the local identity alone is a no-op.
    func refresh(enabled: Bool, backend: String, localModel: String, adapterPath: String) {
        let desired: Identity? = Self.shouldPreload(
            enabled: enabled,
            backend: backend,
            modelCached: ModelDownloadSupervisor.isCached(modelId: localModel)
        ) ? Identity(backend: backend, model: localModel, adapterPath: adapterPath) : nil

        switch Self.decide(running: runningIdentity, desired: desired) {
        case .noop:
            return
        case .start:
            start(enabled: enabled, backend: backend, localModel: localModel, adapterPath: adapterPath)
        case .stop:
            Log.main.info("local model preload: config no longer wants a warm server; stopping")
            stop()
        case .restart:
            Log.main.info("local model preload: config changed to \(localModel); restarting warm server")
            Log.event(category: "main", action: "local_model_preload_restarted", attributes: [
                "model": localModel,
                "adapter_path": adapterPath,
            ])
            stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.restartSettleSeconds) { [weak self] in
                self?.start(
                    enabled: enabled, backend: backend,
                    localModel: localModel, adapterPath: adapterPath
                )
            }
        }
    }

    /// Terminate the warm server. Called on app quit so the resident model is freed.
    func stop() {
        guard let p = process else { return }
        process = nil
        runningIdentity = nil
        guard p.isRunning else { return }
        p.terminate()
        Log.event(category: "main", action: "local_model_preload_stopped", attributes: [:])
    }
}
