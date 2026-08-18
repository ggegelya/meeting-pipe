import Foundation

/// Owns the lifecycle of a `mp prefetch-model` subprocess and surfaces download progress to the Coordinator -> StatusBar.
/// `ensure(modelId:)` is the only entry point - idempotent, cancels any in-flight download for a different model. Short-circuits without spawning if the model is already fully cached (completeness-verified, not merely non-empty - LOCAL1/AUD-20), avoiding 0.5-1 s of fork/import latency on the happy path. Stdout is the live JSON-lines event channel; stderr goes to the daemon log.
/// Threading: every public method must run on the main queue; the stdout reader hops back to main before invoking callbacks.
final class ModelDownloadSupervisor {

    enum State: Equatable {
        case idle
        /// 0.0..1.0 when total_bytes is known, otherwise nil.
        case downloading(modelId: String, progress: Double?, downloadedBytes: Int64, totalBytes: Int64)
        case completed(modelId: String)
        case failed(modelId: String, error: String)
    }

    /// Called on the main queue on every state change; Coordinator uses this to rebuild the menu-bar title and menu.
    var onStateChange: ((State) -> Void)?

    /// LOCAL20: what a terminating prefetch is allowed to do, decided with explicit inputs so the
    /// reported defect is a test rather than a subprocess.
    ///
    /// The owner switched away from a local model mid-download and got a failure banner they could
    /// not dismiss. Their log settles what happened: `rc=15` is SIGTERM, which is exactly what
    /// `cancel()` sends, so nothing failed. `cancel()` cleared `process` but left `state` at
    /// `.downloading`, and the termination handler tested only that state and the non-zero status,
    /// so it manufactured a failure out of the user's own switch, about 99 seconds later.
    enum TerminationOutcome: Equatable {
        /// Not the process being tracked, so an abandoned prefetch from a `cancel()` or from
        /// `ensure`'s replace. It writes nothing at all. That last part matters as much as the
        /// state: the handler also nils `process`, `stdoutHandle` and `currentModelId`, so an
        /// abandoned termination arriving after a replacement had spawned used to tear down the
        /// *live* download on its way past.
        case ignore
        /// Tracked, and it really did fail.
        case fail(modelId: String, error: String)
        /// Tracked, and either it exited cleanly or a stdout event already wrote the terminal state.
        case keep
    }

    static func terminationOutcome(
        isTrackedProcess: Bool,
        state: State,
        terminationStatus: Int32
    ) -> TerminationOutcome {
        guard isTrackedProcess else { return .ignore }
        // Still `.downloading` means no stdout event reported a terminal state, so a non-zero exit
        // is the only evidence there is and it is a real failure.
        if case .downloading(let modelId, _, _, _) = state, terminationStatus != 0 {
            return .fail(modelId: modelId, error: "prefetch exited \(terminationStatus)")
        }
        return .keep
    }

    private(set) var state: State = .idle {
        didSet {
            if oldValue != state {
                onStateChange?(state)
            }
        }
    }

    /// The starting state is injectable (LOCAL20) so a test can begin from a `.failed` that a real
    /// run needs a network failure to reach. Defaulted, so no call site changes.
    init(state: State = .idle) {
        self.state = state
    }

    private var process: Process?
    private var stdoutHandle: FileHandle?
    private var stdoutBuffer = Data()
    private var currentModelId: String?

    /// Is `modelId` fully present in the local HuggingFace cache
    /// (`~/.cache/huggingface/hub/models--<repo>/`)? Verifies completeness
    /// without a network call, so the happy-path short-circuit in `ensure`
    /// stays fast and offline-safe.
    static func isCached(modelId: String) -> Bool {
        let hubRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
        return isComplete(modelId: modelId, hubRoot: hubRoot)
    }

