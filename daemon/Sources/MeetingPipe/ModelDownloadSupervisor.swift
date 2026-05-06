import Foundation

/// Owns the lifecycle of a `mp prefetch-model` subprocess and surfaces
/// download progress to whoever subscribes (Coordinator -> StatusBar).
///
/// Behaviour the daemon's UI relies on:
///
///   - `ensure(modelId:)` is the only entry point. Idempotent: if the
///     same model is already downloading, do nothing. If a different
///     model is downloading, kill the in-flight process and start a new
///     one for the requested model.
///   - The supervisor checks `isCached(modelId:)` first; if the model
///     is fully on disk, it short-circuits and does not spawn anything.
///     The Python prefetch command would do this too, but skipping the
///     subprocess hop avoids 0.5-1s of fork/import latency on the happy
///     path.
///   - Stdout is the live event channel (one JSON per line). Stderr is
///     captured into the daemon's text log for postmortem.
///   - Failures emit one `failed` event and clear the in-flight state.
///     The next recording falls through to the existing
///     `LocalSummaryClient` path which would re-attempt the download
///     (with worse UX). Recovery happens at the next `ensure(...)`.
///
/// Threading: every public method must run on the main queue. The stdout
/// reader hops back to main before invoking callbacks.
final class ModelDownloadSupervisor {

    enum State: Equatable {
        case idle
        /// 0.0..1.0 when total_bytes is known, otherwise nil.
        case downloading(modelId: String, progress: Double?, downloadedBytes: Int64, totalBytes: Int64)
        case completed(modelId: String)
        case failed(modelId: String, error: String)
    }

    /// Called on the main queue every time `state` changes. Coordinator
    /// uses this to rebuild the menu-bar title + menu.
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

    /// Replicates the HuggingFace Hub cache layout: `~/.cache/huggingface/
    /// hub/models--<repo_with_slashes_replaced>/snapshots/<hash>/`. We
    /// treat presence of any non-empty snapshot dir as "cached enough"
    /// for the short-circuit; the Python side does a real byte-count
    /// check before declaring complete.
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

    /// Idempotent. Call when:
    ///   - Coordinator.start() if backend is local/auto.
    ///   - Config persisted with a backend or local_model change.
    /// No-op when backend is anthropic.
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
        // Start at downloading(progress: nil, 0, 0); first stdout line
        // refines this with real numbers from the started/progress event.
        state = .downloading(modelId: modelId, progress: nil, downloadedBytes: 0, totalBytes: 0)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: mp.shell)
        p.arguments = mp.args + ["prefetch-model", modelId]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        p.standardOutput = stdoutPipe
        p.standardError = stderrPipe

        // Drain stderr to the daemon's text log (best-effort, async).
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                Log.writeLine("daemon", "[prefetch:stderr] \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }

        // Drain stdout line-by-line; each line is one JSON event.
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
            // JSONSerialization returns NSNumber for any numeric value.
            // `as? Int64` works for ints below 2^31 only on 32-bit archs;
            // route through NSNumber.int64Value to be size-safe (the
            // download size is multi-GB, well above Int32).
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
        // Drain any final buffered bytes.
        if let h = stdoutHandle {
            let remaining = h.availableData
            if !remaining.isEmpty {
                consumeStdout(chunk: remaining)
            }
            h.readabilityHandler = nil
        }
        stdoutHandle = nil
        process = nil

        // Distinguish abnormal exits the JSONL stream did not narrate.
        if case .downloading(let modelId, _, _, _) = state, proc.terminationStatus != 0 {
            state = .failed(modelId: modelId, error: "prefetch exited \(proc.terminationStatus)")
        }
        Log.writeLine("daemon", "model prefetch terminated rc=\(proc.terminationStatus) state=\(state)")
        currentModelId = nil
    }
}
