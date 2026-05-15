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

final class TranscriptionBackendNormalizeTests: XCTestCase {
    func test_nil_returns_fluidaudio_default() {
        XCTAssertEqual(TranscriptionBackend.normalize(nil), TranscriptionBackend.fluidaudio)
    }

    func test_recognised_canonical_values_pass_through() {
        XCTAssertEqual(TranscriptionBackend.normalize("fluidaudio"), TranscriptionBackend.fluidaudio)
        XCTAssertEqual(TranscriptionBackend.normalize("pipeline"), TranscriptionBackend.pipeline)
    }

    func test_aliases_are_accepted() {
        XCTAssertEqual(TranscriptionBackend.normalize("parakeet"), TranscriptionBackend.fluidaudio)
        XCTAssertEqual(TranscriptionBackend.normalize("MLX"), TranscriptionBackend.pipeline)
        XCTAssertEqual(TranscriptionBackend.normalize("  whisper "), TranscriptionBackend.pipeline)
    }

    func test_unknown_string_falls_back_to_fluidaudio() {
        XCTAssertEqual(TranscriptionBackend.normalize("turbocharged"), TranscriptionBackend.fluidaudio)
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

    func test_fluidaudio_resolves_to_runner() throws {
        let runner = try XCTUnwrap(TranscriptionService.makeRunner(for: TranscriptionBackend.fluidaudio))
        XCTAssertEqual(runner.backendName, TranscriptionBackend.fluidaudio)
    }

    func test_pipeline_resolves_to_nil() {
        XCTAssertNil(TranscriptionService.makeRunner(for: TranscriptionBackend.pipeline))
    }

    func test_override_wins_over_backend_string() {
        TranscriptionService.overrideRunnerForTesting(StubRunner())
        let runner = TranscriptionService.makeRunner(for: TranscriptionBackend.pipeline)
        XCTAssertEqual(runner?.backendName, "stub")
    }
}
