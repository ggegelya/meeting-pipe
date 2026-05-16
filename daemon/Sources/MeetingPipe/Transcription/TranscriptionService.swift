import Foundation

/// Routing seam between the Coordinator and the per-engine
/// `TranscriptionRunner` instances. The daemon owns ASR + diarization
/// in-process via FluidAudio (Parakeet TDT + pyannote on the Apple
/// Neural Engine); the Python pipeline no longer carries its own ASR
/// path. `makeRunner` returns a FluidAudioRunner unless tests have
/// injected a fake.
enum TranscriptionService {

    static func makeRunner() -> TranscriptionRunner {
        if let override = testingOverride { return override }
        return FluidAudioRunner()
    }

    // MARK: - Test seam

    private static var testingOverride: TranscriptionRunner?

    /// Inject a fake runner from tests. Tests must reset to nil in tearDown.
    static func overrideRunnerForTesting(_ runner: TranscriptionRunner?) {
        testingOverride = runner
    }
}
