import AVFoundation
import XCTest
@testable import MeetingPipe

/// Coverage for the waveform peak loader: on-disk cache round-trip,
/// stereo compute against a synthesized WAV, and the cache-invalidation
/// behavior when the source file changes.
final class WaveformPeaksTests: XCTestCase {

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mp-wf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        return dir
    }

    // MARK: equatable (TECH-A13 redraw gate)

    func test_equatable_distinguishes_content_not_just_shape() {
        // The Audio tab gates the static-waveform redraw on WaveformPeaks
        // equality. It must compare real content: two envelopes with the same
        // bin count and duration but different samples are NOT equal, otherwise
        // switching to a same-length meeting would show the previous waveform.
        let a = WaveformPeaks(left: [0.1, 0.2], right: [0.1, 0.2], durationSec: 10)
        let b = WaveformPeaks(left: [0.1, 0.2], right: [0.1, 0.2], durationSec: 10)
        let c = WaveformPeaks(left: [0.9, 0.8], right: [0.9, 0.8], durationSec: 10)
        XCTAssertEqual(a, b, "identical peaks must compare equal so an idle redraw is skipped")
        XCTAssertNotEqual(a, c, "same shape, different samples must compare unequal so the redraw fires")
    }

    // MARK: cache round-trip

    func test_cache_round_trip_preserves_peaks_and_duration() throws {
        let dir = try tempDir()
        let cacheURL = dir.appendingPathComponent("test.peaks")
        let peaks = WaveformPeaks(
            left: [0.0, 0.1, 0.5, 1.0, 0.25, 0.0],
            right: [0.1, 0.2, 0.3, 0.4, 0.5, 0.6],
            durationSec: 12.34
        )
        let mtime = Date(timeIntervalSince1970: 1_700_000_000)
        try WaveformPeaksLoader.writeCache(
            peaks, at: cacheURL,
            wavSize: 4242,
            wavMTime: mtime
        )
        let restored = try XCTUnwrap(WaveformPeaksLoader.readCache(
            at: cacheURL,
            expectedSize: 4242,
            expectedMTime: mtime
        ))
        XCTAssertEqual(restored.left, peaks.left)
        XCTAssertEqual(restored.right, peaks.right)
        XCTAssertEqual(restored.durationSec, 12.34, accuracy: 0.01)
    }

    func test_cache_invalidates_on_size_change() throws {
        let dir = try tempDir()
        let cacheURL = dir.appendingPathComponent("test.peaks")
        let peaks = WaveformPeaks(left: [0.5], right: [0.5], durationSec: 1)
        let mtime = Date(timeIntervalSince1970: 1_700_000_000)
        try WaveformPeaksLoader.writeCache(
            peaks, at: cacheURL,
            wavSize: 1000, wavMTime: mtime
        )
        XCTAssertNil(WaveformPeaksLoader.readCache(
            at: cacheURL, expectedSize: 2000, expectedMTime: mtime
        ))
    }

    func test_cache_invalidates_on_mtime_change() throws {
        let dir = try tempDir()
        let cacheURL = dir.appendingPathComponent("test.peaks")
        let peaks = WaveformPeaks(left: [0.5], right: [0.5], durationSec: 1)
        try WaveformPeaksLoader.writeCache(
            peaks, at: cacheURL,
            wavSize: 1000,
            wavMTime: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertNil(WaveformPeaksLoader.readCache(
            at: cacheURL,
            expectedSize: 1000,
            expectedMTime: Date(timeIntervalSince1970: 1_700_000_500)
        ))
    }

    func test_cache_returns_nil_for_missing_file() {
        let url = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).peaks")
        XCTAssertNil(WaveformPeaksLoader.readCache(
            at: url, expectedSize: 0, expectedMTime: Date()
        ))
    }

    // MARK: compute (against a synthesized stereo WAV)

    func test_compute_emits_distinct_left_and_right_peaks() throws {
        let dir = try tempDir()
        let wavURL = dir.appendingPathComponent("stereo.wav")
        // Left channel rises to 0.5; right channel rises to 1.0. The
        // computed peaks must mirror the per-channel scaling — a bug
        // that collapses both channels into one would fail this.
        try writeStereoWAV(
            at: wavURL,
            sampleRate: 16_000,
            seconds: 1.0
        ) { i, total in
            let frac = Float(i) / Float(total - 1)
            return (frac * 0.5, frac * 1.0)
        }
        let peaks = try WaveformPeaksLoader.compute(audioURL: wavURL)
        XCTAssertEqual(peaks.durationSec, 1.0, accuracy: 0.01)
        XCTAssertGreaterThan(peaks.binCount, 40)   // ~50 bins/sec
        // Late-file bins should be louder than early ones for both
        // channels, with the right channel ~2× louder than the left.
        let lastLeft = peaks.left.last ?? 0
        let lastRight = peaks.right.last ?? 0
        XCTAssertGreaterThan(lastLeft, 0.4)
        XCTAssertGreaterThan(lastRight, 0.8)
        XCTAssertGreaterThan(lastRight, lastLeft + 0.3)
    }

    func test_compute_renders_60_minute_synth_in_under_two_seconds() throws {
        // Mirrors the acceptance criterion (60-min file renders in <2 s).
        // Uses a low sample rate so the test stays fast on CI while
        // still exercising the chunk-iteration path.
        //
        // The 2 s budget assumes a release build. Debug builds skip
        // most optimisations and run the per-frame max/min loop 4-5×
        // slower on the same hardware (measured ~8 s on M-series at
        // -Onone). Use a generous budget under debug so a developer
        // running `swift test` locally doesn't see a spurious failure;
        // the release-mode acceptance criterion still gets enforced
        // by CI / production builds.
        #if DEBUG
        let budgetSec = 15.0
        #else
        let budgetSec = 2.0
        #endif
        let dir = try tempDir()
        let wavURL = dir.appendingPathComponent("long.wav")
        try writeStereoWAV(
            at: wavURL,
            sampleRate: 16_000,
            seconds: 60 * 60
        ) { _, _ in (0.1, 0.1) }
        let started = Date()
        let peaks = try WaveformPeaksLoader.compute(audioURL: wavURL)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(
            elapsed, budgetSec,
            "compute() took \(elapsed)s for a 60-min stereo wav"
        )
        XCTAssertEqual(peaks.durationSec, 3600.0, accuracy: 1.0)
    }

    // MARK: bin <-> time mapping

    func test_bin_at_time_clamps_within_range() {
        let peaks = WaveformPeaks(
            left: Array(repeating: 0.5, count: 100),
            right: Array(repeating: 0.5, count: 100),
            durationSec: 10
        )
        XCTAssertEqual(peaks.bin(at: 0.0), 0)
        XCTAssertEqual(peaks.bin(at: 5.0), 50)
        XCTAssertEqual(peaks.bin(at: 9.99), 99)
        // Overrun: clamped to last index.
        XCTAssertEqual(peaks.bin(at: 100), 99)
    }

    // MARK: WAV helpers

    /// Write a 16-bit signed PCM stereo WAV file at `at`. `sampleFn`
    /// returns `(left, right)` in [-1, 1] for each frame index. We use
    /// 16-bit PCM rather than Float32 because AVAudioFile up-converts
    /// any WAV format to its `processingFormat` of Float32 — that
    /// matches the production path which feeds Float32 buffers, so
    /// `compute()` exercises the same code path.
    private func writeStereoWAV(
        at url: URL,
        sampleRate: Int,
        seconds: Double,
        sampleFn: (Int, Int) -> (Float, Float)
    ) throws {
        let totalFrames = Int(Double(sampleRate) * seconds)
        let byteRate = sampleRate * 2 /*ch*/ * 2 /*bytes/sample*/
        let blockAlign: UInt16 = 4
        let dataSize = totalFrames * 4   // 2 channels × 2 bytes
        let riffSize = 36 + dataSize

        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(contentsOf: u32LE(UInt32(riffSize)))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(contentsOf: u32LE(16))           // fmt chunk size
        data.append(contentsOf: u16LE(1))            // PCM
        data.append(contentsOf: u16LE(2))            // channels
        data.append(contentsOf: u32LE(UInt32(sampleRate)))
        data.append(contentsOf: u32LE(UInt32(byteRate)))
        data.append(contentsOf: u16LE(blockAlign))
        data.append(contentsOf: u16LE(16))           // bits/sample
        data.append(contentsOf: Array("data".utf8))
        data.append(contentsOf: u32LE(UInt32(dataSize)))

        data.reserveCapacity(data.count + dataSize)
        for i in 0..<totalFrames {
            let (l, r) = sampleFn(i, totalFrames)
            data.append(contentsOf: i16LE(toInt16(l)))
            data.append(contentsOf: i16LE(toInt16(r)))
        }
        try data.write(to: url)
    }

    private func toInt16(_ f: Float) -> Int16 {
        let clamped = max(-1, min(1, f))
        return Int16(clamped * 32767)
    }

    private func u16LE(_ v: UInt16) -> [UInt8] {
        let le = v.littleEndian
        return withUnsafeBytes(of: le) { Array($0) }
    }

    private func u32LE(_ v: UInt32) -> [UInt8] {
        let le = v.littleEndian
        return withUnsafeBytes(of: le) { Array($0) }
    }

    private func i16LE(_ v: Int16) -> [UInt8] {
        let le = v.littleEndian
        return withUnsafeBytes(of: le) { Array($0) }
    }
}
