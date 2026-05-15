import AVFoundation
import FluidAudio
import Foundation

/// Swift-native ASR + diarization via FluidAudio (Parakeet TDT + pyannote-Community-1
/// on Apple Neural Engine). Wired into `TranscriptionService` but not the
/// default route yet; flipping the default lands in a follow-up after
/// ANE residency and sidecar parity are verified against a real recording.
///
/// Model state is held for the lifetime of the runner so consecutive
/// recordings within one daemon session don't re-pay the CoreML compilation
/// cost. The init does not touch the network; `transcribe(_:_:)` triggers
/// the first model download lazily via FluidAudio's bundled loader.
final class FluidAudioRunner: TranscriptionRunner {

    let backendName = "fluidaudio"

    /// Configured Parakeet variant. v3 is multilingual (25 European + Japanese + Chinese);
    /// v2 is English-only with marginally lower WER on English. The user's
    /// archive includes en + uk + es + ru, so v3 is the right default.
    private let asrVersion: AsrModelVersion
    private let unknownSpeaker: String

    private var asrManager: AsrManager?
    private var diarizer: DiarizerManager?
    private var diarizerModels: DiarizerModels?

    init(
        asrVersion: AsrModelVersion = .v3,
        unknownSpeaker: String = "speaker_unknown"
    ) {
        self.asrVersion = asrVersion
        self.unknownSpeaker = unknownSpeaker
    }

    func transcribe(
        wavURL: URL,
        languageHint: String?
    ) async throws -> TranscriptSidecar {
        let asr = try await ensureAsr()
        let language = Self.resolveLanguage(hint: languageHint)
        var decoderState = TdtDecoderState.make()
        let asrResult: ASRResult
        do {
            asrResult = try await asr.transcribe(
                wavURL,
                decoderState: &decoderState,
                language: language
            )
        } catch let error as ASRError {
            throw TranscriptionError.inferenceFailed(error.localizedDescription)
        }

        let samples: [Float]
        do {
            samples = try Self.readMonoFloat32(from: wavURL)
        } catch {
            throw TranscriptionError.audioReadFailed(wavURL, underlying: error)
        }

        var speakers: [SpeakerSpan] = []
        var diarizationOK = true
        var diarizationFailureReason: String? = nil
        do {
            let diarized = try await runDiarization(samples: samples)
            speakers = diarized
        } catch {
            diarizationOK = false
            diarizationFailureReason = String(describing: error)
        }

        let tokens = Self.tokens(from: asrResult)
        let segments = SegmentBuilder.build(
            tokens: tokens,
            speakers: speakers,
            unknownSpeaker: unknownSpeaker
        )

        let audioSeconds = asrResult.duration > 0
            ? asrResult.duration
            : (segments.last?.end ?? 0)
        let modelName = "parakeet-tdt-0.6b-\(asrVersion == .v3 ? "v3" : "v2")"
        let writtenLanguage = language?.rawValue ?? languageHint?.lowercased() ?? "auto"

        return TranscriptSidecar(
            language: writtenLanguage,
            segments: segments,
            audioPath: wavURL.path,
            audioSeconds: audioSeconds,
            model: modelName,
            backend: backendName,
            diarization: diarizationOK,
            diarizationFailed: !diarizationOK,
            diarizationFailureReason: diarizationFailureReason,
            streaming: false,
            finalized: true
        )
    }

    // MARK: - Model lifecycle

    private func ensureAsr() async throws -> AsrManager {
        if let asr = asrManager { return asr }
        do {
            let models = try await AsrModels.downloadAndLoad(version: asrVersion)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            self.asrManager = manager
            return manager
        } catch {
            throw TranscriptionError.modelLoadFailed(error.localizedDescription)
        }
    }

    private func ensureDiarizer() async throws -> DiarizerManager {
        if let d = diarizer { return d }
        do {
            let models = try await DiarizerModels.downloadIfNeeded()
            let manager = DiarizerManager()
            manager.initialize(models: models)
            self.diarizerModels = models
            self.diarizer = manager
            return manager
        } catch {
            throw TranscriptionError.diarizationFailed(error.localizedDescription)
        }
    }

    private func runDiarization(samples: [Float]) async throws -> [SpeakerSpan] {
        let diarizer = try await ensureDiarizer()
        let result = try await diarizer.performCompleteDiarization(samples)
        return result.segments.map {
            SpeakerSpan(
                speakerId: $0.speakerId,
                start: Double($0.startTimeSeconds),
                end: Double($0.endTimeSeconds)
            )
        }
    }

    // MARK: - Adapters

    /// Map the workflow's language code (en / uk / es / ru / auto / nil) to
    /// FluidAudio's `Language`. Returns nil for "auto" or unknown codes so
    /// the SDK falls through to its own detection.
    static func resolveLanguage(hint: String?) -> Language? {
        guard let code = hint?.lowercased(), !code.isEmpty, code != "auto" else { return nil }
        return Language(rawValue: code)
    }

    static func tokens(from result: ASRResult) -> [AsrToken] {
        guard let timings = result.tokenTimings, !timings.isEmpty else {
            // No per-token timing: synthesize a single token spanning the
            // whole utterance so downstream segment-building still works.
            // This loses word-level alignment for whatever upstream call
            // didn't request timings, but keeps the schema populated.
            let text = result.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return [] }
            return [AsrToken(text: text, start: 0, end: result.duration)]
        }
        return timings.map {
            AsrToken(
                text: $0.token,
                start: $0.startTime,
                end: $0.endTime
            )
        }
    }

    /// Loads a WAV (any sample-rate, any channel count) and returns it as
    /// mono 16 kHz Float32 — FluidAudio's diarizer expects that shape.
    /// Stereo files (mic-L, system-R) are mixed down to mono for diarization;
    /// the on-disk WAV is untouched.
    static func readMonoFloat32(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )
        guard let target = target,
              let converter = AVAudioConverter(from: file.processingFormat, to: target)
        else {
            throw TranscriptionError.audioReadFailed(
                url,
                underlying: NSError(
                    domain: "FluidAudioRunner",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "audio format conversion unavailable"]
                )
            )
        }

        let frameCapacity = AVAudioFrameCount(file.length)
        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: frameCapacity
        ) else {
            throw TranscriptionError.audioReadFailed(
                url,
                underlying: NSError(
                    domain: "FluidAudioRunner",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "could not allocate input buffer"]
                )
            )
        }
        try file.read(into: inputBuffer)

        let ratio = target.sampleRate / file.processingFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio + 1024)
        guard let outBuffer = AVAudioPCMBuffer(
            pcmFormat: target,
            frameCapacity: outCapacity
        ) else {
            throw TranscriptionError.audioReadFailed(
                url,
                underlying: NSError(
                    domain: "FluidAudioRunner",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "could not allocate output buffer"]
                )
            )
        }

        var done = false
        var convertError: NSError?
        let status = converter.convert(to: outBuffer, error: &convertError) { _, outStatus in
            if done {
                outStatus.pointee = .endOfStream
                return nil
            }
            done = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        if status == .error, let err = convertError {
            throw TranscriptionError.audioReadFailed(url, underlying: err)
        }

        let count = Int(outBuffer.frameLength)
        guard count > 0, let channel = outBuffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: count))
    }
}
