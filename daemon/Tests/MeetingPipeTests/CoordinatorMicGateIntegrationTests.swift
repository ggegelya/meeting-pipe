import XCTest
@testable import MeetingPipe
@testable import MeetingPipeCore

/// Smoke tests for the TECH-G-MIC + TECH-C7 wiring: the recorder's
/// verdict latch + writer apply, and the config knob plumbing for the
/// MicOnlySilenceBackstop window.
///
/// Full end-to-end coverage of the verdict pipeline (AX scrape -> gate
/// state -> verdict stream -> recorder buffer mutation) lives in
/// `MeetingPipeCoreTests` against fakes for the AX/HAL buses. These
/// daemon-side tests just confirm the wiring between the executable
/// surfaces and the library surfaces.
final class CoordinatorMicGateIntegrationTests: XCTestCase {

    // MARK: - Recorder verdict latch

    func test_recorder_initial_verdict_is_uncertain_not_started() {
        let recorder = MeetingRecorder()
        if case .uncertain(let reasons) = recorder.debugCurrentMicGateVerdict {
            XCTAssertEqual(reasons, ["not_started"])
        } else {
            XCTFail("expected initial verdict to be .uncertain")
        }
    }

    func test_setMicGateVerdict_updates_recorder_state() {
        let recorder = MeetingRecorder()
        let verdict: MicGateVerdict = .mutedByApp(axLabel: "Unmute", locale: "en")
        recorder.setMicGateVerdict(verdict)
        XCTAssertEqual(recorder.debugCurrentMicGateVerdict, verdict)

        let next: MicGateVerdict = .hot(reason: .voiceActivityDetected)
        recorder.setMicGateVerdict(next)
        XCTAssertEqual(recorder.debugCurrentMicGateVerdict, next)
    }

    // MARK: - Writer apply

    /// A `.mutedByApp` verdict applied to a buffer of non-zero samples
    /// must zero them after the 20 ms fade transitions out. We give the
    /// writer a long buffer and a non-hot initial state so the writer
    /// takes the direct zero path without entering a fade.
    func test_mutedByApp_verdict_zeroes_buffer_via_writer() {
        let writer = MicGateWriter(sampleRate: 16_000, fadeDurationMillis: 20)
        // Prime the writer's last-state to "not hot" so apply() short
        // circuits to fillZero rather than starting a fade.
        var primer = [Float](repeating: 0, count: 64)
        primer.withUnsafeMutableBufferPointer { buf in
            writer.apply(verdict: .mutedByHardware, to: buf)
        }

        var samples = [Float](repeating: 0.5, count: 1024)
        samples.withUnsafeMutableBufferPointer { buf in
            let result = writer.apply(verdict: .mutedByApp(axLabel: "Unmute", locale: "en"), to: buf)
            XCTAssertEqual(result.action, .zeroed)
        }
        XCTAssertTrue(samples.allSatisfy { $0 == 0 }, "every sample should be zeroed for a .mutedByApp verdict")
    }

    func test_hot_verdict_passes_buffer_through_after_fade() {
        let writer = MicGateWriter(sampleRate: 16_000, fadeDurationMillis: 20)
        // First buffer flips from not-hot to hot, so the fade-in
        // consumes the leading samples. Run a long-enough buffer to
        // exhaust the fade window, then a second buffer should pass
        // through untouched.
        let fadeFrames = Int(16_000 * 0.020) + 8
        var first = [Float](repeating: 1.0, count: fadeFrames)
        first.withUnsafeMutableBufferPointer { buf in
            writer.apply(verdict: .hot(reason: .rmsAboveOpenThreshold), to: buf)
        }

        var second = [Float](repeating: 0.25, count: 256)
        second.withUnsafeMutableBufferPointer { buf in
            let result = writer.apply(verdict: .hot(reason: .rmsAboveOpenThreshold), to: buf)
            XCTAssertEqual(result.action, .passedThrough)
        }
        XCTAssertTrue(second.allSatisfy { $0 == 0.25 }, "passthrough must not mutate samples")
    }

    // MARK: - Backstop window read from Config

    func test_config_default_mic_only_silence_seconds_is_900() {
        // TECH-END3: the single idle backstop auto-stops at 15 min (was 480 s).
        let cfg = Config.defaultFallback()
        XCTAssertEqual(cfg.detection.micOnlySilenceSec, 900)
    }

    func test_config_loads_custom_mic_only_silence_seconds() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mp-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.toml")
        try """
        [detection]
        mic_only_silence_seconds = 120
        """.write(to: url, atomically: true, encoding: .utf8)

        let cfg = try Config.load(from: url)
        XCTAssertEqual(cfg.detection.micOnlySilenceSec, 120)
    }

    func test_config_store_round_trips_mic_only_silence_seconds() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mp-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.toml")

        let store = try ConfigStore(configURL: url)
        XCTAssertEqual(store.micOnlySilenceSec, 900)

        store.micOnlySilenceSec = 60
        try store.saveNow()

        let reloaded = try ConfigStore(configURL: url)
        XCTAssertEqual(reloaded.micOnlySilenceSec, 60)
    }
}
