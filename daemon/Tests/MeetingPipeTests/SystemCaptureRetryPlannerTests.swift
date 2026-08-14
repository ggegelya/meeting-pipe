import AVFoundation
import XCTest
@testable import MeetingPipe

/// REC10: the retry-after-a-mid-meeting-SCStream-death decision, plus the file-level
/// mechanism it rests on.
///
/// The live path cannot be driven here (it needs an SCStream to kill mid-call), so it is
/// split the way the rest of this codebase splits such things: the branching and the gap
/// math are pure and pinned below, and the one platform fact the whole task turns on -
/// that `AVAudioFile(forWriting:)` destroys an existing recording while an open handle
/// appends to it - is pinned against real files on disk rather than asserted from the SDK
/// header.
final class SystemCaptureRetryPlannerTests: XCTestCase {

    private let sampleRate: Double = 48000

    // MARK: - plan

    /// The first start, and a retry after an initial SCStream failure (which deletes the
    /// path and drops the writer), both have nothing to preserve.
    func test_plan_opens_fresh_when_no_file_is_open() {
        let plan = SystemCaptureRetryPlanner.plan(
            hasOpenFile: false,
            capturedFirstFrame: false,
            lostAtUptime: 100,
            retryAtUptime: 107,
            sampleRate: sampleRate
        )
        XCTAssertEqual(plan, .openFresh)
    }

    /// A file that never took a frame holds a WAV header and nothing else, so reopening
    /// it costs no audio and keeps the head-offset reset in one place.
    func test_plan_opens_fresh_when_the_open_file_never_took_a_frame() {
        let plan = SystemCaptureRetryPlanner.plan(
            hasOpenFile: true,
            capturedFirstFrame: false,
            lostAtUptime: 100,
            retryAtUptime: 107,
            sampleRate: sampleRate
        )
        XCTAssertEqual(plan, .openFresh)
    }

    /// The defect this task exists to close: with captured audio in an open file, the
    /// retry resumes it instead of truncating it, and pads the outage it is resuming
    /// across. REC8's automatic retry fires ~7 s after the loss.
    func test_plan_resumes_and_pads_the_outage_when_audio_was_captured() {
        let plan = SystemCaptureRetryPlanner.plan(
            hasOpenFile: true,
            capturedFirstFrame: true,
            lostAtUptime: 100,
            retryAtUptime: 107,
            sampleRate: sampleRate
        )
        XCTAssertEqual(plan, .resumeOpenFile(padFrames: 7 * 48000, gapSeconds: 7, clamped: false))
    }

    /// No loss mark means the outage cannot be measured. Resuming unpadded misplaces the
    /// recovered audio; reopening destroys the captured audio. Only one of those is
    /// recoverable, so it resumes.
    func test_plan_resumes_unpadded_when_the_loss_was_never_dated() {
        let plan = SystemCaptureRetryPlanner.plan(
            hasOpenFile: true,
            capturedFirstFrame: true,
            lostAtUptime: 0,
            retryAtUptime: 107,
            sampleRate: sampleRate
        )
        XCTAssertEqual(plan, .resumeOpenFile(padFrames: 0, gapSeconds: 0, clamped: false))
    }

    func test_plan_resumes_unpadded_when_the_clock_ran_backwards() {
        let plan = SystemCaptureRetryPlanner.plan(
            hasOpenFile: true,
            capturedFirstFrame: true,
            lostAtUptime: 200,
            retryAtUptime: 107,
            sampleRate: sampleRate
        )
        XCTAssertEqual(plan, .resumeOpenFile(padFrames: 0, gapSeconds: 0, clamped: false))
    }

    /// A pathological outage is padded to the ceiling and REPORTED as clamped, so the
    /// resulting misalignment is on the record. A quietly clamped pad would be the same
    /// silent-misplacement failure this task was filed against, wearing a fix.
    func test_plan_clamps_a_pathological_outage_and_says_so() {
        let gap = SystemCaptureRetryPlanner.maxPadSeconds + 600
        let plan = SystemCaptureRetryPlanner.plan(
            hasOpenFile: true,
            capturedFirstFrame: true,
            lostAtUptime: 100,
            retryAtUptime: 100 + gap,
            sampleRate: sampleRate
        )
        XCTAssertEqual(plan, .resumeOpenFile(
            padFrames: AVAudioFrameCount(SystemCaptureRetryPlanner.maxPadSeconds * sampleRate),
            gapSeconds: gap,
            clamped: true
        ))
    }

