import AVFoundation
import XCTest
@testable import MeetingPipe

final class TranscriptionSidecarTests: XCTestCase {

    func test_sidecar_round_trips_snake_case_keys() throws {
        let sidecar = TranscriptSidecar(
            language: "en",
            segments: [
                SidecarSegment(
                    start: 1.0,
                    end: 2.0,
                    text: "Hi.",
                    words: [SidecarWord(word: "Hi.", start: 1.0, end: 2.0)],
                    speaker: "speaker_0"
                )
            ],
            audioPath: "/tmp/x.wav",
            audioSeconds: 2.0,
            model: "parakeet-tdt-0.6b-v3",
            backend: "fluidaudio",
            diarization: true,
            diarizationFailed: false,
            diarizationFailureReason: nil,
            streaming: false,
            finalized: true
        )

        let data = try JSONEncoder().encode(sidecar)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        // Snake-case keys must match what `pipeline/src/mp/transcribe.py` writes,
        // so library code that reads either producer sees the same shape.
        XCTAssertEqual(json["language"] as? String, "en")
        XCTAssertEqual(json["audio_path"] as? String, "/tmp/x.wav")
        XCTAssertEqual(json["audio_seconds"] as? Double, 2.0)
        XCTAssertEqual(json["backend"] as? String, "fluidaudio")
        XCTAssertEqual(json["diarization"] as? Bool, true)
        XCTAssertEqual(json["diarization_failed"] as? Bool, false)
        XCTAssertEqual(json["streaming"] as? Bool, false)
        XCTAssertEqual(json["finalized"] as? Bool, true)

        let segs = try XCTUnwrap(json["segments"] as? [[String: Any]])
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs[0]["text"] as? String, "Hi.")
        XCTAssertEqual(segs[0]["speaker"] as? String, "speaker_0")
        XCTAssertNotNil(segs[0]["words"])

        let decoded = try JSONDecoder().decode(TranscriptSidecar.self, from: data)
        XCTAssertEqual(decoded, sidecar)
    }

    func test_write_to_url_produces_readable_file() throws {
        let sidecar = TranscriptSidecar(
            language: "uk",
            segments: [],
            audioPath: "/tmp/empty.wav",
            audioSeconds: 0,
            model: "parakeet-tdt-0.6b-v3",
            backend: "fluidaudio",
            diarization: false,
            diarizationFailed: true,
            diarizationFailureReason: "skipped: no segments",
            streaming: false,
            finalized: true
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidecar-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        try sidecar.write(to: url)
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(TranscriptSidecar.self, from: data)
        XCTAssertEqual(decoded.language, "uk")
        XCTAssertEqual(decoded.diarizationFailureReason, "skipped: no segments")
    }

    func test_write_lands_owner_only_permissions() throws {
        // SEC14: transcripts carry meeting content, so the writer lands them 0600
        // (like originals/ and the logs), not the 0644 default.
        let sidecar = TranscriptSidecar(
            language: "en", segments: [], audioPath: "/tmp/x.wav", audioSeconds: 0,
            model: "m", backend: "fluidaudio", diarization: false,
            diarizationFailed: false, diarizationFailureReason: nil,
            streaming: false, finalized: true
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidecar-perms-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        try sidecar.write(to: url)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
    }

    func test_speaker_embeddings_omitted_when_nil_present_when_set() throws {
        // Nil (the no-diarization common case) must keep the JSON byte-shape
        // identical to the pre-voiceprint sidecar: the key is absent, not null,
        // so the final transcript the Library reads is unchanged.
        let bare = TranscriptSidecar(
            language: "en", segments: [], audioPath: "/tmp/x.wav", audioSeconds: 0,
            model: "m", backend: "fluidaudio", diarization: false,
            diarizationFailed: false, diarizationFailureReason: nil,
            streaming: false, finalized: true
        )
        let bareJSON = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(bare)) as? [String: Any]
        )
        XCTAssertNil(bareJSON["speaker_embeddings"])

        var withEmb = bare
        withEmb.speakerEmbeddings = ["speaker_1": [0.1, 0.2], "speaker_2": [0.3, 0.4]]
        let data = try JSONEncoder().encode(withEmb)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let emb = try XCTUnwrap(json["speaker_embeddings"] as? [String: [Double]])
        XCTAssertEqual(emb["speaker_1"]?.count, 2)
        XCTAssertEqual(try JSONDecoder().decode(TranscriptSidecar.self, from: data), withEmb)
    }
}

