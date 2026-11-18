import XCTest
@testable import MeetingPipe
import MeetingPipeTestSupport

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
        setenv("MEETINGPIPE_FFMPEG", try FakeFFmpeg.copying(truncated, in: dir).path, 1)
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

    // MARK: - DEP2 / F052: no ffmpeg is a failed merge, never a mic-only success

    /// Both channels present and no ffmpeg: the old branch renamed `mic.wav` onto the final and reported
    /// success, which hid the stem from the orphan sweep and published a call with the far side missing.
    func test_no_ffmpeg_keeps_both_channels_and_writes_no_final_F052() async throws {
        let dir = try makeTempDir()
        let logs = dir.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        setenv("MEETINGPIPE_LOGS_DIR", logs.path, 1)
        defer { unsetenv("MEETINGPIPE_LOGS_DIR") }
        let mic = dir.appendingPathComponent("rec.mic.wav")
        let system = dir.appendingPathComponent("rec.system.wav")
        let final = dir.appendingPathComponent("rec.wav")
        try makeWavData(seconds: 1.0, amplitude: 1000).write(to: mic)
        try makeWavData(seconds: 1.0, amplitude: 2000).write(to: system)
        let micBytes = try Data(contentsOf: mic)
        let systemBytes = try Data(contentsOf: system)

        let ok = await RecordingPostProcessor.produceFinal(
            mic: mic, system: system, final: final, hasMic: true, hasSystem: true,
            locateFFmpeg: { nil }
        )

        XCTAssertFalse(ok, "a mic-only file is not a finished recording")
        XCTAssertFalse(FileManager.default.fileExists(atPath: final.path), "no final at the canonical path")
        XCTAssertEqual(try Data(contentsOf: mic), micBytes, "the mic channel stays where it was")
        XCTAssertEqual(try Data(contentsOf: system), systemBytes)
        let breadcrumb = try XCTUnwrap(RecordingPostProcessor.readPostProcessFailure(final: final))
        XCTAssertEqual(breadcrumb.reason, RecordingPostProcessor.ffmpegMissingReason)
        XCTAssertTrue(breadcrumb.reason?.contains("ffmpeg") == true && breadcrumb.reason?.contains("relaunch") == true)
        let raw = try Data(contentsOf: RecordingPostProcessor.recordFailURL(forFinal: final))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        XCTAssertEqual(payload["retained"] as? [String], ["rec.mic.wav", "rec.system.wav"])
        let events = try String(contentsOf: logs.appendingPathComponent("events.jsonl"), encoding: .utf8)
        XCTAssertTrue(events.contains("postprocess_failed"), events)
    }

    /// A single present channel is converted, not merged, and keeps its own failure path (unchanged).
    func test_no_ffmpeg_leaves_the_single_source_path_failing_as_before_F052() async throws {
        let dir = try makeTempDir()
        let mic = dir.appendingPathComponent("solo.mic.wav")
        let final = dir.appendingPathComponent("solo.wav")
        try makeWavData(seconds: 1.0, amplitude: 1000).write(to: mic)
        let saved = ProcessInfo.processInfo.environment["MEETINGPIPE_FFMPEG"]
        setenv("MEETINGPIPE_FFMPEG", "/nonexistent/ffmpeg", 1)
        defer { if let saved { setenv("MEETINGPIPE_FFMPEG", saved, 1) } else { unsetenv("MEETINGPIPE_FFMPEG") } }

        let ok = await RecordingPostProcessor.produceFinal(
            mic: mic, system: dir.appendingPathComponent("solo.system.wav"), final: final,
            hasMic: true, hasSystem: false, ffmpegPath: "/nonexistent/ffmpeg"
        )

        XCTAssertFalse(ok)
        XCTAssertFalse(FileManager.default.fileExists(atPath: final.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: mic.path))
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

// MARK: - REC36: orphan recovery merges with the persisted placement

/// REC36: `recoverOrphan` used to merge at offset 0 with no cut, because the REC9 head offset and
/// the END9 trim lived only in memory at stop. These drive `recoverOrphan` itself over real files,
/// with real ffmpeg for the placement, as the merge tests above do.
extension RecordingPostProcessorTests {

    func test_recoverOrphan_places_the_system_channel_at_the_persisted_offset() async throws {
        try requireFFmpeg()
        let (dir, logs) = try makeRecoveryDir()
        let stem = "20261117-100000"
        try makeWavData(seconds: 10, amplitude: 8000).write(to: dir.appendingPathComponent("\(stem).mic.wav"))
        try makeWavData(seconds: 3, channels: 2, amplitude: 8000).write(to: dir.appendingPathComponent("\(stem).system.wav"))
        let final = dir.appendingPathComponent("\(stem).wav")
        XCTAssertTrue(MergePlacement.write(.init(systemHeadOffsetSec: 4, spanSec: 10), forFinal: final))

        let recovered = await RecordingPostProcessor.recoverOrphan(stem: stem, in: dir)

        XCTAssertEqual(recovered, final)
        XCTAssertEqual(try XCTUnwrap(RecordingPostProcessor.audioDurationSec(of: final)), 10, accuracy: 0.05)
        XCTAssertLessThan(try peak(final, channel: 1, from: 0.5, to: 3.5), 100, "silent before the capture started")
        XCTAssertGreaterThan(try peak(final, channel: 1, from: 4.5, to: 6.5), 4000, "the far side sits 4 s in")
        XCTAssertEqual(MergePlacement.load(forFinal: final), .absent, "removed once the final is promoted")
        XCTAssertTrue(recoveryEvents(logs, action: "orphan_recovered_without_offset").isEmpty)
        // The termination flush's span means stop never ran REC30's check, so recovery does.
        let coverage = recoveryEvents(logs, action: "channel_coverage_short")
        XCTAssertEqual(coverage.count, 1)
        XCTAssertEqual(coverage.first?["path"] as? String, "orphan_recovery")
        XCTAssertEqual(coverage.first?["head_offset_sec"] as? Double, 4)
    }

    func test_recoverOrphan_cuts_at_the_persisted_limit() async throws {
        try requireFFmpeg()
        let (dir, logs) = try makeRecoveryDir()
        let stem = "20261117-101000"
        try makeWavData(seconds: 10, amplitude: 8000).write(to: dir.appendingPathComponent("\(stem).mic.wav"))
        try makeWavData(seconds: 10, channels: 2, amplitude: 8000).write(to: dir.appendingPathComponent("\(stem).system.wav"))
        let final = dir.appendingPathComponent("\(stem).wav")
        MergePlacement.write(.init(systemHeadOffsetSec: 0, limitSeconds: 6), forFinal: final)

        let recovered = await RecordingPostProcessor.recoverOrphan(stem: stem, in: dir)

        XCTAssertEqual(recovered, final)
        XCTAssertEqual(try XCTUnwrap(RecordingPostProcessor.audioDurationSec(of: final)), 6, accuracy: 0.05)
        XCTAssertTrue(recoveryEvents(logs, action: "channel_coverage_short").isEmpty, "a stop-time placement carries no span")
    }

    func test_recoverOrphan_with_nothing_persisted_merges_at_zero_and_says_so() async throws {
        try requireFFmpeg()
        let (dir, logs) = try makeRecoveryDir()
        let stem = "20261117-102000"
        try makeWavData(seconds: 10, amplitude: 8000).write(to: dir.appendingPathComponent("\(stem).mic.wav"))
        try makeWavData(seconds: 3, channels: 2, amplitude: 8000).write(to: dir.appendingPathComponent("\(stem).system.wav"))
        let final = dir.appendingPathComponent("\(stem).wav")

        let recovered = await RecordingPostProcessor.recoverOrphan(stem: stem, in: dir)

        XCTAssertEqual(recovered, final)
        XCTAssertGreaterThan(try peak(final, channel: 1, from: 0.5, to: 2.5), 4000, "no offset: the far side starts at 0")
        let without = recoveryEvents(logs, action: "orphan_recovered_without_offset")
        XCTAssertEqual(without.count, 1)
        XCTAssertEqual(without.first?["category"] as? String, "recorder")
        XCTAssertEqual(without.first?["reason"] as? String, "absent")
        XCTAssertEqual(without.first?["file"] as? String, "\(stem).wav")
    }

    /// The case a placement carried in the failure breadcrumb would have lost: that file is
    /// rewritten on every failure, so the second attempt would merge at 0.
    func test_a_failed_recovery_keeps_the_placement_for_the_next_attempt() async throws {
        let (dir, _) = try makeRecoveryDir()
        let stem = "20261117-103000"
        try makeWavData(seconds: 10, amplitude: 8000).write(to: dir.appendingPathComponent("\(stem).mic.wav"))
        try makeWavData(seconds: 10, channels: 2, amplitude: 8000).write(to: dir.appendingPathComponent("\(stem).system.wav"))
        let final = dir.appendingPathComponent("\(stem).wav")
        MergePlacement.write(.init(systemHeadOffsetSec: 4, limitSeconds: 8), forFinal: final)
        let truncated = dir.appendingPathComponent("truncated.wav")
        try makeWavData(seconds: 1, amplitude: 8000).write(to: truncated)
        setenv("MEETINGPIPE_FFMPEG", try FakeFFmpeg.copying(truncated, in: dir).path, 1)
        defer { unsetenv("MEETINGPIPE_FFMPEG") }

        let recovered = await RecordingPostProcessor.recoverOrphan(stem: stem, in: dir)

        XCTAssertNil(recovered)
        XCTAssertEqual(MergePlacement.load(forFinal: final), .loaded(.init(systemHeadOffsetSec: 4, limitSeconds: 8)))
        XCTAssertNotNil(RecordingPostProcessor.readPostProcessFailure(final: final))
    }

    func test_placement_round_trips_and_refuses_what_it_did_not_write() throws {
        let (dir, _) = try makeRecoveryDir()
        let final = dir.appendingPathComponent("20261117-104000.wav")
        XCTAssertEqual(MergePlacement.load(forFinal: final), .absent)

        let values = MergePlacement.Values(systemHeadOffsetSec: 33.21, limitSeconds: 1800, spanSec: 2400)
        MergePlacement.write(values, forFinal: final)
        XCTAssertEqual(MergePlacement.load(forFinal: final), .loaded(values))

        for body in ["not json", #"{"system_head_offset_sec": -1}"#, #"{"system_head_offset_sec": true}"#,
                     #"{"system_head_offset_sec": 2, "limit_sec": 0}"#, #"{"limit_sec": 5}"#] {
            try Data(body.utf8).write(to: MergePlacement.url(forFinal: final))
            XCTAssertEqual(MergePlacement.load(forFinal: final), .unreadable, body)
        }
    }

    /// A merge that keeps failing keeps its placement, but the coverage row is measured once.
    func test_recovered_coverage_is_emitted_once_across_failed_retries() async throws {
        let (dir, logs) = try makeRecoveryDir()
        let stem = "20261117-105000"
        try makeWavData(seconds: 10, amplitude: 8000).write(to: dir.appendingPathComponent("\(stem).mic.wav"))
        try makeWavData(seconds: 10, channels: 2, amplitude: 8000).write(to: dir.appendingPathComponent("\(stem).system.wav"))
        let final = dir.appendingPathComponent("\(stem).wav")
        MergePlacement.write(.init(systemHeadOffsetSec: 4, spanSec: 14), forFinal: final)
        let truncated = dir.appendingPathComponent("truncated.wav")
        try makeWavData(seconds: 1, amplitude: 8000).write(to: truncated)
        setenv("MEETINGPIPE_FFMPEG", try FakeFFmpeg.copying(truncated, in: dir).path, 1)
        defer { unsetenv("MEETINGPIPE_FFMPEG") }

        _ = await RecordingPostProcessor.recoverOrphan(stem: stem, in: dir)
        _ = await RecordingPostProcessor.recoverOrphan(stem: stem, in: dir)

        XCTAssertEqual(recoveryEvents(logs, action: "channel_coverage_short").count, 1)
        XCTAssertEqual(MergePlacement.load(forFinal: final), .loaded(.init(systemHeadOffsetSec: 4)))
    }

    func test_a_placement_beside_a_finished_final_is_cleared_not_applied() async throws {
        let (dir, _) = try makeRecoveryDir()
        let stem = "20261117-106000"
        let final = dir.appendingPathComponent("\(stem).wav")
        try makeWavData(seconds: 10, amplitude: 8000).write(to: final)
        try makeWavData(seconds: 10, amplitude: 8000).write(to: dir.appendingPathComponent("\(stem).mic.wav"))
        MergePlacement.write(.init(systemHeadOffsetSec: 4), forFinal: final)

        let recovered = await RecordingPostProcessor.recoverOrphan(stem: stem, in: dir)

        XCTAssertNil(recovered)
        XCTAssertEqual(MergePlacement.load(forFinal: final), .absent)
    }

    /// T7 source fence (deliberate): the recorder half of REC36. Missing seam: `stop()` and the
    /// termination flush need a live engine and real capture files, so no test can drive them to
    /// the write; this pins that each persists the placement at the point the fix depends on:
    /// `stop()` straight after `endSession` (a quit after that skips the flush), and the flush
    /// before its writer drains (a slow drain must not starve it).
    func test_the_recorder_persists_the_placement_where_recovery_needs_it() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/MeetingPipe/MeetingRecorder.swift"), encoding: .utf8
        )
        func range(of needle: String, after start: String.Index? = nil) throws -> Range<String.Index> {
            try XCTUnwrap(source.range(of: needle, range: (start ?? source.startIndex)..<source.endIndex), needle)
        }
        let stop = try range(of: "func stop(limitSeconds: Double? = nil) async -> Bool {")
        let ended = try range(of: "let session = endSession()", after: stop.upperBound)
        let write = try range(of: "MergePlacement.write(", after: ended.upperBound)
        let halt = try range(of: "await systemChannel.haltCapture()", after: ended.upperBound)
        XCTAssertLessThan(write.lowerBound, halt.lowerBound, "stop() persists the placement before its first await")

        let flush = try range(of: "func flushIntermediatesForTermination() {")
        let flushWrite = try range(of: "MergePlacement.write(placement, forFinal: final)", after: flush.upperBound)
        let drain = try range(of: "micWriter?.finish(timeout:", after: flush.upperBound)
        XCTAssertLessThan(flushWrite.lowerBound, drain.lowerBound, "the flush persists the placement before the drains")
        let drop = try range(of: "systemChannel.dropCaptureForTermination()", after: flush.upperBound)
        let read = try range(of: "systemChannel.systemFirstFrameUptime", after: flush.upperBound)
        XCTAssertLessThan(read.lowerBound, drop.lowerBound, "the offset is read before the system capture is dropped")
    }

    private func makeRecoveryDir() throws -> (URL, URL) {
        let dir = try makeTempDir()
        let logs = dir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        setenv("MEETINGPIPE_LOGS_DIR", logs.path, 1)
        addTeardownBlock { unsetenv("MEETINGPIPE_LOGS_DIR") }
        return (dir, logs)
    }

    private func recoveryEvents(_ logs: URL, action: String) -> [[String: Any]] {
        let text = (try? String(contentsOf: logs.appendingPathComponent("events.jsonl"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["action"] as? String == action else { return nil }
            return object
        }
    }
}

// MARK: - OBS10: the merge says what it cost

extension RecordingPostProcessorTests {

    func test_aSuccessfulMerge_emitsMergeCompleted_withWallCPUAndAudioSeconds_OBS10() async throws {
        try requireFFmpeg()
        let dir = try makeTempDir()
        let logs = dir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        setenv("MEETINGPIPE_LOGS_DIR", logs.path, 1)
        defer { unsetenv("MEETINGPIPE_LOGS_DIR") }
        let mic = dir.appendingPathComponent("20261117-200000.mic.wav")
        let system = dir.appendingPathComponent("20261117-200000.system.wav")
        let final = dir.appendingPathComponent("20261117-200000.wav")
        try makeWavData(seconds: 4, amplitude: 8000).write(to: mic)
        try makeWavData(seconds: 4, channels: 2, amplitude: 8000).write(to: system)

        let ok = await RecordingPostProcessor.produceFinal(mic: mic, system: system, final: final, hasMic: true, hasSystem: true)
        XCTAssertTrue(ok)

        let rows = ((try? String(contentsOf: logs.appendingPathComponent("events.jsonl"), encoding: .utf8)) ?? "")
            .split(separator: "\n")
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            .filter { $0["action"] as? String == "merge_completed" }
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row["file"] as? String, "20261117-200000.wav")
        XCTAssertEqual(row["kind"] as? String, "merge")
        XCTAssertGreaterThan(row["wall_ms"] as? Double ?? -1, 0)
        XCTAssertGreaterThan(row["cpu_ms"] as? Double ?? -1, 0, "ffmpeg's own CPU, from the reaped child's rusage")
        XCTAssertEqual(row["audio_seconds"] as? Double ?? 0, 4, accuracy: 0.1, "measured on the final")
        XCTAssertNotNil(row["thermal_state"] as? String)
    }

    /// A single-source recording's convert is the same kind of ffmpeg run and gets the same row.
    func test_aSingleSourceConvert_emitsMergeCompleted_asAConvert_OBS10() async throws {
        try requireFFmpeg()
        let dir = try makeTempDir()
        let logs = dir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        setenv("MEETINGPIPE_LOGS_DIR", logs.path, 1)
        defer { unsetenv("MEETINGPIPE_LOGS_DIR") }
        let mic = dir.appendingPathComponent("20261117-201000.mic.wav")
        let system = dir.appendingPathComponent("20261117-201000.system.wav")
        let final = dir.appendingPathComponent("20261117-201000.wav")
        try makeWavData(seconds: 3, amplitude: 8000).write(to: mic)

        let ok = await RecordingPostProcessor.produceFinal(mic: mic, system: system, final: final, hasMic: true, hasSystem: false)
        XCTAssertTrue(ok)
        let rows = ((try? String(contentsOf: logs.appendingPathComponent("events.jsonl"), encoding: .utf8)) ?? "")
            .split(separator: "\n")
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            .filter { $0["action"] as? String == "merge_completed" }
        XCTAssertEqual(rows.map { $0["kind"] as? String }, ["convert"])
    }
}
