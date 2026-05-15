import Foundation

/// Stable identifiers for the `[transcription] backend` config field.
/// Centralising them here means callers don't sprinkle string literals
/// and the normalize helper is the only place that decides what
/// unrecognised input falls back to.
enum TranscriptionBackend {
    /// Swift-native Parakeet TDT + pyannote on the Apple Neural Engine.
    /// Daemon-owned: writes `<stem>.json` directly before invoking the
    /// Python pipeline subprocess, which then skips its own ASR.
    static let fluidaudio = "fluidaudio"

    /// Legacy path: the Python `mp` subprocess runs MLX-Whisper +
    /// sherpa-onnx end-to-end. Kept around as a fallback while the
    /// FluidAudio path is being dogfooded.
    static let pipeline = "pipeline"

    /// Returns `fluidaudio` for any unrecognised input. The default
    /// route is FluidAudio; `nil` from the TOML loader means the user
    /// is on a fresh install and gets the new default.
    static func normalize(_ raw: String?) -> String {
        let candidate = raw?.lowercased().trimmingCharacters(in: .whitespaces) ?? ""
        switch candidate {
        case fluidaudio, "fluid", "parakeet": return fluidaudio
        case pipeline, "mlx", "whisper", "mlx-whisper": return pipeline
        default: return fluidaudio
        }
    }
}

/// Routing seam between the Coordinator and the per-engine
/// `TranscriptionRunner` instances. `makeRunner(for:)` returns the
/// runner the daemon should drive (running it before queueing the
/// Python subprocess), or `nil` if the legacy Python pipeline should
/// own transcription itself.
enum TranscriptionService {

    /// Build a runner for the given backend identifier. Returns `nil`
    /// for the legacy pipeline path so the Coordinator skips the
    /// pre-pipeline transcription step and lets `mp run-all` handle ASR.
    static func makeRunner(for backend: String) -> TranscriptionRunner? {
        if let override = testingOverride { return override }
        switch backend {
        case TranscriptionBackend.fluidaudio:
            return FluidAudioRunner()
        case TranscriptionBackend.pipeline:
            return nil
        default:
            // Defensive: TranscriptionBackend.normalize already collapses
            // unknown values to fluidaudio. If a caller passed an unfiltered
            // string anyway, treat it as the legacy path so we don't silently
            // run an unexpected engine.
            return nil
        }
    }

    // MARK: - Test seam

    private static var testingOverride: TranscriptionRunner?

    /// Inject a fake runner from tests. Tests must reset to nil in tearDown.
    static func overrideRunnerForTesting(_ runner: TranscriptionRunner?) {
        testingOverride = runner
    }
}
