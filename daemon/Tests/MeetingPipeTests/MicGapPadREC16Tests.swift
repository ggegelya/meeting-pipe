import AVFoundation
import XCTest
@testable import MeetingPipe

/// REC16's 2026-11-13 amendment, the pure halves: the mic pad is clamped and enqueued in shared
/// 1 s chunks charged once (F028), its gap starts at the last delivered buffer (F029), the
/// converter path collapses to the loudest channel before resampling (F156), and the owner sees
/// one notification per recovery episode (item 7). The recovery paths that use these are driven
/// through the fake host in `InputDeviceRecoveryTests`; the engine-bound paths stay untested for
/// REC12's reason.
final class MicGapPadREC16Tests: XCTestCase {

    private let mono48k = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!

    // MARK: - Clamp and chunk (F028)

    func test_anHourGapIsClampedToTheSharedCeiling() {
        let pad = CaptureRecoveryPlanner.micPad(gapSeconds: 3_600, sampleRate: 48_000)
        XCTAssertTrue(pad.clamped)
        XCTAssertEqual(pad.frames, AVAudioFrameCount(SystemCaptureRetryPlanner.maxPadSeconds * 48_000))

        let short = CaptureRecoveryPlanner.micPad(gapSeconds: 1.7, sampleRate: 48_000)
        XCTAssertFalse(short.clamped)
        XCTAssertEqual(short.frames, 81_600)
    }

    /// Red against the old `padMicGap`, which enqueued one buffer of the whole span and charged
    /// all of it: 3,600 s at 48 kHz mono Float32 is about 691 MB, past the 512 MB hard cap alone.
    func test_aClampedPadChargesOneChunkNotTheWholeSpan() {
        let pad = CaptureRecoveryPlanner.micPad(gapSeconds: 3_600, sampleRate: 48_000)
        var charged = 0
        var frames: AVAudioFrameCount = 0
        var distinctBuffers = Set<ObjectIdentifier>()
        MeetingRecorder.enqueueSilence(frames: pad.frames, format: mono48k) { buffer, bytes in
            charged += bytes
            frames += buffer.frameLength
            distinctBuffers.insert(ObjectIdentifier(buffer))
        }
        XCTAssertEqual(frames, pad.frames, "every padded frame is enqueued")
        XCTAssertEqual(charged, 48_000 * 4, "one 1 s chunk's bytes, charged once")
        XCTAssertEqual(distinctBuffers.count, 1, "one buffer of memory, enqueued repeatedly")
        XCTAssertLessThan(charged, WriterBacklogPolicy.hardCapBytes)
    }

    func test_aPadUnderOneSecondStillEnqueuesItsTail() {
        var enqueued: [(AVAudioFrameCount, Int)] = []
        MeetingRecorder.enqueueSilence(frames: 2_400, format: mono48k) { enqueued.append(($0.frameLength, $1)) }
        XCTAssertEqual(enqueued.count, 1)
        XCTAssertEqual(enqueued.first?.0, 2_400)
        XCTAssertEqual(enqueued.first?.1, 2_400 * 4)
    }

    func test_aPadOfOneAndAHalfSecondsIsAChunkAndATail() {
        var enqueued: [(AVAudioFrameCount, Int)] = []
        MeetingRecorder.enqueueSilence(frames: 72_000, format: mono48k) { enqueued.append(($0.frameLength, $1)) }
        XCTAssertEqual(enqueued.map(\.0), [48_000, 24_000])
        XCTAssertEqual(enqueued.map(\.1), [48_000 * 4, 24_000 * 4])
    }

    // MARK: - Where the gap starts (F029)

    func test_theGapStartsAtTheLastBuffer() {
        let now = Date()
        let last = now.addingTimeInterval(-1.7)
        XCTAssertEqual(CaptureRecoveryPlanner.micGapStart(now: now, lastBufferAt: last, paddedThrough: nil), last)
    }

    func test_withNoBufferTheGapStartsNow() {
        let now = Date()
        XCTAssertEqual(CaptureRecoveryPlanner.micGapStart(now: now, lastBufferAt: nil, paddedThrough: nil), now)
        XCTAssertEqual(
            CaptureRecoveryPlanner.micGapStart(now: now, lastBufferAt: now.addingTimeInterval(3), paddedThrough: nil), now,
            "a clock that stepped back reads as now, never as a negative gap"
        )
    }

    func test_aPadAlreadyCoveringTheSpanMovesTheStartUp() {
        let now = Date()
        let last = now.addingTimeInterval(-1.7)
        let resumed = now.addingTimeInterval(-0.2)
        XCTAssertEqual(CaptureRecoveryPlanner.micGapStart(now: now, lastBufferAt: last, paddedThrough: resumed), resumed)
    }

    // MARK: - Collapse before converting (F156)

