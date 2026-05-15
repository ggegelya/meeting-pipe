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

    func test_default_runner_is_nil_when_flag_off_and_no_override() {
        TranscriptionService.overrideRunnerForTesting(nil)
        if TranscriptionService.featureEnabled {
            // Build was compiled with MP_USE_FLUIDAUDIO; the default
            // runner should be the FluidAudio one.
            let runner = try? XCTUnwrap(TranscriptionService.defaultRunner())
            XCTAssertEqual(runner?.backendName, "fluidaudio")
        } else {
            // Default daemon build: flag off, no override → nil so the
            // caller falls through to the existing Python pipeline path.
            XCTAssertNil(TranscriptionService.defaultRunner())
        }
    }

    func test_override_wins_over_flag() {
        TranscriptionService.overrideRunnerForTesting(StubRunner())
        let runner = TranscriptionService.defaultRunner()
        XCTAssertEqual(runner?.backendName, "stub")
    }
}