    /// Testable core of `isCached`: is `modelId` fully present under `hubRoot`
    /// (the `.../huggingface/hub` directory)? Pure filesystem inspection - no
    /// network, no home-directory dependency.
    ///
    /// Rejects the two signatures an interrupted multi-GB download leaves behind
    /// (LOCAL1/AUD-20), which the old "any non-empty snapshot dir" check missed:
    ///   - a `blobs/*.incomplete` file (`hf_hub_download` writes `<etag>.incomplete`
    ///     then renames on completion), and
    ///   - a dangling snapshot symlink (a blob the download never finished).
    ///
    /// Residual it cannot catch locally: a download interrupted in the gap
    /// between finishing one file and starting the next leaves no `.incomplete`
    /// and no dangling link, yet the repo manifest expects more files. Detecting
    /// that needs the network manifest, so `mp prefetch-model` (spawned whenever
    /// this returns false) stays the authority; this check only has to be tight
    /// enough that an obviously-partial cache no longer reports ready forever.
    static func isComplete(modelId: String, hubRoot: URL) -> Bool {
        let fm = FileManager.default
        let sanitized = "models--" + modelId.replacingOccurrences(of: "/", with: "--")
        let modelDir = hubRoot.appendingPathComponent(sanitized, isDirectory: true)

        // An in-flight or interrupted download leaves `<etag>.incomplete` blobs;
        // their presence means the cache is partial.
        let blobs = modelDir.appendingPathComponent("blobs", isDirectory: true)
        if let blobEntries = try? fm.contentsOfDirectory(
            at: blobs, includingPropertiesForKeys: nil
        ), blobEntries.contains(where: { $0.pathExtension == "incomplete" }) {
            return false
        }

        // At least one snapshot must be structurally whole.
        let snapshots = modelDir.appendingPathComponent("snapshots", isDirectory: true)
        guard let snapshotDirs = try? fm.contentsOfDirectory(
            at: snapshots, includingPropertiesForKeys: nil
        ), !snapshotDirs.isEmpty else {
            return false
        }
        return snapshotDirs.contains { snapshotIsWhole($0, fm: fm) }
    }

