import XCTest
@testable import MeetingPipe

/// REC9: the merge's length policy and the duration-based promote gate.
///
/// The defect these pin: `amerge` has no length option, so the bare filter ended the
/// merged final at the SHORTER capture channel and `produceFinal` then deleted both
/// intermediates. Measured across the owner's log, 140 of 153 recordings lost mic
/// tail that way, and one lost 35.9 s of 41.2 s and reported success.
///
/// The REC1 / REC7 tests over this type (intermediates survive a failed merge, no
/// partial final at the canonical path) live in `MeetingRecorderTests`, where they
/// were written before ARCH5 moved the code here.
final class RecordingPostProcessorTests: XCTestCase {

    // MARK: - Length policy (pure)

    /// The ordinary case, and the one the bare filter got wrong: a system channel
    /// that stops early must not shorten the recording.
    func test_mergeLengths_targets_the_longer_channel() {
        let lengths = RecordingPostProcessor.mergeLengths(
            micDurationSec: 10, systemDurationSec: 3, systemHeadOffsetSec: 0
        )
        XCTAssertEqual(lengths.targetDurationSec, 10)
        XCTAssertEqual(lengths.expectedDurationSec, 10)
        XCTAssertTrue(lengths.padMic)
        XCTAssertEqual(lengths.systemDelayMs, 0)
    }

    /// The 2026-07-15 shape: system capture came up 35.92 s into a 41.2 s meeting
    /// and carried the last 5.28 s. Padding the tail alone would place those 5.28 s
    /// at sample 0, against the wrong mic timestamps; the delay puts them back.
    func test_mergeLengths_delays_a_late_system_channel_to_where_it_was_captured() {
        let lengths = RecordingPostProcessor.mergeLengths(
            micDurationSec: 41.2, systemDurationSec: 5.28, systemHeadOffsetSec: 35.92
        )
        XCTAssertEqual(lengths.systemDelayMs, 35920)
        XCTAssertEqual(lengths.targetDurationSec ?? 0, 41.2, accuracy: 0.001)
    }

    /// A delayed system channel that runs past the mic extends the target rather
    /// than being cut back to the mic's length.
    func test_mergeLengths_extends_past_the_mic_for_a_late_channel_that_outlasts_it() {
        let lengths = RecordingPostProcessor.mergeLengths(
            micDurationSec: 10, systemDurationSec: 3, systemHeadOffsetSec: 8
        )
        XCTAssertEqual(lengths.systemDelayMs, 8000)
        XCTAssertEqual(lengths.targetDurationSec ?? 0, 11, accuracy: 0.001)
    }

    /// The routine capture skew (CAP1: median 0.21 s over 153 recordings) is not a
    /// late start, and moving every normal recording by it would be a regression of
    /// its own. Below the floor the offset is dropped, and the tail padding alone
    /// carries the fix.
    func test_mergeLengths_ignores_the_routine_capture_skew() {
        let lengths = RecordingPostProcessor.mergeLengths(
            micDurationSec: 600, systemDurationSec: 599.79, systemHeadOffsetSec: 0.21
        )
        XCTAssertEqual(lengths.systemDelayMs, 0)
        XCTAssertEqual(lengths.targetDurationSec, 600)
    }

    /// A negative offset is a clock artefact, never a system channel that started
    /// before the recording did.
    func test_mergeLengths_clamps_a_negative_offset() {
        let lengths = RecordingPostProcessor.mergeLengths(
            micDurationSec: 10, systemDurationSec: 10, systemHeadOffsetSec: -3
        )
        XCTAssertEqual(lengths.systemDelayMs, 0)
        XCTAssertEqual(lengths.targetDurationSec, 10)
    }

    /// When a duration cannot be read there is no target to cut at, so only the
    /// system leg is padded and the merge ends with the mic: still strictly longer
    /// than the `min()` the bare filter produced, and biased toward the channel the
    /// owner cannot re-obtain.
    func test_mergeLengths_falls_back_to_the_mic_when_the_system_duration_is_unreadable() {
        let lengths = RecordingPostProcessor.mergeLengths(
            micDurationSec: 10, systemDurationSec: nil, systemHeadOffsetSec: 0
        )
        XCTAssertFalse(lengths.padMic, "padding both legs with no -t makes the merge infinite")
        XCTAssertNil(lengths.targetDurationSec)
        XCTAssertEqual(lengths.expectedDurationSec, 10, "the output still has a length to be checked against")
    }

