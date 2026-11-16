import AVFoundation
import os
import XCTest
@testable import MeetingPipe

/// CONC5: `ProcessRunner` and the call sites that now ride it. Every child is a `/bin/sh` script, and
/// the fake ffmpegs below are shell scripts, so none of this needs a real ffmpeg.
final class ProcessRunnerTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("conc5-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    // MARK: Helpers

    private func sh(_ script: String, timeout: TimeInterval = 10, grace: TimeInterval = 1, stdin: Data? = nil) -> ProcessRunner.Result {
        ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", script], stdin: stdin, timeout: timeout, grace: grace)
    }

    private func isGone(_ pid: pid_t) -> Bool { kill(pid, 0) != 0 && errno == ESRCH }

    private func readPid(_ file: URL) throws -> pid_t {
        let text = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return try XCTUnwrap(pid_t(text))
    }

    /// An executable script standing in for ffmpeg.
    private func fakeFFmpeg(_ body: String) throws -> String {
        let url = dir.appendingPathComponent("fake-ffmpeg-\(UUID().uuidString).sh")
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    /// A short mono 16 kHz WAV (silence unless `amplitude` is set), written through AVFoundation.
    @discardableResult
    private func writeWAV(_ name: String, seconds: Double = 1, channels: AVAudioChannelCount = 1) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let rate = 16_000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ])
        let frames = AVAudioFrameCount(rate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        try file.write(from: buffer)
        return url
    }

    // MARK: The runner

    func test_a_megabyte_on_each_stream_completes_and_returns_both_tails() {
        let r = sh("head -c 1048576 /dev/zero | tr '\\0' o; head -c 1048576 /dev/zero | tr '\\0' e >&2; echo END >&2")
        XCTAssertTrue(r.succeeded)
        XCTAssertEqual(r.stdout.count, ProcessRunner.defaultStdoutLimit)
        XCTAssertEqual(r.stderrTail.count, ProcessOutputDrain.stderrLimit)
        XCTAssertTrue(r.stderrText.hasSuffix("eeEND\n"))
    }

    func test_a_nonzero_exit_returns_its_status_and_stderr_tail() {
        let r = sh("echo boom >&2; exit 7")
        XCTAssertEqual(r.status, 7)
        XCTAssertEqual(r.stderrText, "boom\n")
        XCTAssertFalse(r.timedOut)
        XCTAssertTrue(r.reaped)
        XCTAssertFalse(r.succeeded)
    }

    func test_a_child_that_ignores_sigterm_is_killed_and_reaped_past_its_timeout() throws {
        let pidFile = dir.appendingPathComponent("pid")
        // `exec` keeps the pid, and an ignored signal survives an exec, so it is `sleep` that ignores TERM.
        let started = Date()
        let r = sh("echo $$ > '\(pidFile.path)'; trap '' TERM; exec sleep 30", timeout: 1, grace: 1)
        XCTAssertTrue(r.timedOut)
        XCTAssertTrue(r.reaped)
        XCTAssertFalse(r.succeeded)
        XCTAssertLessThan(Date().timeIntervalSince(started), 8, "SIGKILL did not follow the grace")
        XCTAssertTrue(isGone(try readPid(pidFile)), "the child outlived its kill")
    }

    func test_a_child_that_honours_sigterm_stops_at_the_timeout() throws {
        let pidFile = dir.appendingPathComponent("pid")
        let started = Date()
        let r = sh("echo $$ > '\(pidFile.path)'; exec sleep 30", timeout: 1, grace: 5)
        XCTAssertTrue(r.timedOut)
        XCTAssertTrue(r.reaped)
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
        XCTAssertTrue(isGone(try readPid(pidFile)))
    }

    func test_stdin_reaches_the_child() {
        let r = sh("cat", stdin: Data("hello\n".utf8))
        XCTAssertTrue(r.succeeded)
        XCTAssertEqual(r.stdoutText, "hello\n")
    }

    func test_a_child_that_never_reads_a_large_stdin_cannot_park_the_caller() {
        let started = Date()
        let r = ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", "exec sleep 30"],
                                  stdin: Data(count: 4 * 1024 * 1024), timeout: 1, grace: 1)
        XCTAssertTrue(r.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 6)
    }

    func test_a_pipe_held_by_a_grandchild_is_not_a_timeout() {
        let started = Date()
        // 0.5 s is below the drain's 2 s ceiling, so the timeout branch runs while the child is already gone.
        let r = sh("(sleep 10) & echo done; exit 3", timeout: 0.5)
        XCTAssertEqual(r.status, 3)
        XCTAssertFalse(r.timedOut, "the child exited in time; only a pipe lagged")
        XCTAssertTrue(r.reaped)
        XCTAssertLessThan(Date().timeIntervalSince(started), 8)
    }

    func test_a_missing_executable_is_a_launch_failure() {
        let r = ProcessRunner.run(executable: "/nonexistent/tool", arguments: [], timeout: 5)
        XCTAssertNotNil(r.launchFailure)
        XCTAssertFalse(r.succeeded)
    }

    /// More concurrent blocking runs than cores, and each child waits until every one of them has
    /// started. A runner that parked its waits on the cooperative pool (one thread per core) could never
    /// start them all, so this fails there instead of merely running slowly.
    func test_async_runs_all_start_together_so_none_waits_on_a_pool_thread() async throws {
        let count = min(ProcessInfo.processInfo.activeProcessorCount * 3, 40)
        let flags = dir.appendingPathComponent("flags")
        try FileManager.default.createDirectory(at: flags, withIntermediateDirectories: true)
        let script = "touch '\(flags.path)'/$$; i=0; while [ \"$(ls '\(flags.path)' | wc -l)\" -lt \(count) ]; do i=$((i+1)); [ $i -gt 150 ] && exit 1; sleep 0.1; done"
        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<count {
                group.addTask {
                    await ProcessRunner.runAsync(executable: "/bin/sh", arguments: ["-c", script], timeout: 30).succeeded
                }
            }
            var out: [Bool] = []
            for await ok in group { out.append(ok) }
            return out
        }
        XCTAssertEqual(results.filter { $0 }.count, count)
    }

    func test_the_reapers_ps_has_a_finite_ceiling() {
        // The reaper's one `Process()`: a finite bound, so one stuck `ps` cannot stop the janitor's queue.
        XCTAssertLessThanOrEqual(LocalServerReaper.psTimeoutSeconds, 10)
    }

    // MARK: KeychainBackend

    func test_a_hung_keychain_read_is_unreadable_within_its_ceiling_and_the_child_is_killed() throws {
        let pidFile = dir.appendingPathComponent("pid")
        let started = Date()
        let output = KeychainBackend.run(
            executable: "/bin/sh", args: ["-c", "echo $$ > '\(pidFile.path)'; trap '' TERM; exec sleep 30"],
            stdin: nil, timeout: 1
        )
        XCTAssertNil(output, "a timed-out read is nil, which `value(for:)` reports as unreadable")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1 + KeychainBackend.killGrace + 4)
        XCTAssertTrue(isGone(try readPid(pidFile)), "SIGTERM was ignored and nothing sent SIGKILL")
    }

    // MARK: RecordingPostProcessor

    private func produce(
        ffmpeg: String, ceiling: Double, mic: URL, final: URL
    ) async -> Bool {
        await RecordingPostProcessor.produceFinal(
            mic: mic, system: dir.appendingPathComponent("absent.system.wav"), final: final,
            hasMic: true, hasSystem: false, ffmpegPath: ffmpeg, ceilingSeconds: ceiling
        )
    }

    func test_a_flood_of_ffmpeg_stderr_does_not_deadlock_the_convert() async throws {
        let mic = try writeWAV("a.mic.wav")
        let final = dir.appendingPathComponent("a.wav")
        let ffmpeg = try fakeFFmpeg("""
        head -c 1048576 /dev/zero | tr '\\0' w >&2
        for a; do last=$a; done
        cp '\(mic.path)' "$last"
        """)

        let ok = await produce(ffmpeg: ffmpeg, ceiling: 30, mic: mic, final: final)

        XCTAssertTrue(ok)
        XCTAssertTrue(FileManager.default.fileExists(atPath: final.path))
    }

    func test_a_timed_out_single_source_convert_kills_ffmpeg_promotes_nothing_and_keeps_the_intermediates() async throws {
        let mic = try writeWAV("b.mic.wav")
        let final = dir.appendingPathComponent("b.wav")
        let pidFile = dir.appendingPathComponent("pid")
        // Writes a (truncated, well-formed) temp first, as a SIGTERMed ffmpeg would leave behind.
        let ffmpeg = try fakeFFmpeg("""
        echo $$ > '\(pidFile.path)'
        for a; do last=$a; done
        cp '\(mic.path)' "$last"
        exec sleep 30
        """)
        let tmp = RecordingPostProcessor.mergingTempURL(forFinal: final)

        let started = Date()
        let ok = await produce(ffmpeg: ffmpeg, ceiling: 1, mic: mic, final: final)

        XCTAssertFalse(ok)
        XCTAssertLessThan(Date().timeIntervalSince(started), 8)
        XCTAssertTrue(isGone(try readPid(pidFile)), "ffmpeg is still running after the ceiling")
        XCTAssertFalse(FileManager.default.fileExists(atPath: final.path), "a killed merge was promoted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.path), "the killed child's temp was left to truncate the next attempt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: mic.path), "the intermediate was deleted")

        // The next attempt is not touched by the killed one.
        let retry = try fakeFFmpeg("for a; do last=$a; done\ncp '\(mic.path)' \"$last\"")
        let again = await produce(ffmpeg: retry, ceiling: 30, mic: mic, final: final)
        XCTAssertTrue(again)
    }

    func test_a_timed_out_two_source_merge_is_killed_and_never_promoted() async throws {
        let mic = try writeWAV("e.mic.wav")
        let system = try writeWAV("e.system.wav")
        let final = dir.appendingPathComponent("e.wav")
        let pidFile = dir.appendingPathComponent("pid")
        let ffmpeg = try fakeFFmpeg("""
        echo $$ > '\(pidFile.path)'
        for a; do last=$a; done
        cp '\(mic.path)' "$last"
        exec sleep 30
        """)

        let ok = await RecordingPostProcessor.produceFinal(
            mic: mic, system: system, final: final, hasMic: true, hasSystem: true,
            ffmpegPath: ffmpeg, ceilingSeconds: 1
        )

        XCTAssertFalse(ok)
        XCTAssertTrue(isGone(try readPid(pidFile)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: final.path), "a killed two-source merge was promoted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: mic.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: system.path))
    }

    // MARK: MuteRedactor

    func test_a_timed_out_redaction_fails_closed_kills_ffmpeg_and_leaves_the_recording() async throws {
        let wav = try writeWAV("c.wav", seconds: 1, channels: 2)
        let original = try Data(contentsOf: wav)
        let pidFile = dir.appendingPathComponent("pid")
        setenv("MEETINGPIPE_LOGS_DIR", dir.appendingPathComponent("logs").path, 1)
        defer { unsetenv("MEETINGPIPE_LOGS_DIR") }
        MuteTimelineFile.write(spans: [MuteTimeline.Span(startSec: 0, endSec: 0.5, source: .manual)], forFinal: wav)
        let ffmpeg = try fakeFFmpeg("echo $$ > '\(pidFile.path)'\nfor a; do last=$a; done\necho partial > \"$last\"\nexec sleep 30")

        let outcome = await MuteRedactor.redactIfNeeded(
            wav: wav, originalsDir: dir.appendingPathComponent("originals"),
            findFFmpeg: { ffmpeg }, ceilingSeconds: 1
        )

        XCTAssertEqual(outcome, .failed(.ffmpegFailed), "a wedged redaction must hold the meeting back, never read as not needed")
        XCTAssertTrue(isGone(try readPid(pidFile)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: wav.deletingPathExtension().appendingPathExtension("redacting.wav").path))
        XCTAssertEqual(try Data(contentsOf: wav), original, "the full recording is untouched")
    }

    func test_the_redaction_ceiling_scales_with_duration() {
        XCTAssertEqual(MuteRedactor.redactionCeilingSeconds(forDurationSec: nil), 60)
        XCTAssertEqual(MuteRedactor.redactionCeilingSeconds(forDurationSec: 3600), 240)
    }

    // MARK: AudioTranscoder

    func test_a_timed_out_flac_encode_throws_leaves_the_wav_and_kills_ffmpeg() throws {
        let wav = try writeWAV("d.wav")
        let original = try Data(contentsOf: wav)
        let pidFile = dir.appendingPathComponent("pid")
        let ffmpeg = try fakeFFmpeg("echo $$ > '\(pidFile.path)'\nexec sleep 30")

        XCTAssertThrowsError(try AudioTranscoder.compressToFLAC(wav: wav, ffmpegPath: ffmpeg, ceilingSeconds: 1)) { error in
            XCTAssertEqual(error as? AudioTranscoder.TranscodeError, .timedOut)
        }
        XCTAssertTrue(isGone(try readPid(pidFile)))
        XCTAssertEqual(try Data(contentsOf: wav), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: wav.deletingPathExtension().appendingPathExtension("flac.writing").path))
    }

    func test_the_flac_ceiling_is_a_minute_plus_five_percent_of_the_duration() {
        XCTAssertEqual(AudioTranscoder.flacCeilingSeconds(forDurationSec: 3600), 240)
    }
}
