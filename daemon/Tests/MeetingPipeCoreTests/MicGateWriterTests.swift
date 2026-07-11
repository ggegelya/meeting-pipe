import XCTest
@testable import MeetingPipeCore

final class MicGateWriterTests: XCTestCase {

    private func makeBuffer(_ samples: [Float]) -> [Float] {
        return samples
    }

    private func apply(
        _ writer: MicGateWriter,
        verdict: MicGateVerdict,
        samples: [Float]
    ) -> ([Float], MicGateWriter.ApplyResult) {
        var copy = samples
        let result = copy.withUnsafeMutableBufferPointer { buffer in
            writer.apply(verdict: verdict, to: buffer)
        }
        return (copy, result)
    }

    func test_hot_to_hot_passes_through_unchanged() {
        // 0ms fade so the initial muted->hot transition completes on
        // the first sample and the second call observes steady state.
        let writer = MicGateWriter(sampleRate: 48_000, fadeDurationMillis: 0)
        _ = apply(writer, verdict: .hot(reason: .voiceActivityDetected), samples: [0.5, 0.5, 0.5])
        let (out, result) = apply(writer, verdict: .hot(reason: .rmsAboveOpenThreshold), samples: [0.5, 0.5, 0.5])
        XCTAssertEqual(out, [0.5, 0.5, 0.5])
        XCTAssertEqual(result.action, .passedThrough)
    }

    func test_muted_to_muted_zeroes_buffer() {
        let writer = MicGateWriter(sampleRate: 48_000)
        let (out, result) = apply(writer, verdict: .silentByRMS(dwellMillis: 400), samples: [0.5, 0.5, 0.5])
        XCTAssertEqual(out, [0.0, 0.0, 0.0])
        XCTAssertEqual(result.action, .zeroed)
    }

    func test_forceMuted_zeroes_even_a_hot_verdict() {
        // MIC14: the off-the-record toggle forces the muted path under the regulated gate, so a
        // hot verdict (the user speaking) is still zeroed - no off-record audio reaches disk.
        let writer = MicGateWriter(sampleRate: 48_000, fadeDurationMillis: 0)
        var samples: [Float] = [0.5, 0.5, 0.5]
        let result = samples.withUnsafeMutableBufferPointer { buffer in
            writer.apply(verdict: .hot(reason: .voiceActivityDetected), forceMuted: true, to: buffer)
        }
        XCTAssertEqual(samples, [0.0, 0.0, 0.0])
        XCTAssertEqual(result.action, .zeroed)
    }

    func test_hot_to_muted_applies_fade_out() {
        // 48kHz, 20ms = 960 samples.
        let writer = MicGateWriter(sampleRate: 48_000, fadeDurationMillis: 1)
        // 48kHz, 1ms = 48 samples.
        _ = apply(writer, verdict: .hot(reason: .voiceActivityDetected), samples: Array(repeating: 1.0, count: 48))

        let samples = Array(repeating: Float(1.0), count: 96)
        let (out, result) = apply(writer, verdict: .mutedByApp(axLabel: "Unmute", locale: "en"), samples: samples)
        XCTAssertEqual(result.action, .fadedOut)
        XCTAssertEqual(result.samplesFaded, 48)
        // First sample should be unchanged (gain 1.0).
        XCTAssertEqual(out[0], 1.0, accuracy: 0.001)
        // Halfway through the fade should be around 0.5.
        XCTAssertEqual(out[24], 0.5, accuracy: 0.05)
        // Tail past the fade should be silent.
        XCTAssertEqual(out[48], 0.0, accuracy: 0.001)
        XCTAssertEqual(out[95], 0.0, accuracy: 0.001)
    }

    func test_muted_to_hot_applies_fade_in() {
        let writer = MicGateWriter(sampleRate: 48_000, fadeDurationMillis: 1)
        _ = apply(writer, verdict: .mutedByApp(axLabel: "Unmute", locale: "en"), samples: Array(repeating: 1.0, count: 48))

        let samples = Array(repeating: Float(1.0), count: 96)
        let (out, result) = apply(writer, verdict: .hot(reason: .voiceActivityDetected), samples: samples)
        XCTAssertEqual(result.action, .fadedIn)
        // First sample should be near zero.
        XCTAssertEqual(out[0], 0.0, accuracy: 0.001)
        // Halfway through.
        XCTAssertEqual(out[24], 0.5, accuracy: 0.05)
        // Past the fade, samples pass through.
        XCTAssertEqual(out[48], 1.0, accuracy: 0.001)
        XCTAssertEqual(out[95], 1.0, accuracy: 0.001)
    }

    func test_buffer_length_always_matches_input_length() {
        let writer = MicGateWriter(sampleRate: 48_000)
        let cases: [MicGateVerdict] = [
            .hot(reason: .voiceActivityDetected),
            .mutedByHardware,
            .silentByRMS(dwellMillis: 400),
            .uncertain(reasons: ["test"])
        ]
        for verdict in cases {
            let (out, _) = apply(writer, verdict: verdict, samples: [0.1, 0.2, 0.3, 0.4])
            XCTAssertEqual(out.count, 4, "Writer must never resize the buffer")
        }
    }

    func test_reset_drops_pending_fade() {
        let writer = MicGateWriter(sampleRate: 48_000, fadeDurationMillis: 1000)
        _ = apply(writer, verdict: .hot(reason: .voiceActivityDetected), samples: [1.0])
        _ = apply(writer, verdict: .mutedByApp(axLabel: "Unmute", locale: "en"), samples: [1.0])
        writer.reset()
        let (out, result) = apply(writer, verdict: .silentByRMS(dwellMillis: 0), samples: [1.0])
        XCTAssertEqual(out, [0.0])
        XCTAssertEqual(result.action, .zeroed)
    }
}
