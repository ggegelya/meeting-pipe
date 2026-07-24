import AVFoundation
import XCTest
@testable import MeetingPipe

final class MuteRedactorTests: XCTestCase {

    // MARK: - protectOriginalAtRest (AUD-19 / MIC13)

    func test_protectOriginalAtRest_sets_owner_only_and_excludes_from_backup() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp-originals-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("rec.wav")
        try Data("x".utf8).write(to: file)
        // World-readable to start, so the 0600 tightening is observable.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)

        MuteRedactor.protectOriginalAtRest(file)

        let perms = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o600, "kept originals must be owner-only")
        let excluded = try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        XCTAssertEqual(excluded, true, "kept originals must be excluded from Time Machine / iCloud (AUD-19)")
    }

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
        try requireFFmpeg()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("redact-\(UUID().uuidString)")
        let originals = dir.appendingPathComponent("originals")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let wav = dir.appendingPathComponent("rec.wav")
        // Mute the first half of the mic channel. It must be genuinely quiet for
        // MIC12's per-span guard to redact it; the audible second half stands in
        // for un-muted speech that must survive.
        try writeStereoWavTwoRegions(at: wav, seconds: 1.0, splitSec: 0.5,
                                     micFirst: 0.002, micSecond: 0.5, system: 0.5)
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
        try requireFFmpeg()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("redact-\(UUID().uuidString)")
        let originals = dir.appendingPathComponent("originals")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let wav = dir.appendingPathComponent("rec.wav")
        // Muted span genuinely quiet so MIC12's per-span guard redacts it.
        try writeStereoWavTwoRegions(at: wav, seconds: 1.0, splitSec: 0.5,
                                     micFirst: 0.002, micSecond: 0.5, system: 0.5)
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

    // MARK: - per-span runaway guard (TECH-MIC12)

    func test_partitionSpans_redacts_quiet_spans_and_withholds_speechy_ones() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mic12-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Mic genuinely quiet (~-54 dBFS) in [0,0.5), at speech level (~-10 dBFS)
        // in [0.5,1.0); system audio present throughout.
        let wav = dir.appendingPathComponent("rec.wav")
        try writeStereoWavTwoRegions(at: wav, seconds: 1.0, splitSec: 0.5,
                                     micFirst: 0.002, micSecond: 0.3, system: 0.5)
        let quiet = MuteTimeline.Span(startSec: 0.0, endSec: 0.5)
        let speechy = MuteTimeline.Span(startSec: 0.5, endSec: 1.0)

        let (redact, withheld) = MuteRedactor.partitionSpans(wav: wav, spans: [quiet, speechy])

        XCTAssertEqual(redact.map { $0.startSec }, [0.0],
                       "a genuinely quiet muted span is safe to redact")
        XCTAssertEqual(withheld.map { $0.startSec }, [0.5],
                       "a muted span carrying speech is withheld, never zeroed")
    }

    func test_redactIfNeeded_redacts_quiet_span_and_keeps_speechy_span() async throws {
        try requireFFmpeg()
        // The MIC12 win in one assertion: a mixed timeline redacts the quiet muted
        // span but PRESERVES the muted span that carries speech (the old whole-file
        // 85% guard would have withheld both, leaving the quiet listening
        // un-redacted).
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mic12-\(UUID().uuidString)")
        let originals = dir.appendingPathComponent("originals")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let wav = dir.appendingPathComponent("rec.wav")
        try writeStereoWavTwoRegions(at: wav, seconds: 1.0, splitSec: 0.5,
                                     micFirst: 0.002, micSecond: 0.3, system: 0.5)
        MuteTimelineFile.write(
            spans: [MuteTimeline.Span(startSec: 0.0, endSec: 0.5),
                    MuteTimeline.Span(startSec: 0.5, endSec: 1.0)],
            forFinal: wav
        )

        let redacted = await MuteRedactor.redactIfNeeded(wav: wav, originalsDir: originals)
        XCTAssertTrue(redacted, "a mixed timeline still redacts its quiet span")

        let file = try AVAudioFile(forReading: wav)
        let frames = AVAudioFrameCount(file.length)
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
        try file.read(into: buf)
        let data = try XCTUnwrap(buf.floatChannelData)
        let rate = file.processingFormat.sampleRate

        XCTAssertLessThan(peak(data[0], from: 0, to: Int(0.4 * rate)), 0.0005,
                          "the quiet muted span was redacted to silence (was ~0.002)")
        XCTAssertGreaterThan(peak(data[0], from: Int(0.6 * rate), to: Int(0.9 * rate)), 0.1,
                             "the speech-carrying muted span was preserved, not zeroed")
        XCTAssertGreaterThan(peak(data[1], from: 0, to: Int(0.9 * rate)), 0.1,
                             "the system (right) channel is untouched")
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

    func test_redactIfNeeded_always_redacts_a_manual_span_over_a_live_mic() async throws {
        try requireFFmpeg()
        // MIC14 invariant 1: a manual off-record span is explicit user intent, so it is redacted
        // even over a mic carrying speech - the exact case the auto withhold above protects. This
        // is the mirror assertion: same live mic, same whole-file span, but tagged `.manual`, so
        // the outcome flips from withheld to redacted.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("redact-\(UUID().uuidString)")
        let originals = dir.appendingPathComponent("originals")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let wav = dir.appendingPathComponent("rec.wav")
        try writeStereoWav(at: wav, seconds: 1.0, left: 0.5, right: 0.5)  // a live mic
        MuteTimelineFile.write(
            spans: [MuteTimeline.Span(startSec: 0.0, endSec: 1.0, source: .manual)], forFinal: wav
        )

        let redacted = await MuteRedactor.redactIfNeeded(wav: wav, originalsDir: originals)
        XCTAssertTrue(redacted, "a manual span is always redacted, exempt from the speech-bearing withhold")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: originals.appendingPathComponent("rec.wav").path),
            "the full original is moved aside for recovery"
        )
        // The mic (left) channel is zeroed over the manual span in the redacted artifact.
        let f = try AVAudioFile(forReading: wav)
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: buf)
        let leftPeak = peak(buf.floatChannelData![0], from: 0, to: Int(buf.frameLength))
        XCTAssertLessThan(leftPeak, 0.02, "the manual span's mic audio is zeroed in the consumed artifact")
    }

    func test_redactIfNeeded_redacts_a_runaway_span_when_the_mic_is_silent() async throws {
        try requireFFmpeg()
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

    /// Gate for the ffmpeg-backed safety tests, loud by design (CI1 / AUD-8).
    /// CI installs ffmpeg (`.github/workflows/ci.yml`), so a missing binary
    /// there means the most destructive code path (mute redaction over a real
    /// WAV) went unverified: a failure to surface, not a skip to swallow. Only a
    /// genuinely local machine without ffmpeg still skips.
    private func requireFFmpeg() throws {
        if RecordingPostProcessor.findFFmpeg() != nil { return }
        if ProcessInfo.processInfo.environment["CI"] == "true" {
            throw FFmpegUnavailableOnCI()
        }
        throw XCTSkip("ffmpeg not available (local run)")
    }

    private struct FFmpegUnavailableOnCI: Error, CustomStringConvertible {
        var description: String {
            "ffmpeg missing on CI: the MuteRedactor data-safety tests could not run. "
                + "ci.yml is supposed to install it; the mute-redaction path is now unverified."
        }
    }

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

    /// Stereo WAV whose mic (left) channel switches level at `splitSec`: used to
    /// build a recording where one muted span is genuinely quiet and another
    /// carries speech (TECH-MIC12). System (right) is constant.
    private func writeStereoWavTwoRegions(
        at url: URL, seconds: Double, splitSec: Double,
        micFirst: Float, micSecond: Float, system: Float
    ) throws {
        let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 2, interleaved: false
        )!
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
        let frames = AVAudioFrameCount(seconds * 16000)
        let split = Int(splitSec * 16000)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        for i in 0..<Int(frames) {
            buf.floatChannelData![0][i] = i < split ? micFirst : micSecond
            buf.floatChannelData![1][i] = system
        }
        try file.write(from: buf)
    }

    private func peak(_ p: UnsafeMutablePointer<Float>, from: Int, to: Int) -> Float {
        var m: Float = 0
        for i in from..<to { m = max(m, abs(p[i])) }
        return m
    }
}
