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
