import AVFoundation
import FluidAudio
import Foundation

/// Swift-native ASR + diarization via FluidAudio (Parakeet TDT + pyannote on ANE).
/// The default (and only) ASR runner, returned by `TranscriptionService.makeRunner()`;
/// Python does summarize + publish only (ADR 0007). Model state is held for the daemon
/// session lifetime to avoid CoreML recompilation. Network is not touched at init;
/// first model download is lazy via FluidAudio's bundled loader.
final class FluidAudioRunner: TranscriptionRunner {

    let backendName = "fluidaudio"

    /// Parakeet variant. v3 is multilingual (25 European + JA + ZH); v2 is English-only
    /// with slightly lower WER on English. User archive is en/uk/es/ru, so v3 is default.
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

        // Critical: downmix ourselves instead of letting FluidAudio's AVAudioConverter
        // handle stereo. AVAudioConverter silently falls through to channel-0-only when
        // the source WAV has no tagged channel layout; for (mic-L, system-R) that drops
        // the entire remote side of the call. readMonoFloat32 computes (L+R)/2 explicitly.
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
        var speakerEmbeddings: [String: [Float]] = [:]
        var diarizationOK = true
        var diarizationFailureReason: String? = nil
        do {
            let diarized = try await runDiarization(samples: samples)
            speakers = diarized.spans
            speakerEmbeddings = diarized.embeddings
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
            finalized: true,
            speakerEmbeddings: speakerEmbeddings.isEmpty ? nil : speakerEmbeddings
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

    private func runDiarization(
        samples: [Float]
    ) async throws -> (spans: [SpeakerSpan], embeddings: [String: [Float]]) {
        let diarizer = try await ensureDiarizer()
        // ASR2: the DiarizerManager is cached for the daemon session to avoid CoreML
        // recompilation, but its SpeakerManager also accumulates a speaker-clustering
        // database across meetings. Clear it at the start of each job so label assignment
        // restarts from speaker_1 per meeting (identical to a fresh launch) and cannot
        // drift with daemon uptime. `reset()` only empties the in-memory database and
        // resets the id counter; the models + EmbeddingExtractor stay resident, so there
        // is no per-job recompilation. Jobs are serialized (`SinkDispatcher`), so this
        // never races a concurrent diarization.
        diarizer.speakerManager.reset()
        let result = try diarizer.performCompleteDiarization(samples)
        let spans = result.segments.map {
            SpeakerSpan(
                speakerId: $0.speakerId,
                start: Double($0.startTimeSeconds),
                end: Double($0.endTimeSeconds)
            )
        }
        // Duration-weighted mean of each speaker's per-segment embeddings, so the
        // persisted voiceprint reflects voiced speech. The per-segment embedding is
        // this recording's own audio; combined with the ASR2 per-job
        // `speakerManager.reset()` above, the clustering state is per-meeting, so the
        // ids and embeddings do not drift with daemon uptime.
        let items = result.segments.map {
            (speaker: $0.speakerId,
             embedding: $0.embedding,
             weight: Double(max(0, $0.endTimeSeconds - $0.startTimeSeconds)))
        }
        return (spans, Self.weightedMeanEmbeddings(items))
    }

    /// Duration-weighted mean embedding per speaker id, L2-normalized. Pure and
    /// FluidAudio-free so it is unit-testable. Speakers with no positive weight
    /// or a ragged embedding dimension are dropped.
    static func weightedMeanEmbeddings(
        _ items: [(speaker: String, embedding: [Float], weight: Double)]
    ) -> [String: [Float]] {
        var sums: [String: [Double]] = [:]
        var totals: [String: Double] = [:]
        for item in items {
            let dim = item.embedding.count
            guard dim > 0, item.weight > 0 else { continue }
            if let existing = sums[item.speaker], existing.count != dim { continue }
            var acc = sums[item.speaker] ?? [Double](repeating: 0, count: dim)
            for i in 0..<dim { acc[i] += Double(item.embedding[i]) * item.weight }
            sums[item.speaker] = acc
            totals[item.speaker, default: 0] += item.weight
        }
        var out: [String: [Float]] = [:]
        for (speaker, sum) in sums {
            guard let total = totals[speaker], total > 0 else { continue }
            out[speaker] = l2Normalized(sum.map { Float($0 / total) })
        }
        return out
    }

    /// L2-normalize a vector; returns the input unchanged when its norm is ~0.
    static func l2Normalized(_ v: [Float]) -> [Float] {
        let norm = (v.reduce(Float(0)) { $0 + $1 * $1 }).squareRoot()
        guard norm > 1e-9 else { return v }
        return v.map { $0 / norm }
    }

    // MARK: - Adapters

    /// Map workflow language code (en/uk/es/ru/auto/nil) to FluidAudio Language.
    /// Returns nil for "auto" or unknown codes so the SDK detects language itself.
    static func resolveLanguage(hint: String?) -> Language? {
        guard let code = hint?.lowercased(), !code.isEmpty, code != "auto" else { return nil }
        return Language(rawValue: code)
    }

    static func tokens(from result: ASRResult) -> [AsrToken] {
        guard let timings = result.tokenTimings, !timings.isEmpty else {
            // No per-token timing: synthesize one token for the whole utterance so
            // segment-building still works; loses word-level alignment but keeps schema valid.
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

    /// Load a WAV as 16 kHz mono Float32, averaging all channels. Explicit (L+R)/2
    /// for stereo (mic-L, system-R) avoids AVAudioConverter's unreliable channel
    /// reduction on untagged-layout WAVs. The on-disk WAV is never modified.
    static func readMonoFloat32(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0 else { return [] }

        // Scope the full-clip PCM buffer to this closure so it is released the
        // moment the mono [Float] exists, rather than living alongside the
        // resampler's input/output buffers (or the array the ASR and
        // diarization stages then hold). Halves the readMonoFloat32 peak.
        // (TECH-PERF2)
        let mono: [Float] = try {
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
            return mixDownToMono(inputBuffer)
        }()

        // Mono-to-mono AVAudioConverter is safe (no channel layout ambiguity) for the rate step.
        if format.sampleRate == 16_000 {
            return mono
        }
        return try resampleMono(mono, from: format.sampleRate, to: 16_000, url: url)
    }

    /// Visible for tests to verify (L+R)/2 against a synthetic stereo buffer.
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