    /// Nothing measurable at all degrades to REC1's byte floor rather than
    /// inventing an expectation.
    func test_mergeLengths_expects_nothing_when_neither_duration_reads() {
        let lengths = RecordingPostProcessor.mergeLengths(
            micDurationSec: nil, systemDurationSec: nil, systemHeadOffsetSec: 0
        )
        XCTAssertNil(lengths.targetDurationSec)
        XCTAssertNil(lengths.expectedDurationSec)
    }

    // MARK: - Promote gate (pure)

    /// The exact numbers that were promoted on 2026-07-15: a 192,078-byte, 3 s
    /// output for a 41.2 s capture cleared the byte floor trivially.
    func test_outputIsPlausible_refuses_the_2026_07_15_truncation() {
        XCTAssertFalse(RecordingPostProcessor.outputIsPlausible(
            byteCount: 192_078, producedDurationSec: 5.28, expectedDurationSec: 41.2
        ))
    }

    /// The tolerance is slack for resampler rounding, not a budget for lost audio.
    func test_outputIsPlausible_tolerates_rounding_but_not_loss() {
        XCTAssertTrue(RecordingPostProcessor.outputIsPlausible(
            byteCount: 1_000_000, producedDurationSec: 9.9, expectedDurationSec: 10
        ))
        XCTAssertFalse(RecordingPostProcessor.outputIsPlausible(
            byteCount: 1_000_000, producedDurationSec: 9.0, expectedDurationSec: 10
        ))
    }

    /// REC1's byte floor survives underneath the duration check.
    func test_outputIsPlausible_keeps_the_byte_floor() {
        XCTAssertFalse(RecordingPostProcessor.outputIsPlausible(
            byteCount: 2048, producedDurationSec: 10, expectedDurationSec: 10
        ))
    }

    /// An expectation that cannot be checked fails closed: a refused merge costs a
    /// retry, a promoted one costs the meeting.
    func test_outputIsPlausible_fails_closed_on_an_unreadable_output() {
        XCTAssertFalse(RecordingPostProcessor.outputIsPlausible(
            byteCount: 1_000_000, producedDurationSec: nil, expectedDurationSec: 10
        ))
        XCTAssertTrue(
            RecordingPostProcessor.outputIsPlausible(
                byteCount: 1_000_000, producedDurationSec: nil, expectedDurationSec: nil
            ),
            "with nothing to compare against, the byte floor is the whole check"
        )
    }

    /// The same rule against a real file, so the header read and the predicate are
    /// pinned together rather than only in the abstract.
    func test_producedPlausibleOutput_refuses_a_short_file_on_disk() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("short.wav")
        try makeWavData(seconds: 3).write(to: url)

