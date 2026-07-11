import Foundation

/// Derives silent spans from the waveform peaks cache for skip-silence (UX17).
/// Pure over `WaveformPeaks` (no AVFoundation, no file access), so the hop logic
/// is unit-testable without a live engine.
enum SilenceScanner {
    struct Span: Equatable {
        let start: Double
        let end: Double
    }

    /// Contiguous runs where the louder of the two channels stays below `threshold`
    /// for at least `minDuration` seconds. `threshold` is a fraction of full scale
    /// (peaks are max-abs per bin); `minDuration` keeps natural short pauses intact.
    static func spans(
        peaks: WaveformPeaks,
        threshold: Float = 0.02,
        minDuration: Double = 1.5
    ) -> [Span] {
        let n = peaks.binCount
        let binDuration = peaks.binDuration
        guard n > 0, binDuration > 0 else { return [] }

        var out: [Span] = []
        var runStart: Int?
        for i in 0..<n {
            let amp = max(abs(peaks.left[i]), abs(peaks.right[i]))
            if amp < threshold {
                if runStart == nil { runStart = i }
            } else if let s = runStart {
                appendIfLong(&out, from: s, to: i, binDuration: binDuration, minDuration: minDuration)
                runStart = nil
            }
        }
        if let s = runStart {
            appendIfLong(&out, from: s, to: n, binDuration: binDuration, minDuration: minDuration)
        }
        return out
    }

    private static func appendIfLong(
        _ out: inout [Span],
        from: Int,
        to: Int,
        binDuration: Double,
        minDuration: Double
    ) {
        let start = Double(from) * binDuration
        let end = Double(to) * binDuration
        if end - start >= minDuration {
            out.append(Span(start: start, end: end))
        }
    }
}
