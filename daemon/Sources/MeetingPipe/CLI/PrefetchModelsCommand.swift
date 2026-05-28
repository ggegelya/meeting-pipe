import FluidAudio
import Foundation

/// `MeetingPipe prefetch-models` - downloads and compiles FluidAudio CoreML models (Parakeet TDT v3 ~600 MB, pyannote ~30 MB) so the first recording skips the download wait.
/// Idempotent: SDK no-ops already-cached models. Exit 0 on success or "already cached"; exit 1 if a model fails. Installer treats non-zero as a warning (flaky network must not break the whole install - daemon retries on first recording).
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
        FileHandle.standardOutput.write(Data("  • Parakeet TDT v3 (ASR)\n".utf8))
        let asrReporter = ProgressReporter(label: "    Parakeet")
        let asrModels = try await AsrModels.downloadAndLoad(version: .v3) { progress in
            asrReporter.report(progress)
        }
        _ = asrModels
        FileHandle.standardOutput.write(Data("    ✓ Parakeet ready\n".utf8))

        FileHandle.standardOutput.write(Data("  • pyannote diarizer\n".utf8))
        let diarReporter = ProgressReporter(label: "    pyannote")
        let diarizerModels = try await DiarizerModels.downloadIfNeeded { progress in
            diarReporter.report(progress)
        }
        _ = diarizerModels
        FileHandle.standardOutput.write(Data("    ✓ pyannote ready\n".utf8))

        FileHandle.standardOutput.write(Data("✓ FluidAudio models cached. First recording will skip the download wait.\n".utf8))
    }

    /// Throttles progress writes to every ~5%; the SDK fires callbacks far more frequently during large downloads. `@unchecked Sendable` because the `@Sendable` progress closure captures and mutates it from a background context.
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