        XCTAssertFalse(RecordingPostProcessor.producedPlausibleOutput(at: url, expectedDurationSec: 10))
        XCTAssertTrue(RecordingPostProcessor.producedPlausibleOutput(at: url, expectedDurationSec: 3))
        XCTAssertTrue(RecordingPostProcessor.producedPlausibleOutput(at: url))
    }

    // MARK: - The merge itself (real ffmpeg)

    /// Acceptance: a 10 s mic and a 3 s system produce a 10 s final, with the system
    /// channel silent where it had no audio. Before REC9 this produced 3 s and
    /// deleted both intermediates (reproduced by hand on 2026-08-03).
    func test_produceFinal_keeps_the_whole_mic_when_the_system_channel_stops_early() async throws {
        try requireFFmpeg()
        let dir = try makeTempDir()
        let mic = dir.appendingPathComponent("20260715-142800.mic.wav")
        let system = dir.appendingPathComponent("20260715-142800.system.wav")
        let final = dir.appendingPathComponent("20260715-142800.wav")
        try makeWavData(seconds: 10, amplitude: 8000).write(to: mic)
        try makeWavData(seconds: 3, channels: 2, amplitude: 8000).write(to: system)

        let ok = await RecordingPostProcessor.produceFinal(
            mic: mic, system: system, final: final, hasMic: true, hasSystem: true
        )

        XCTAssertTrue(ok)
        let duration = try XCTUnwrap(RecordingPostProcessor.audioDurationSec(of: final))
        XCTAssertEqual(duration, 10, accuracy: 0.05, "the final must not end at the shorter channel")
        XCTAssertGreaterThan(try peak(final, channel: 0, from: 8.5, to: 9.5), 4000, "the mic tail survived")
        XCTAssertLessThan(try peak(final, channel: 1, from: 8.5, to: 9.5), 100, "the system channel is padded silent")
    }

    /// Acceptance: a system channel that started late lands at its offset rather
    /// than at sample 0. Padding the tail alone would put the recovered audio
    /// against the wrong mic timestamps, which is worse than losing it, because it
    /// reads as a real transcript.
    func test_produceFinal_places_a_late_system_channel_at_its_offset() async throws {
        try requireFFmpeg()
        let dir = try makeTempDir()
        let mic = dir.appendingPathComponent("20260715-142800.mic.wav")
        let system = dir.appendingPathComponent("20260715-142800.system.wav")
        let final = dir.appendingPathComponent("20260715-142800.wav")
        try makeWavData(seconds: 10, amplitude: 8000).write(to: mic)
        try makeWavData(seconds: 3, channels: 2, amplitude: 8000).write(to: system)

        let ok = await RecordingPostProcessor.produceFinal(
            mic: mic, system: system, final: final, hasMic: true, hasSystem: true,
            systemHeadOffsetSec: 5
        )

        XCTAssertTrue(ok)
        let duration = try XCTUnwrap(RecordingPostProcessor.audioDurationSec(of: final))
        XCTAssertEqual(duration, 10, accuracy: 0.05)
        XCTAssertLessThan(try peak(final, channel: 1, from: 1, to: 4), 100, "silent before the capture started")
        XCTAssertGreaterThan(try peak(final, channel: 1, from: 5.5, to: 7.5), 4000, "audio sits in the window it was captured in")
        XCTAssertLessThan(try peak(final, channel: 1, from: 8.5, to: 9.5), 100, "silent after the 3 s it carried")
    }

    /// Acceptance: an under-length result is refused, both intermediates are kept,
    /// and a breadcrumb explains why. Driven with a stand-in ffmpeg that exits 0
    /// having written a short file, which is exactly the shape the byte floor waved
    /// through: a clean exit status is not evidence that the audio survived.
    func test_produceFinal_refuses_a_short_merge_and_keeps_both_intermediates() async throws {
        let dir = try makeTempDir()
        let mic = dir.appendingPathComponent("20260715-142800.mic.wav")
        let system = dir.appendingPathComponent("20260715-142800.system.wav")
        let final = dir.appendingPathComponent("20260715-142800.wav")
        try makeWavData(seconds: 10, amplitude: 8000).write(to: mic)
        try makeWavData(seconds: 10, channels: 2, amplitude: 8000).write(to: system)

        let truncated = dir.appendingPathComponent("truncated.wav")
        try makeWavData(seconds: 1, amplitude: 8000).write(to: truncated)
        setenv("MEETINGPIPE_FFMPEG", try fakeFFmpeg(in: dir, writing: truncated).path, 1)
        defer { unsetenv("MEETINGPIPE_FFMPEG") }

        let ok = await RecordingPostProcessor.produceFinal(
            mic: mic, system: system, final: final, hasMic: true, hasSystem: true
        )

        XCTAssertFalse(ok)
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: final.path), "a short merge must never reach the canonical path")
        XCTAssertTrue(fm.fileExists(atPath: mic.path), "mic.wav is the only copy of the owner's voice")
        XCTAssertTrue(fm.fileExists(atPath: system.path))
        XCTAssertFalse(fm.fileExists(atPath: RecordingPostProcessor.mergingTempURL(forFinal: final).path))

        let breadcrumb = RecordingPostProcessor.recordFailURL(forFinal: final)
        XCTAssertTrue(fm.fileExists(atPath: breadcrumb.path))
        let payload = try JSONSerialization.jsonObject(with: Data(contentsOf: breadcrumb)) as? [String: Any]
        let reason = payload?["reason"] as? String ?? ""
        XCTAssertTrue(reason.contains("REC9"), "the breadcrumb names the length refusal, not a generic failure: \(reason)")
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rec9-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// A PCM WAV of `seconds` at a constant amplitude, so a window of the merged
    /// output can be told apart from padding.
    private func makeWavData(
        seconds: Double,
        sampleRate: UInt32 = 48000,
        channels: UInt16 = 1,
        amplitude: Int16 = 0
    ) -> Data {
        let bytesPerSample = 2
        let frames = Int(Double(sampleRate) * seconds)
        let payloadBytes = frames * Int(channels) * bytesPerSample
        let byteRate = sampleRate * UInt32(channels) * UInt32(bytesPerSample)

        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(36 + payloadBytes).littleEndian, Array.init))
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: channels.littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: (channels * UInt16(bytesPerSample)).littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian, Array.init))
        data.append(contentsOf: "data".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(payloadBytes).littleEndian, Array.init))

        var payload = [UInt8](repeating: 0, count: payloadBytes)
        if amplitude != 0 {
            let low = UInt8(truncatingIfNeeded: amplitude)
            let high = UInt8(truncatingIfNeeded: amplitude >> 8)
            for i in stride(from: 0, to: payloadBytes - 1, by: 2) {
                payload[i] = low
                payload[i + 1] = high
            }
        }
        data.append(contentsOf: payload)
        return data
    }

    /// Loudest absolute sample on `channel` over `[from, to)` seconds of a 16-bit
    /// PCM WAV, so a padded-silent stretch reads apart from a captured one. `Int32`
    /// because `abs(Int16.min)` does not fit an `Int16`.
    private func peak(_ url: URL, channel: Int, from: Double, to: Double) throws -> Int32 {
        let data = try Data(contentsOf: url)
        let dataChunk = try XCTUnwrap(data.range(of: Data("data".utf8), options: [], in: 12..<data.count))
        let fmtBody = try XCTUnwrap(data.range(of: Data("fmt ".utf8))).upperBound + 4
        let channels = Int(data.subdata(in: (fmtBody + 2)..<(fmtBody + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) })
        let rate = Int(data.subdata(in: (fmtBody + 4)..<(fmtBody + 8)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        let payload = dataChunk.upperBound + 4

        var loudest: Int32 = 0
        let firstFrame = Int(from * Double(rate))
        let lastFrame = Int(to * Double(rate))
        for frame in firstFrame..<lastFrame {
            let offset = payload + (frame * channels + channel) * 2
            guard offset + 2 <= data.count else { break }
            let sample = data.subdata(in: offset..<(offset + 2)).withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }
            loudest = max(loudest, abs(Int32(sample)))
        }
        return loudest
    }

    /// A stand-in ffmpeg that ignores its arguments, drops `source` at the output
    /// path, and exits 0.
    private func fakeFFmpeg(in dir: URL, writing source: URL) throws -> URL {
        let script = dir.appendingPathComponent("fake-ffmpeg")
        let body = """
        #!/bin/sh
        for last; do :; done
        /bin/cp "\(source.path)" "$last"
        exit 0
        """
        try Data(body.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    private func requireFFmpeg() throws {
        if RecordingPostProcessor.findFFmpeg() != nil { return }
        if ProcessInfo.processInfo.environment["CI"] == "true" {
            struct FFmpegUnavailableOnCI: Error, CustomStringConvertible {
                var description: String {
                    "ffmpeg missing on CI: the REC9 merge-length tests could not run. "
                        + "ci.yml is supposed to install it; the capture-preservation path is now unverified."
                }
            }
            throw FFmpegUnavailableOnCI()
        }
        throw XCTSkip("ffmpeg not available (local run)")
    }
}
