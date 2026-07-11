import XCTest
@testable import MeetingPipe

/// UX17: the pure silence-span derivation behind skip-silence, plus the rate
/// label formatting. The live AVAudioUnitTimePitch wiring is owner-eyeball; this
/// is the logic behind it.
final class SilenceScannerTests: XCTestCase {

    /// Peaks whose bins are 0.1 s each, same amplitude on both channels.
    private func peaks(_ amps: [Float]) -> WaveformPeaks {
        WaveformPeaks(left: amps, right: amps, durationSec: Double(amps.count) * 0.1)
    }

    /// Compare against expected (start, end) seconds with fp tolerance (binDuration
    /// is `durationSec / binCount`, so exact tenths are not representable).
    private func assertSpans(
        _ got: [SilenceScanner.Span],
        _ expected: [(Double, Double)],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(got.count, expected.count, "span count", file: file, line: line)
        for (g, e) in zip(got, expected) {
            XCTAssertEqual(g.start, e.0, accuracy: 0.01, file: file, line: line)
            XCTAssertEqual(g.end, e.1, accuracy: 0.01, file: file, line: line)
        }
    }

    func test_no_spans_when_all_loud() {
        let spans = SilenceScanner.spans(peaks: peaks([0.5, 0.6, 0.4, 0.7]), minDuration: 0.3)
        XCTAssertTrue(spans.isEmpty)
    }

    func test_detects_a_long_silence_span() {
        // bins: loud, then four silent (0.4 s), then loud
        let spans = SilenceScanner.spans(peaks: peaks([0.5, 0.0, 0.0, 0.0, 0.0, 0.5]), minDuration: 0.3)
        assertSpans(spans, [(0.1, 0.5)])
    }

    func test_ignores_a_short_pause() {
        // two silent bins = 0.2 s, below the 0.3 s floor
        let spans = SilenceScanner.spans(peaks: peaks([0.5, 0.0, 0.0, 0.5]), minDuration: 0.3)
        XCTAssertTrue(spans.isEmpty)
    }

    func test_trailing_silence_runs_to_end() {
        let spans = SilenceScanner.spans(peaks: peaks([0.5, 0.0, 0.0, 0.0, 0.0]), minDuration: 0.3)
        assertSpans(spans, [(0.1, 0.5)])
    }

    func test_threshold_breaks_a_run() {
        // a bin at 0.03 is above the 0.02 default threshold, so it splits the silence
        let spans = SilenceScanner.spans(peaks: peaks([0.0, 0.0, 0.03, 0.0, 0.0]), minDuration: 0.15)
        assertSpans(spans, [(0.0, 0.2), (0.3, 0.5)])
    }

    func test_empty_peaks_yields_no_spans() {
        XCTAssertTrue(SilenceScanner.spans(peaks: peaks([])).isEmpty)
    }

    @MainActor
    func test_rate_labels_and_options() {
        XCTAssertEqual(AudioPlaybackController.rateOptions, [1.0, 1.25, 1.5, 2.0])
        XCTAssertEqual(AudioPlaybackController.rateLabel(1.0), "1x")
        XCTAssertEqual(AudioPlaybackController.rateLabel(1.25), "1.25x")
        XCTAssertEqual(AudioPlaybackController.rateLabel(1.5), "1.5x")
        XCTAssertEqual(AudioPlaybackController.rateLabel(2.0), "2x")
    }
}
