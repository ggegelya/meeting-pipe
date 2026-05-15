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

        // Critical: read + downmix the WAV ourselves rather than letting
        // FluidAudio's AVAudioConverter-based loader handle stereo. Apple's
        // AVAudioConverter does NOT reliably downmix stereo to mono when
        // the source's channel layout isn't explicitly tagged — it can
        // silently fall through to channel-0-only. Our WAVs are
        // (mic-L, system-R), so that path would drop the entire remote
        // side of the call out of the transcript. We compute (L+R)/2 in
        // Swift and hand the resulting [Float] to both ASR + diarization.
        let samples: [Float]
        do {
            samples = try Self.readMonoFloat32(from: wavURL)
        } catch {
            throw TranscriptionError.audioReadFailed(wavURL, underlying: error)
        }

        var decoderState = TdtDecoderState.make()
        let asrResult: ASRResult
        do {
            asrResult = try await asr.transcribe(
                samples,
                decoderState: &decoderState,
                language: language
            )
        } catch let error as ASRError {
            throw TranscriptionError.inferenceFailed(error.localizedDescription)
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

    /// Loads a WAV and returns it as 16 kHz mono Float32 with both
    /// channels averaged into the mono stream. Stereo files (mic-L,
    /// system-R) get an explicit per-frame `(L+R)/2` mix; FluidAudio's
    /// own loader uses AVAudioConverter for the channel reduction and
    /// that path is unreliable on macOS when the source WAV has no
    /// tagged channel layout (it can silently drop to channel 0 only,
    /// losing the entire system-audio side of the recording).
    ///
    /// The on-disk WAV is never modified — we only build an in-memory
    /// mono copy for ASR + diarization inputs.
    static func readMonoFloat32(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0 else { return [] }

        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw TranscriptionError.audioReadFailed(
                url,
                underlying: NSError(
                    domain: "FluidAudioRunner",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "could not allocate input buffer"]
                )
            )
        }
        try file.read(into: inputBuffer)

        // Downmix every channel into mono by simple average. This works
        // for any channel count (1, 2, 4, ...) and never silently drops
        // a channel the way an unconfigured AVAudioConverter mixer can.
        let mono = mixDownToMono(inputBuffer)

        // Resample to 16 kHz if the source isn't already there.
        // Mono → mono via AVAudioConverter is safe (no channel layout
        // ambiguity), so reuse it for the rate change.
        if format.sampleRate == 16_000 {
            return mono
        }
        return try resampleMono(mono, from: format.sampleRate, to: 16_000, url: url)
    }

    /// Visible for tests so we can lock in (L+R)/2 against a synthesized
    /// stereo buffer. Production callers go through `readMonoFloat32`.
    static func mixDownToMono(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0, let channels = buffer.floatChannelData else { return [] }
        let channelCount = Int(buffer.format.channelCount)

        if channelCount == 1 {
            return Array(UnsafeBufferPointer(start: channels[0], count: frameCount))
        }

        var result = [Float](repeating: 0, count: frameCount)
        let scale = 1.0 / Float(channelCount)
        for c in 0..<channelCount {
            let ptr = channels[c]
            for i in 0..<frameCount {
                result[i] += ptr[i] * scale
            }
        }
        return result
    }

    private static func resampleMono(
        _ samples: [Float],
        from inputRate: Double,
        to outputRate: Double,
        url: URL
    ) throws -> [Float] {
        guard
            let inputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: inputRate,
                channels: 1,
                interleaved: false
            ),
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: outputRate,
                channels: 1,
                interleaved: false
            ),
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else {
            throw TranscriptionError.audioReadFailed(
                url,
                underlying: NSError(
                    domain: "FluidAudioRunner", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "resampler unavailable"]
                )
            )
        }
        guard
            let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: inputFormat,
                frameCapacity: AVAudioFrameCount(samples.count)
            )
        else {
            throw TranscriptionError.audioReadFailed(
                url,
                underlying: NSError(
                    domain: "FluidAudioRunner", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "resampler input alloc failed"]
                )
            )
        }
        inputBuffer.frameLength = AVAudioFrameCount(samples.count)
        if let dst = inputBuffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                dst.update(from: src.baseAddress!, count: samples.count)
            }
        }

        let ratio = outputRate / inputRate
        let outCapacity = AVAudioFrameCount(Double(samples.count) * ratio + 1024)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outCapacity) else {
            throw TranscriptionError.audioReadFailed(
                url,
                underlying: NSError(
                    domain: "FluidAudioRunner", code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "resampler output alloc failed"]
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
