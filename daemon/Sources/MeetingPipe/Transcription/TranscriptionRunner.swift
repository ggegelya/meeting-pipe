import Foundation

/// On-disk schema for the per-recording transcript sidecar (`<stem>.json`).
/// This must stay field-for-field identical to what `pipeline/src/mp/transcribe.py`
/// writes today, because downstream library code reads both. Group P's
/// migration replaces the *producer* of this file; the file itself does
/// not change.
struct TranscriptSidecar: Codable, Equatable {
    var language: String
    var segments: [SidecarSegment]
    var audioPath: String
    var audioSeconds: Double
    var model: String
    var backend: String
    var diarization: Bool
    var diarizationFailed: Bool
    var diarizationFailureReason: String?
    var streaming: Bool
    var finalized: Bool

    enum CodingKeys: String, CodingKey {
        case language
        case segments
        case audioPath = "audio_path"
        case audioSeconds = "audio_seconds"
        case model
        case backend
        case diarization
        case diarizationFailed = "diarization_failed"
        case diarizationFailureReason = "diarization_failure_reason"
        case streaming
        case finalized
    }
}

struct SidecarSegment: Codable, Equatable {
    var start: Double
    var end: Double
    var text: String
    var words: [SidecarWord]
    var speaker: String
}

struct SidecarWord: Codable, Equatable {
    var word: String
    var start: Double
    var end: Double
}

/// Contract every transcription backend (FluidAudio today; MLX-Whisper-via-pipeline
/// still owned by the Python subprocess) must satisfy. Async because every
/// real implementation needs to await model load + inference.
protocol TranscriptionRunner: AnyObject {
    /// Engine identifier written into `TranscriptSidecar.backend`. Surfaces
    /// in events.jsonl analysis (TECH-P2 acceptance) so dogfood reports can
    /// distinguish runs by engine.
    var backendName: String { get }

    /// Run ASR + diarization against `wavURL` and produce the sidecar
    /// payload. `languageHint` is the workflow's configured language code
    /// (en / uk / es / ru / auto); a runner may ignore it when the engine
    /// auto-detects.
    func transcribe(
        wavURL: URL,
        languageHint: String?
    ) async throws -> TranscriptSidecar
}

enum TranscriptionError: Error, LocalizedError {
    case modelLoadFailed(String)
    case inferenceFailed(String)
    case audioReadFailed(URL, underlying: Error)
    case diarizationFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let reason):
            return "Transcription model load failed: \(reason)"
        case .inferenceFailed(let reason):
            return "Transcription inference failed: \(reason)"
        case .audioReadFailed(let url, let err):
            return "Failed to read audio at \(url.path): \(err.localizedDescription)"
        case .diarizationFailed(let reason):
            return "Diarization failed: \(reason)"
        }
    }
}

extension TranscriptSidecar {
    /// Atomic JSON write to disk. Schema validated against the Python
    /// pipeline's writer in `pipeline/src/mp/transcribe.py`; the encoder
    /// keys are explicit (snake_case) so the produced file is byte-shape
    /// interchangeable with the pipeline's output.
    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }
}
