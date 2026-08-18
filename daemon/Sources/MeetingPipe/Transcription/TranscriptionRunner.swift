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
    /// Per-speaker 256-d voiceprint embedding keyed by diarization speaker id.
    /// Written on the draft <stem>.json only; the pipeline consumes it at
    /// finalize (voiceprint enroll + match) and strips it, so it never reaches
    /// the final transcript the Library reads. Omitted when diarization
    /// produced no speakers.
    var speakerEmbeddings: [String: [Float]]? = nil

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
        case speakerEmbeddings = "speaker_embeddings"
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
    ///
    /// **Cancellable, and that is part of the contract (UX69).** The pass takes
    /// tens of seconds on a long meeting and scales with its length, so the
    /// Library offers a Cancel while it runs; the owner's click cancels the Task
    /// this is called in, and an implementation is required to notice and throw
    /// `CancellationError` rather than run to completion. There is no `cancel()`
    /// method here on purpose: Swift's own cancellation is the vocabulary
    /// FluidAudio's ASR already speaks internally, and a second one beside it
    /// would be a seam every future runner had to remember to wire up.
    ///
    /// A runner that degrades a failure into a partial result (the way
    /// `FluidAudioRunner` records a diarization failure and keeps the transcript)
    /// must exempt cancellation from that: swallowing it returns a sidecar for a
    /// job the owner stopped, and the caller then spawns the pipeline for it.
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
        // SEC14: transcripts carry meeting content, so keep them user-private (0600), like originals/ and the logs.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