    // MARK: - the file-level mechanism

    private func captureFormat() -> AVAudioFormat {
        SystemAudioCapture.captureFormat
    }

    /// A buffer of `frames` frames whose samples are all `value`, so a test can tell
    /// captured audio from padded silence by reading the file back.
    private func toneBuffer(frames: AVAudioFrameCount, value: Float) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: captureFormat(), frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(captureFormat().channelCount) {
            let samples = buffer.floatChannelData![channel]
            for frame in 0..<Int(frames) { samples[frame] = value }
        }
        return buffer
    }

    /// Read a finished WAV back off disk. Always via a fresh reader, never via the
    /// writing handle's own `length`: `AVAudioFile` buffers, so a write handle reports a
    /// frame count rounded to what it has flushed (4096 for 4800 written) and the file's
    /// header is not valid until the handle is released. That is the same reason
    /// `stop()` drops `micFile` / `systemFile` before ffmpeg reads them.
    private func readAllFrames(at url: URL) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(max(file.length, 1))
        )!
        try file.read(into: buffer)
        return buffer
    }

    /// The SDK contract the whole defect rests on, measured rather than quoted: opening a
    /// path that already holds a recording `forWriting` destroys it. This is what
    /// `retrySystemAudio` used to do on every automatic recovery, which is why the
    /// `.openFresh` branch is now the only one a retry can reach with an empty file.
    func test_reopening_the_path_for_writing_destroys_the_captured_audio() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rec10-truncate-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        var first: AVAudioFile? = try AVAudioFile(forWriting: url, settings: captureFormat().settings)
        try first?.write(from: toneBuffer(frames: 4800, value: 0.5))
        first = nil  // release so the WAV header flushes, as stop() does before ffmpeg reads
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 4800)

        // What a retry used to do.
        var second: AVAudioFile? = try AVAudioFile(forWriting: url, settings: captureFormat().settings)
        second = nil
        XCTAssertEqual(
            try AVAudioFile(forReading: url).length, 0,
            "forWriting overwrites: the pre-loss capture is gone"
        )
    }

    /// The fix, end to end over a real writer and a real file: pre-loss audio survives,
    /// the outage is silence, and the recovered audio lands after both rather than at
    /// sample 0.
    func test_resuming_the_open_file_keeps_the_pre_loss_audio_and_places_the_recovery() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rec10-resume-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let preLossFrames: AVAudioFrameCount = 4800   // 0.1 s captured before the death
        let padFrames: AVAudioFrameCount = 9600       // 0.2 s outage
        let recoveredFrames: AVAudioFrameCount = 2400 // 0.05 s captured after the retry

        var sink: AVAudioFile? = try AVAudioFile(forWriting: url, settings: captureFormat().settings)
        var writer: SerialBufferWriter<AVAudioPCMBuffer>? = SerialBufferWriter(label: "test.rec10") { [weak sink] buffer in
            try? sink?.write(from: buffer)
        }

        writer?.enqueue(toneBuffer(frames: preLossFrames, value: 0.5))
        // The stream dies here. handleSystemAudioLost leaves the file and the writer
        // open, and the retry resumes them behind a pad instead of reopening the path.
        writer?.enqueue(toneBuffer(frames: padFrames, value: 0))
        writer?.enqueue(toneBuffer(frames: recoveredFrames, value: -0.25))
        writer?.finish(timeout: 5)
        // Release EVERY strong reference to the write handle so the WAV header flushes.
        // stop() does the same (drain the writer, then drop the file) before ffmpeg
        // reads, and it is the reason a mid-write `length` read cannot be trusted.
        writer = nil
        sink = nil

        let read = try readAllFrames(at: url)
        XCTAssertEqual(read.frameLength, preLossFrames + padFrames + recoveredFrames)
        let samples = read.floatChannelData![0]
        XCTAssertEqual(samples[0], 0.5, accuracy: 0.001, "the pre-loss capture survived")
        XCTAssertEqual(
            samples[Int(preLossFrames) - 1], 0.5, accuracy: 0.001,
            "the whole pre-loss capture survived, not just its head"
        )
        XCTAssertEqual(samples[Int(preLossFrames)], 0, accuracy: 0.001, "the outage reads as silence")
        XCTAssertEqual(
            samples[Int(preLossFrames + padFrames)], -0.25, accuracy: 0.001,
            "the recovered audio starts at the offset it was captured at, not at sample 0"
        )
    }
}