    /// A snapshot dir is whole when it is non-empty and every entry resolves to
    /// an existing file (no dangling symlinks). Recurses into real subdirs.
    private static func snapshotIsWhole(_ dir: URL, fm: FileManager) -> Bool {
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ), !entries.isEmpty else {
            return false
        }
        return entries.allSatisfy { url in
            var isDir: ObjCBool = false
            // fileExists follows symlinks, so a dangling link returns false.
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
                return false
            }
            return isDir.boolValue ? snapshotIsWhole(url, fm: fm) : true
        }
    }

    /// UX21: a rough download-size label for a 4-bit MLX chat model, e.g.
    /// "~4.3 GB", for the "model not downloaded" affordance. Parsed from the
    /// parameter count in the repo id (`...-7B-...` -> 7B at ~0.62 GB/B, matching
    /// the measured ~4.3 GB for the default 7B). Mirrors the pipeline doctor's
    /// `_estimate_model_gb`; a display estimate only, so a small drift is harmless.
    static func downloadSizeLabel(forModelId id: String) -> String {
        guard let gb = estimatedDownloadGB(forModelId: id) else { return "several GB" }
        return "~\(String(format: "%.1f", gb)) GB"
    }

    /// The parsed size in GB, or nil when the parameter count is unreadable.
    static func estimatedDownloadGB(forModelId id: String) -> Double? {
        // First "<number>B" token, e.g. the 7 in "Qwen2.5-7B-Instruct-4bit".
        guard let match = id.range(
            of: #"(\d+(?:\.\d+)?)\s*[bB]\b"#, options: .regularExpression
        ) else { return nil }
        let token = id[match]
        let digits = token.prefix { $0.isNumber || $0 == "." }
        guard let paramsB = Double(digits) else { return nil }
        return (paramsB * 0.62 * 10).rounded() / 10
    }

    /// Idempotent. Call on `Coordinator.start()` (local/auto backend) and when config is persisted with a backend or local_model change. No-op when backend is anthropic.
    func ensure(modelId: String) {
        // Already downloading the same model -> let it run.
        if let cur = currentModelId, cur == modelId, process?.isRunning == true {
            return
        }
        // Already cached -> skip the subprocess entirely.
        if Self.isCached(modelId: modelId) {
            currentModelId = modelId
            state = .completed(modelId: modelId)
            return
        }
        // Replacing an in-flight download with a different model.
        cancel()
        spawn(modelId: modelId)
    }

    func cancel() {
        if let p = process, p.isRunning {
            p.terminate()
        }
        process = nil
        stdoutHandle = nil
        stdoutBuffer.removeAll()
        currentModelId = nil
        // LOCAL20: a cancelled download is not a download, and it is not a failed one either.
        // Leaving `.downloading` here is half of what let a SIGTERM read as a failure; the
        // identity guard in `handleTermination` is the other half, and both are wanted. This also
        // clears a `.failed` that the user is switching away from, which is the staleness rule:
        // a failure for a model the app is no longer configured to use is not worth a banner.
        state = .idle
    }

    /// LOCAL20: drop a failure the user has read and does not want to act on. Only `.failed` is
    /// dismissible: an in-flight download is not a notice, and `.completed` collapses on its own
    /// after a moment. Retry used to be the only exit from a failed row, which meant the only way
    /// to clear it was to re-download the model you had just moved away from.
    func dismissFailure() {
        if case .failed = state { state = .idle }
    }

    private func spawn(modelId: String) {
        guard let mp = PipelineLauncher.findMP() else {
            Log.main.warning("model prefetch: no `mp` binary found; skipping")
            state = .failed(modelId: modelId, error: "mp binary not found")
            return
        }
        currentModelId = modelId
        // Start with progress nil; first stdout event refines to real numbers.
        state = .downloading(modelId: modelId, progress: nil, downloadedBytes: 0, totalBytes: 0)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: mp.shell)
        p.arguments = mp.args + ["prefetch-model", modelId]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        p.standardOutput = stdoutPipe
        p.standardError = stderrPipe

        // Drain stderr to the daemon log (best-effort).
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                Log.writeLine("daemon", "[prefetch:stderr] \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }

        // Drain stdout line-by-line; each line is one JSON progress event.
        let outHandle = stdoutPipe.fileHandleForReading
        stdoutHandle = outHandle
        outHandle.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            DispatchQueue.main.async {
                self?.consumeStdout(chunk: chunk)
            }
        }

        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                self?.handleTermination(proc)
            }
        }

        do {
            Log.main.info("spawning model prefetch: \(modelId)")
            Log.writeLine("daemon", "model prefetch start \(modelId)")
            try p.run()
            process = p
        } catch {
            Log.main.error("model prefetch spawn failed: \(error.localizedDescription)")
            state = .failed(modelId: modelId, error: error.localizedDescription)
            currentModelId = nil
        }
    }

    private func consumeStdout(chunk: Data) {
        stdoutBuffer.append(chunk)
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer.prefix(upTo: nl)
            stdoutBuffer.removeSubrange(0...nl)
            guard !lineData.isEmpty,
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }
            handleEvent(json)
        }
    }

    /// Internal rather than private so `CI4ContractFixtureTests` can drive it
    /// with the committed `prefetch-progress-golden.json` lines, which are
    /// generated from the Python emitter's own call sites.
    func handleEvent(_ event: [String: Any]) {
        let kind = event["event"] as? String ?? "?"
        let modelId = (event["repo_id"] as? String) ?? currentModelId ?? ""
        switch kind {
        case "started", "progress":
            // Route byte counts through NSNumber.int64Value: `as? Int64` only works below 2^31 on 32-bit arches and download sizes are multi-GB.
            let downloaded = (event["downloaded_bytes"] as? NSNumber)?.int64Value
                ?? (event["cached_bytes"] as? NSNumber)?.int64Value
                ?? 0
            let total = (event["total_bytes"] as? NSNumber)?.int64Value ?? 0
            let progress = total > 0 ? Double(downloaded) / Double(total) : nil
            state = .downloading(
                modelId: modelId,
                progress: progress,
                downloadedBytes: downloaded,
                totalBytes: total
            )
        case "complete":
            state = .completed(modelId: modelId)
        case "failed":
            let error = (event["error"] as? String) ?? "unknown"
            state = .failed(modelId: modelId, error: error)
        default:
            break
        }
    }

    private func handleTermination(_ proc: Process) {
        let outcome = Self.terminationOutcome(
            isTrackedProcess: proc === process,
            state: state,
            terminationStatus: proc.terminationStatus
        )
        // LOCAL20: an abandoned prefetch touches nothing. Returning before the teardown below is
        // the point, not an optimisation: those three lines belong to whichever download is live
        // now, which after a replace is a different one.
        if outcome == .ignore {
            Log.writeLine(
                "daemon",
                "model prefetch terminated rc=\(proc.terminationStatus) (abandoned, ignored)"
            )
            return
        }

        // Flush any remaining buffered bytes before clearing the handle.
        if let h = stdoutHandle {
            let remaining = h.availableData
            if !remaining.isEmpty {
                consumeStdout(chunk: remaining)
            }
            h.readabilityHandler = nil
        }
        stdoutHandle = nil
        process = nil

        // Non-zero exit without a prior "failed" event - synthesize the failure state.
        if case .fail(let modelId, let error) = outcome {
            state = .failed(modelId: modelId, error: error)
        }
        Log.writeLine("daemon", "model prefetch terminated rc=\(proc.terminationStatus) state=\(state)")
        currentModelId = nil
    }
}
