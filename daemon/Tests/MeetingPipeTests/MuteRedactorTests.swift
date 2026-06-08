import AVFoundation
import XCTest
@testable import MeetingPipe

final class MuteRedactorTests: XCTestCase {

    // MARK: - buildFilter (pure)

    func test_buildFilter_nil_when_no_spans() {
        XCTAssertNil(MuteRedactor.buildFilter(spans: [], channels: 2))
    }

    func test_buildFilter_stereo_zeroes_only_the_left_channel() {
        let filter = MuteRedactor.buildFilter(
            spans: [MuteTimeline.Span(startSec: 1.0, endSec: 2.0)], channels: 2
        )
        let f = try? XCTUnwrap(filter)
        XCTAssertTrue(f?.contains("channelsplit") == true, "stereo must split so system audio is untouched")
        XCTAssertTrue(f?.contains("[L]volume=0:enable=") == true, "only the left (mic) channel is zeroed")
        XCTAssertTrue(f?.contains("amerge=inputs=2") == true, "channels are re-merged back to stereo")
    }

    func test_buildFilter_mono_zeroes_the_single_channel() {
        let filter = MuteRedactor.buildFilter(
            spans: [MuteTimeline.Span(startSec: 1.0, endSec: 2.0)], channels: 1
        )
        let f = try? XCTUnwrap(filter)
        XCTAssertEqual(f?.contains("channelsplit"), false, "mono has nothing to split")
        XCTAssertTrue(f?.contains("[0:a]volume=0:enable=") == true)
    }

    func test_buildFilter_encodes_each_span_as_a_between_term() {
        let filter = MuteRedactor.buildFilter(
            spans: [
                MuteTimeline.Span(startSec: 1.25, endSec: 2.5),
                MuteTimeline.Span(startSec: 10.0, endSec: 12.0),
            ],
            channels: 2
        )
        let f = try? XCTUnwrap(filter)
        XCTAssertTrue(f?.contains("between(t,1.250,2.500)") == true)
        XCTAssertTrue(f?.contains("between(t,10.000,12.000)") == true)
        XCTAssertTrue(f?.contains("between(t,1.250,2.500)+between(t,10.000,12.000)") == true,
                      "spans OR together so any one silences the mic")
    }

    // MARK: - originals path

    func test_originalsURL_is_app_private_and_outside_the_recordings_tree() {
        let wav = URL(fileURLWithPath: "/Users/x/Documents/Meetings/raw/20260607-120000.wav")
        let original = MuteRedactor.originalsURL(for: wav)
        XCTAssertEqual(original.lastPathComponent, "20260607-120000.wav")
        XCTAssertTrue(original.path.contains("Application Support/MeetingPipe/originals"))
        XCTAssertFalse(original.path.contains("/Meetings/raw/"), "must not sit in the Library-scanned tree")
    }

    // MARK: - redactIfNeeded

    func test_redactIfNeeded_is_a_noop_without_a_timeline() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("redact-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("rec.wav")
        try writeStereoWav(at: wav, seconds: 0.2, left: 0.5, right: 0.5)
        let before = try Data(contentsOf: wav)

        // No <stem>.mute-timeline.json present -> regulated/orphan/pre-MIC4 path.
        let redacted = await MuteRedactor.redactIfNeeded(wav: wav, originalsDir: dir)

        XCTAssertFalse(redacted)
        XCTAssertEqual(try Data(contentsOf: wav), before, "the WAV must be untouched without a timeline")
    }

    func test_redactIfNeeded_zeroes_the_muted_span_and_keeps_the_original() async throws {
        try XCTSkipIf(MeetingRecorder.findFFmpeg() == nil, "ffmpeg not available")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("redact-\(UUID().uuidString)")
        let originals = dir.appendingPathComponent("originals")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let wav = dir.appendingPathComponent("rec.wav")
        try writeStereoWav(at: wav, seconds: 1.0, left: 0.5, right: 0.5)
        // Mute the first half of the mic channel.
        MuteTimelineFile.write(spans: [MuteTimeline.Span(startSec: 0.0, endSec: 0.5)], forFinal: wav)

        let redacted = await MuteRedactor.redactIfNeeded(wav: wav, originalsDir: originals)
        XCTAssertTrue(redacted)

        // The full recording was moved aside for recovery.
        XCTAssertTrue(FileManager.default.fileExists(atPath: originals.appendingPathComponent("rec.wav").path))

        // The redacted artifact: left silenced in [0,0.5), audible after; right untouched.
        let file = try AVAudioFile(forReading: wav)
        let frames = AVAudioFrameCount(file.length)
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
        try file.read(into: buf)
        let data = try XCTUnwrap(buf.floatChannelData)
        let rate = file.processingFormat.sampleRate

        XCTAssertEqual(peak(data[0], from: 0, to: Int(0.4 * rate)), 0, accuracy: 0.02,
                       "mic must be silent inside the muted span")
        XCTAssertGreaterThan(peak(data[0], from: Int(0.6 * rate), to: Int(0.95 * rate)), 0.1,
                             "mic must be audible after the muted span")
        XCTAssertGreaterThan(peak(data[1], from: 0, to: Int(0.4 * rate)), 0.1,
                             "system (right) channel must be untouched by mic redaction")
    }

