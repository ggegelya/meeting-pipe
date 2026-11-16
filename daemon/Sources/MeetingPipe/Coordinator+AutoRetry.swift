import Foundation

/// PIPE41: the two triggers and the launch notice for the one automatic re-run of a failed summarize job. The
/// policy, the bound's store and the pickup are in `Coordination/AutoRetry.swift`; this is only the wiring.
extension Coordinator {

    /// Arm the launch pass: after `reconcileStrandedJobs` and a short wait for the network
    /// (`AutoRetryTiming.launchDelay`). A successful job landing first runs `runAutoRetry` sooner.
    func scheduleLaunchAutoRetry() {
        DispatchQueue.main.asyncAfter(deadline: .now() + AutoRetryTiming.launchDelay) { [weak self] in
            self?.runLaunchAutoRetry()
        }
    }

    /// Run every pending re-run once, through `retryMeeting` (so PIPE18's coalescing, the transcript reuse and
    /// the moved-into-NDA publish guard all apply). Returns the stems started. Cheap and main-thread: it reads
    /// one small store and, per pending stem, one failure sidecar.
    @discardableResult
    func runAutoRetry() -> [String] {
        let dir = liveOutputDir
        return AutoRetryPass.run(
            store: autoRetryStore,
            readFailure: { PipelineFailureSidecar.read(stem: $0, in: dir) },
            hasSummary: { FileManager.default.fileExists(atPath: dir.appendingPathComponent("\($0).summary.json").path) },
            retry: { [weak self] stem in
                self?.library.retryMeeting(stem: stem, trigger: .auto) ?? .failure(CancellationError())
            },
            onSkip: { stem, reason in
                Log.event(category: "coordinator", action: "auto_retry_skipped", attributes: [
                    "stem": stem, "reason": reason.rawValue,
                ])
            }
        )
    }

    /// The launch pass, then the once-per-launch notice. Everything that only reads files (the directory listing
    /// and the failure sidecars) is off main (PERF24: `raw/` is about seven entries per meeting and may sync to
    /// iCloud); the store, `retryMeeting` and the notification are back on main.
    private func runLaunchAutoRetry() {
        let dir = liveOutputDir
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
            let failures = MeetingStore.unrecoveredFailureStems(fileNames: names ?? []).compactMap { stem in
                PipelineFailureSidecar.read(stem: stem, in: dir).map { (stem: stem, ts: $0.ts) }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                let result = AutoRetryPass.launch(
                    store: self.autoRetryStore,
                    snapshot: .init(names: names, failures: failures),
                    now: Date(),
                    readFailure: { PipelineFailureSidecar.read(stem: $0, in: dir) },
                    hasSummary: { FileManager.default.fileExists(atPath: dir.appendingPathComponent("\($0).summary.json").path) },
                    retry: { [weak self] stem in
                        self?.library.retryMeeting(stem: stem, trigger: .auto) ?? .failure(CancellationError())
                    },
                    onSkip: { stem, reason in
                        Log.event(category: "coordinator", action: "auto_retry_skipped", attributes: [
                            "stem": stem, "reason": reason.rawValue,
                        ])
                    }
                )
                guard let oldest = result.unresolved.first else { return }
                Log.event(category: "coordinator", action: "failures_unresolved", attributes: [
                    "count": result.unresolved.count,
                ])
                self.notifier.notifyUnresolvedFailures(count: result.unresolved.count, oldestStem: oldest)
            }
        }
    }
}
