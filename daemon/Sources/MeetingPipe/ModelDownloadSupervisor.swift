import Foundation

/// Owns the lifecycle of a `mp prefetch-model` subprocess and surfaces download progress to the Coordinator -> StatusBar.
/// `ensure(modelId:)` is the only entry point - idempotent, cancels any in-flight download for a different model. Short-circuits without spawning if the model is already cached (avoids 0.5-1 s of fork/import latency on the happy path). Stdout is the live JSON-lines event channel; stderr goes to the daemon log.
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

    private(set) var state: State = .idle {
        didSet {
            if oldValue != state {
                onStateChange?(state)
            }
        }
    }

    private var process: Process?
    private var stdoutHandle: FileHandle?
    private var stdoutBuffer = Data()
    private var currentModelId: String?

    /// Replicates the HuggingFace Hub layout (`~/.cache/huggingface/hub/models--<repo>/snapshots/<hash>/`). Any non-empty snapshot dir is "cached enough" for the short-circuit; the Python side does a real byte-count check before declaring complete.
    static func isCached(modelId: String) -> Bool {
        let sanitized = "models--" + modelId.replacingOccurrences(of: "/", with: "--")
        let snapshots = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub/\(sanitized)/snapshots", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: snapshots, includingPropertiesForKeys: nil
        ) else {
            return false
        }
        return entries.contains { url in
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            return !contents.isEmpty
        }
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

    private func handleEvent(_ event: [String: Any]) {
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
        if case .downloading(let modelId, _, _, _) = state, proc.terminationStatus != 0 {
            state = .failed(modelId: modelId, error: "prefetch exited \(proc.terminationStatus)")
        }
        Log.writeLine("daemon", "model prefetch terminated rc=\(proc.terminationStatus) state=\(state)")
        currentModelId = nil
    }
}
