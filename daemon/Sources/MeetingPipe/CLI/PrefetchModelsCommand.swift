import FluidAudio
import Foundation

/// `MeetingPipe prefetch-models` — download + compile the FluidAudio
/// CoreML models the runner uses (Parakeet TDT v3 ~600 MB, pyannote
/// diarizer ~30 MB) into `~/Library/Application Support/FluidAudio/Models`
/// so the first real recording doesn't pay the download + compile latency.
///
/// Idempotent: the SDK no-ops downloads that are already on disk and
/// only re-compiles when the CoreML toolchain version drifts. Safe to
/// invoke from `scripts/install.sh` after the daemon build, and safe to
/// re-run manually any time the user wants a warm cache.
///
/// Exit code: 0 on success (or "already cached"), 1 if either model
/// failed to materialise. The installer treats a non-zero exit as a
/// warning rather than a fatal error so a flaky network doesn't break
/// the whole install — the daemon will retry lazily on first recording.
enum PrefetchModelsCommand {

    static func run() -> Int32 {
        FileHandle.standardOutput.write(Data("Prefetching FluidAudio models…\n".utf8))

        let semaphore = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0
        let task = Task.detached {
            do {
                try await runAsync()
            } catch {
                let message = "  ✗ prefetch failed: \(error.localizedDescription)\n"
                FileHandle.standardError.write(Data(message.utf8))
                exitCode = 1
            }
            semaphore.signal()
        }
        semaphore.wait()
        _ = task
        return exitCode
    }

    private static func runAsync() async throws {
        // ASR (Parakeet TDT v3 — multilingual, ~600 MB).
        FileHandle.standardOutput.write(Data("  • Parakeet TDT v3 (ASR)\n".utf8))
        let asrReporter = ProgressReporter(label: "    Parakeet")
        let asrModels = try await AsrModels.downloadAndLoad(version: .v3) { progress in
            asrReporter.report(progress)
        }
        _ = asrModels
        FileHandle.standardOutput.write(Data("    ✓ Parakeet ready\n".utf8))

        // Diarizer (pyannote-Community-1 — ~30 MB).
        FileHandle.standardOutput.write(Data("  • pyannote diarizer\n".utf8))
        let diarReporter = ProgressReporter(label: "    pyannote")
        let diarizerModels = try await DiarizerModels.downloadIfNeeded { progress in
            diarReporter.report(progress)
        }
        _ = diarizerModels
        FileHandle.standardOutput.write(Data("    ✓ pyannote ready\n".utf8))

        FileHandle.standardOutput.write(Data("✓ FluidAudio models cached. First recording will skip the download wait.\n".utf8))
    }

    /// Throttles progress writes to every ~5% so the installer's stdout
    /// stays readable. The SDK fires callbacks much more frequently than
    /// that during a large download. Sendable so the @Sendable progress
    /// closure can capture and mutate it from a background context.
    private final class ProgressReporter: @unchecked Sendable {
        private let label: String
        private let lock = NSLock()
        private var lastFraction: Double = -1

        init(label: String) {
            self.label = label
        }

        func report(_ progress: DownloadUtils.DownloadProgress) {
            switch progress.phase {
            case .listing:
                return
            case .compiling(let modelName):
                let line = "\(label): compiling \(modelName)\n"
                FileHandle.standardOutput.write(Data(line.utf8))
            case .downloading(let completed, let total):
                let fraction = progress.fractionCompleted
                lock.lock()
                let shouldEmit = fraction - lastFraction >= 0.05 || fraction >= 1.0
                if shouldEmit { lastFraction = fraction }
                lock.unlock()
                guard shouldEmit else { return }
                let pct = Int(fraction * 100)
                let line = "\(label): \(pct)% (\(completed)/\(total) files)\n"
                FileHandle.standardOutput.write(Data(line.utf8))
            }
        }
    }
}
