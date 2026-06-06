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