    /// Only a rate change needs the converter now; a channel change alone takes `collapseToMono`.
    func test_onlyARateChangeNeedsTheConverter() {
        let stereo48k = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let stereo24k = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 2)!
        XCTAssertEqual(CaptureRecoveryPlanner.plan(isRecording: true, fileFormat: mono48k, liveFormat: stereo48k), .resume(needsConverter: false))
        XCTAssertEqual(CaptureRecoveryPlanner.plan(isRecording: true, fileFormat: mono48k, liveFormat: stereo24k), .resume(needsConverter: true))
    }

    /// A 2-channel buffer whose second channel is louder, through the converter path at a
    /// different live rate, keeps the second channel, the one `start()` would have picked.
    func test_theConverterPathKeepsTheLoudestChannel() throws {
        let live = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 2)!
        let raw = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: live, frameCapacity: 4_800))
        raw.frameLength = 4_800
        let data = try XCTUnwrap(raw.floatChannelData)
        for i in 0..<4_800 {
            data[0][i] = 0
            data[1][i] = 0.5
        }
        let monoLive = try XCTUnwrap(MeetingRecorder.monoCaptureFormat(from: live))
        let converter = try XCTUnwrap(AVAudioConverter(from: monoLive, to: mono48k))

        let out = try XCTUnwrap(MeetingRecorder.convertMicBuffer(raw, using: converter, to: mono48k))

        XCTAssertEqual(out.format.sampleRate, 48_000)
        XCTAssertEqual(out.format.channelCount, 1)
        let samples = UnsafeBufferPointer(start: try XCTUnwrap(out.floatChannelData)[0], count: Int(out.frameLength))
        let middle = samples[(samples.count / 4)..<(3 * samples.count / 4)]
        XCTAssertEqual(middle.reduce(0, +) / Float(middle.count), 0.5, accuracy: 0.05, "the louder channel, resampled")
    }

    // MARK: - One notification per episode (item 7)

    func test_threeRecoveriesInsideTheWindowPostOneNotification() {
        var coalescer = RecoveredNoticeCoalescer()
        let start = Date()
        let posts = [0.0, 0.7, 1.5].filter { coalescer.shouldNotifyResumed(at: start.addingTimeInterval($0)) }
        XCTAssertEqual(posts, [0.0])
    }

    func test_aRecoveryPastTheWindowIsANewEpisode() {
        var coalescer = RecoveredNoticeCoalescer()
        let start = Date()
        XCTAssertTrue(coalescer.shouldNotifyResumed(at: start))
        XCTAssertTrue(coalescer.shouldNotifyResumed(at: start.addingTimeInterval(RecoveredNoticeCoalescer.windowSeconds + 1)))
    }

    func test_aFailureEndsTheEpisode() {
        var coalescer = RecoveredNoticeCoalescer()
        let start = Date()
        XCTAssertTrue(coalescer.shouldNotifyResumed(at: start))
        coalescer.noteFailed()
        XCTAssertTrue(coalescer.shouldNotifyResumed(at: start.addingTimeInterval(1)), "the mic came back after a lost notice")
    }

    func test_aNewRecordingStartsANewEpisode() {
        var coalescer = RecoveredNoticeCoalescer()
        let start = Date()
        XCTAssertTrue(coalescer.shouldNotifyResumed(at: start, recording: URL(fileURLWithPath: "/r/a.wav")))
        XCTAssertTrue(coalescer.shouldNotifyResumed(at: start.addingTimeInterval(2), recording: URL(fileURLWithPath: "/r/b.wav")))
        XCTAssertFalse(coalescer.shouldNotifyResumed(at: start.addingTimeInterval(3), recording: URL(fileURLWithPath: "/r/b.wav")))
    }

    /// T7 source fence (deliberate): the real `padMicGap` goes through the chunked helper.
    /// Missing seam: it writes to the recorder's live `micWriter`, which only `start()` opens; the
    /// fake host in `InputDeviceRecoveryTests` stands in for it, so no test reaches this body.
    func test_padMicGapEnqueuesThroughTheChunkedHelper() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/MeetingPipe/MeetingRecorder.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "func padMicGap(frames: AVAudioFrameCount, format: AVAudioFormat) {"))
        let end = try XCTUnwrap(source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex))
        let body = String(source[start.upperBound..<end.lowerBound])
        XCTAssertTrue(body.contains("Self.enqueueSilence(frames: frames, format: format)"))
        XCTAssertFalse(body.contains("makeSilenceBuffer"), "never one buffer the length of the gap")
    }

    /// T7 source fence (deliberate): the coalescer gates the notification only, and the
    /// `recording` / `recovered` row stays one per recovery. Missing seam: the handler lives in
    /// `Coordinator.start()`, which has no headless form to drive.
    func test_theCoordinatorGatesTheNoticeButNotTheRow() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/MeetingPipe/Coordinator.swift"), encoding: .utf8)
        let resumed = try XCTUnwrap(source.range(of: "case .resumed:"))
        let failed = try XCTUnwrap(source.range(of: "case .failed:", range: resumed.upperBound..<source.endIndex))
        let branch = String(source[resumed.upperBound..<failed.lowerBound])
        let row = try XCTUnwrap(branch.range(of: #"action: "recovered""#))
        let gate = try XCTUnwrap(branch.range(of: "recoveredNotices.shouldNotifyResumed("))
        let notify = try XCTUnwrap(branch.range(of: "notifier.notifyCaptureRecovered()"))
        XCTAssertLessThan(row.lowerBound, gate.lowerBound, "the row is written before, and outside, the gate")
        XCTAssertLessThan(gate.lowerBound, notify.lowerBound)
    }
}