final class FluidAudioRunnerAudioMixdownTests: XCTestCase {
    /// Locks in the stereo→mono downmix. Regression case for the
    /// "transcript only contains the mic side of the call" symptom: an
    /// unconfigured AVAudioConverter on macOS can silently fall through
    /// to channel-0 only when downmixing stereo, which loses the entire
    /// system-audio side of our (mic-L, system-R) recordings. The runner
    /// computes the mix in Swift instead and this test pins (L+R)/2.
    func test_stereo_mixdown_averages_both_channels() throws {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 2,
                interleaved: false
            )
        )
        let frameCount: AVAudioFrameCount = 4
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount

        let left = try XCTUnwrap(buffer.floatChannelData?[0])
        let right = try XCTUnwrap(buffer.floatChannelData?[1])
        // L: 1.0, 0.0, 0.5, -0.5     R: 0.0, 1.0, -0.5, 0.5
        // expected mono: 0.5, 0.5, 0.0, 0.0
        left[0]  = 1.0;  right[0]  = 0.0
        left[1]  = 0.0;  right[1]  = 1.0
        left[2]  = 0.5;  right[2]  = -0.5
        left[3]  = -0.5; right[3]  = 0.5

        let mono = FluidAudioRunner.mixDownToMono(buffer)
        XCTAssertEqual(mono.count, 4)
        XCTAssertEqual(mono[0], 0.5, accuracy: 1e-6)
        XCTAssertEqual(mono[1], 0.5, accuracy: 1e-6)
        XCTAssertEqual(mono[2], 0.0, accuracy: 1e-6)
        XCTAssertEqual(mono[3], 0.0, accuracy: 1e-6)
    }

    func test_mono_input_passes_through_unchanged() throws {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            )
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3))
        buffer.frameLength = 3
        let ch = try XCTUnwrap(buffer.floatChannelData?[0])
        ch[0] = 0.1; ch[1] = -0.2; ch[2] = 0.3
        let mono = FluidAudioRunner.mixDownToMono(buffer)
        XCTAssertEqual(mono, [0.1, -0.2, 0.3])
    }

    /// Write `channelData` (one [Float] per channel) to a 16-bit PCM WAV, the
    /// same encoding the daemon records. Returns the file URL.
    private func writePCM16Wav(channelData: [[Float]], sampleRate: Double = 16_000) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("perf2-\(UUID().uuidString).wav")
        let channels = AVAudioChannelCount(channelData.count)
        let frames = AVAudioFrameCount(channelData.first?.count ?? 0)
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: channels,
                interleaved: false
            )
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let dst = try XCTUnwrap(buffer.floatChannelData)
        for (c, samples) in channelData.enumerated() {
            for (i, sample) in samples.enumerated() { dst[c][i] = sample }
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Int(channels),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let outFile = try AVAudioFile(forWriting: url, settings: settings)
        try outFile.write(from: buffer)
        return url
    }

    /// End-to-end read of an already-16kHz-mono WAV: readMonoFloat32 returns
    /// the written PCM (within int16 quantization). This is the common fast
    /// path, and the one where the input PCM buffer is now scoped to free
    /// before return. There was no direct readMonoFloat32 coverage before.
    /// (TECH-PERF2)
    func test_readMonoFloat32_roundtrips_16k_mono() throws {
        let samples: [Float] = [0.0, 0.25, -0.5, 0.75]
        let url = try writePCM16Wav(channelData: [samples])
        defer { try? FileManager.default.removeItem(at: url) }

        let read = try FluidAudioRunner.readMonoFloat32(from: url)
        XCTAssertEqual(read.count, samples.count)
        for (i, sample) in samples.enumerated() {
            XCTAssertEqual(read[i], sample, accuracy: 1e-4)
        }
    }

    /// End-to-end read of a 16kHz stereo WAV (the production mic-L, system-R
    /// shape): readMonoFloat32 must return (L+R)/2 per frame. (TECH-PERF2)
    func test_readMonoFloat32_mixes_16k_stereo() throws {
        let left: [Float] = [1.0, 0.0, 0.5, -0.5]
        let right: [Float] = [0.0, 1.0, -0.5, 0.5]
        let url = try writePCM16Wav(channelData: [left, right])
        defer { try? FileManager.default.removeItem(at: url) }

        let read = try FluidAudioRunner.readMonoFloat32(from: url)
        XCTAssertEqual(read.count, 4)
        for (i, expected) in [Float(0.5), 0.5, 0.0, 0.0].enumerated() {
            XCTAssertEqual(read[i], expected, accuracy: 1e-4)
        }
    }
}

