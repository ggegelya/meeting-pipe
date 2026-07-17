import Foundation

/// Factory seam between the Coordinator and TranscriptionRunner backends.
/// Returns FluidAudioRunner unless a test fake has been injected.
enum TranscriptionService {

    static func makeRunner(
        clusteringThreshold: Double = FluidAudioRunner.defaultClusteringThreshold
    ) -> TranscriptionRunner {
        if let override = testingOverride { return override }
        return FluidAudioRunner(clusteringThreshold: clusteringThreshold)
    }

    // MARK: - Test seam

    private static var testingOverride: TranscriptionRunner?

    /// Inject a fake runner for tests. Reset to nil in tearDown.
    static func overrideRunnerForTesting(_ runner: TranscriptionRunner?) {
        testingOverride = runner
    }
}
