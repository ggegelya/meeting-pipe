import Foundation

/// Routing seam between the Coordinator and the per-engine
/// `TranscriptionRunner` instances. The default route still goes through
/// the existing Python pipeline subprocess — `defaultRunner()` returns
/// `nil` and the caller falls through to `PipelineLauncher.runAll(...)`.
///
/// Group P (TECH-P2 onward) flips the default to FluidAudio after the
/// ANE residency + sidecar parity acceptance pass against a real recording.
/// The build-time flag `MP_USE_FLUIDAUDIO` (declared via `swiftSettings`
/// on the executable target) flips that default for the user / test build
/// without code changes; the runtime setter (`overrideRunnerForTesting`)
/// is what the unit tests use to exercise both routes.
enum TranscriptionService {

    /// Returns the runner that should produce the transcript sidecar for a
    /// fresh recording, or `nil` if the legacy Python pipeline path should
    /// keep handling transcription. `nil` is the current default until the
    /// FluidAudio path is validated end-to-end.
    static func defaultRunner() -> TranscriptionRunner? {
        if let override = testingOverride { return override }
        return featureEnabled ? FluidAudioRunner() : nil
    }

    /// True iff the `MP_USE_FLUIDAUDIO` build flag is set. Compile-time
    /// gate so a release build can opt in without touching code paths
    /// users haven't seen yet.
    static var featureEnabled: Bool {
        #if MP_USE_FLUIDAUDIO
        return true
        #else
        return false
        #endif
    }

    // MARK: - Test seam

    private static var testingOverride: TranscriptionRunner?

    /// Inject a fake runner from tests. Always set back to nil in tearDown.
    static func overrideRunnerForTesting(_ runner: TranscriptionRunner?) {
        testingOverride = runner
    }
}