final class TranscriptionServiceRoutingTests: XCTestCase {

    private final class StubRunner: TranscriptionRunner {
        let backendName = "stub"
        func transcribe(wavURL: URL, languageHint: String?) async throws -> TranscriptSidecar {
            TranscriptSidecar(
                language: languageHint ?? "auto",
                segments: [],
                audioPath: wavURL.path,
                audioSeconds: 0,
                model: "stub",
                backend: backendName,
                diarization: false,
                diarizationFailed: false,
                diarizationFailureReason: nil,
                streaming: false,
                finalized: true
            )
        }
    }

    override func tearDown() {
        TranscriptionService.overrideRunnerForTesting(nil)
        super.tearDown()
    }

    func test_default_resolves_to_fluidaudio_runner() {
        let runner = TranscriptionService.makeRunner()
        XCTAssertEqual(runner.backendName, "fluidaudio")
    }

    func test_override_wins() {
        TranscriptionService.overrideRunnerForTesting(StubRunner())
        let runner = TranscriptionService.makeRunner()
        XCTAssertEqual(runner.backendName, "stub")
    }
}

final class FluidAudioRunnerEmbeddingTests: XCTestCase {

    private func norm(_ v: [Float]) -> Float {
        (v.reduce(0) { $0 + $1 * $1 }).squareRoot()
    }

    func test_weighted_mean_is_duration_weighted_and_l2_normalized() throws {
        let out = FluidAudioRunner.weightedMeanEmbeddings([
            (speaker: "speaker_1", embedding: [1, 0], weight: 9),
            (speaker: "speaker_1", embedding: [0, 1], weight: 1),
            (speaker: "speaker_2", embedding: [3, 4], weight: 2),
        ])
        // speaker_1: (9*[1,0] + 1*[0,1]) / 10 = [0.9, 0.1], then L2-normalized.
        let s1 = try XCTUnwrap(out["speaker_1"])
        XCTAssertEqual(s1[0], 0.9938, accuracy: 1e-3)
        XCTAssertEqual(s1[1], 0.1104, accuracy: 1e-3)
        XCTAssertEqual(norm(s1), 1.0, accuracy: 1e-4)
        // speaker_2: single [3,4] turn normalizes to [0.6, 0.8].
        let s2 = try XCTUnwrap(out["speaker_2"])
        XCTAssertEqual(s2[0], 0.6, accuracy: 1e-4)
        XCTAssertEqual(s2[1], 0.8, accuracy: 1e-4)
    }

    func test_zero_weight_ragged_and_empty_are_dropped() {
        // No positive-weight segment -> speaker dropped entirely.
        XCTAssertTrue(FluidAudioRunner.weightedMeanEmbeddings([
            (speaker: "speaker_1", embedding: [1, 0], weight: 0),
        ]).isEmpty)
        // Empty input -> empty output.
        XCTAssertTrue(FluidAudioRunner.weightedMeanEmbeddings([]).isEmpty)
        // A ragged-dimension segment is skipped; the first still yields a vector.
        let out = FluidAudioRunner.weightedMeanEmbeddings([
            (speaker: "speaker_1", embedding: [1, 0, 0], weight: 1),
            (speaker: "speaker_1", embedding: [0, 1], weight: 5),
        ])
        XCTAssertEqual(out["speaker_1"]?.count, 3)
    }
}