    func test_redactIfNeeded_is_idempotent_and_keeps_the_original_across_reruns() async throws {
        try XCTSkipIf(MeetingRecorder.findFFmpeg() == nil, "ffmpeg not available")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("redact-\(UUID().uuidString)")
        let originals = dir.appendingPathComponent("originals")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let wav = dir.appendingPathComponent("rec.wav")
        try writeStereoWav(at: wav, seconds: 1.0, left: 0.5, right: 0.5)
        let fullBytes = try Data(contentsOf: wav)
        MuteTimelineFile.write(spans: [MuteTimeline.Span(startSec: 0.0, endSec: 0.5)], forFinal: wav)

        // First pass redacts and moves the full recording aside.
        let firstPass = await MuteRedactor.redactIfNeeded(wav: wav, originalsDir: originals)
        XCTAssertTrue(firstPass)
        let keptOriginal = originals.appendingPathComponent("rec.wav")
        XCTAssertEqual(try Data(contentsOf: keptOriginal), fullBytes, "the kept original is the un-redacted full recording")
        let redactedBytes = try Data(contentsOf: wav)

        // Second pass (reprocess / retry) must be a no-op that does NOT clobber
        // the kept original with the already-redacted file.
        let secondPass = await MuteRedactor.redactIfNeeded(wav: wav, originalsDir: originals)
        XCTAssertFalse(secondPass, "a second pass must no-op")
        XCTAssertEqual(try Data(contentsOf: keptOriginal), fullBytes,
                       "the kept original must survive a re-run unchanged")
        XCTAssertEqual(try Data(contentsOf: wav), redactedBytes, "the canonical WAV stays the redacted one")
    }

    // MARK: - audio-grounded runaway guard (TECH-MIC9)

    func test_runawayWithholdReason_only_fires_on_high_coverage_with_speech() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let loud = dir.appendingPathComponent("loud.wav")
        try writeStereoWav(at: loud, seconds: 1.0, left: 0.5, right: 0.5)
        let silentMic = dir.appendingPathComponent("silent.wav")
        try writeStereoWav(at: silentMic, seconds: 1.0, left: 0.0, right: 0.5)

        let whole = [MuteTimeline.Span(startSec: 0.0, endSec: 1.0)]
        let half = [MuteTimeline.Span(startSec: 0.0, endSec: 0.5)]

        XCTAssertNotNil(
            MuteRedactor.runawayWithholdReason(wav: loud, spans: whole),
            "whole-recording mute over a live mic must withhold"
        )
        XCTAssertNil(
            MuteRedactor.runawayWithholdReason(wav: loud, spans: half),
            "50% coverage is below the runaway bound: a genuine muted aside, redact it"
        )
        XCTAssertNil(
            MuteRedactor.runawayWithholdReason(wav: silentMic, spans: whole),
            "whole-recording mute over a silent mic is harmless: redact it"
        )
    }

    func test_redactIfNeeded_withholds_runaway_redaction_over_a_live_mic() async throws {
        // The Teams mini-window incident in one assertion: a whole-recording
        // muted span over a mic that carries speech must be withheld, the full
        // mic kept, and the bogus timeline reaped. The guard returns before
        // ffmpeg, so this runs without it.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("redact-\(UUID().uuidString)")
        let originals = dir.appendingPathComponent("originals")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let wav = dir.appendingPathComponent("rec.wav")
        try writeStereoWav(at: wav, seconds: 1.0, left: 0.5, right: 0.5)
        let fullBytes = try Data(contentsOf: wav)
        MuteTimelineFile.write(spans: [MuteTimeline.Span(startSec: 0.0, endSec: 1.0)], forFinal: wav)

        let redacted = await MuteRedactor.redactIfNeeded(wav: wav, originalsDir: originals)
        XCTAssertFalse(redacted, "a whole-file muted span over a live mic must be withheld, not redacted")
        XCTAssertEqual(try Data(contentsOf: wav), fullBytes, "the full mic recording is kept untouched")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: originals.appendingPathComponent("rec.wav").path),
            "nothing is moved aside when redaction is withheld"
        )
        XCTAssertNil(MuteTimelineFile.read(forFinal: wav), "the bogus timeline is reaped so a reprocess won't retry it")
    }

    func test_redactIfNeeded_redacts_a_runaway_span_when_the_mic_is_silent() async throws {
        try XCTSkipIf(MeetingRecorder.findFFmpeg() == nil, "ffmpeg not available")
        // A whole-recording mute over a silent mic loses nothing, so the guard
        // must not over-withhold: redaction proceeds as normal.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("redact-\(UUID().uuidString)")
        let originals = dir.appendingPathComponent("originals")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let wav = dir.appendingPathComponent("rec.wav")
        try writeStereoWav(at: wav, seconds: 1.0, left: 0.0, right: 0.5)
        MuteTimelineFile.write(spans: [MuteTimeline.Span(startSec: 0.0, endSec: 1.0)], forFinal: wav)

        let redacted = await MuteRedactor.redactIfNeeded(wav: wav, originalsDir: originals)
        XCTAssertTrue(redacted, "a runaway mute over a silent mic is harmless and redacts normally")
        XCTAssertTrue(FileManager.default.fileExists(atPath: originals.appendingPathComponent("rec.wav").path))
    }

    // MARK: - helpers

    private func writeStereoWav(at url: URL, seconds: Double, left: Float, right: Float) throws {
        let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 2, interleaved: false
        )!
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
        let frames = AVAudioFrameCount(seconds * 16000)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        for i in 0..<Int(frames) {
            buf.floatChannelData![0][i] = left
            buf.floatChannelData![1][i] = right
        }
        try file.write(from: buf)
    }

    private func peak(_ p: UnsafeMutablePointer<Float>, from: Int, to: Int) -> Float {
        var m: Float = 0
        for i in from..<to { m = max(m, abs(p[i])) }
        return m
    }
}
