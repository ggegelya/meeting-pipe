import Foundation

/// Per-recording transcript sidecar schema (<stem>.json). Must stay field-for-field
/// identical to what pipeline/src/mp/transcribe.py writes; downstream library code
/// reads both. Group P's migration replaces the producer, not the schema.
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

/// Contract for transcription backends. Async because every real implementation awaits model load + inference.
protocol TranscriptionRunner: AnyObject {
    /// Written into TranscriptSidecar.backend; used by events.jsonl analysis (TECH-P2) to distinguish engines.
    var backendName: String { get }

    /// Run ASR + diarization and return the sidecar. languageHint is the workflow's
    /// language code (en/uk/es/ru/auto); runners may ignore it for auto-detection.
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
    /// Atomic JSON write. Keys are explicit snake_case so the file is byte-shape
    /// interchangeable with pipeline/src/mp/transcribe.py output.
    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }
}
