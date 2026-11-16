import AVFoundation
import XCTest
@testable import MeetingPipe

/// REC34: the mute timeline reaches disk on every exit that can still read it safely, so a quit
/// or a failed merge during an off-the-record recording is redacted at the next launch rather
/// than quarantined. The recorder's two call sites need a live engine, so their placement is
/// fenced against the source and the rule they share is driven directly.
final class MuteTimelineAtQuitREC34Tests: XCTestCase {

    private var dir: URL!
    private var logs: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rec34-\(UUID().uuidString)", isDirectory: true)
        logs = dir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        setenv("MEETINGPIPE_LOGS_DIR", logs.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("MEETINGPIPE_LOGS_DIR")
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    private let stem = "20261117-090000"
    private var final: URL { dir.appendingPathComponent("\(stem).wav") }

    /// A timeline with one auto mute at 0-1 s and one manual off-the-record span at 2-3 s.
    private func timeline() -> MuteTimeline {
        var t = MuteTimeline()
        t.add(startSec: 0, endSec: 1, muted: true, source: .mute)
        t.add(startSec: 1, endSec: 2, muted: false)
        t.add(startSec: 2, endSec: 3, muted: true, source: .manual)
        t.finalize()
        return t
    }

    private func eventRows(action: String) -> [[String: Any]] {
        let text = (try? String(contentsOf: logs.appendingPathComponent("events.jsonl"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }.filter { $0["action"] as? String == action }
    }

    // MARK: - The one rule

    func test_each_mode_keeps_what_the_stop_path_always_kept() {
        let t = timeline()
        XCTAssertEqual(MuteTimelinePersistence.spans(for: .captureFirstRedact, from: t), t.spans)
        XCTAssertEqual(
            MuteTimelinePersistence.spans(for: .captureFirst, from: t),
            [MuteTimeline.Span(startSec: 2, endSec: 3, source: .manual)]
        )
        XCTAssertNil(MuteTimelinePersistence.spans(for: .regulatedGate, from: t))
        var autoOnly = MuteTimeline()
        autoOnly.add(startSec: 0, endSec: 1, muted: true, source: .mute)
        autoOnly.finalize()
        XCTAssertNil(MuteTimelinePersistence.spans(for: .captureFirst, from: autoOnly), "no manual span, nothing to keep")
    }

    func test_a_termination_write_keyed_by_stem_lands_with_no_final_and_says_so() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: final.path))
        XCTAssertEqual(
            MuteTimelinePersistence.persist(timeline(), mode: .captureFirst, forFinal: final, path: .termination),
            .written
        )
        let file = try XCTUnwrap(MuteTimelineFile.read(forFinal: final))
        XCTAssertEqual(file.spans, [MuteTimeline.Span(startSec: 2, endSec: 3, source: .manual)])
        let row = try XCTUnwrap(eventRows(action: "mute_timeline_written").first)
        XCTAssertEqual(row["path"] as? String, "termination")
        XCTAssertEqual(row["manual_spans"] as? Int, 1)
        XCTAssertEqual(row["source"] as? String, "manual")
    }

    func test_redact_opt_in_writes_every_span_and_regulated_writes_nothing() throws {
        XCTAssertEqual(
            MuteTimelinePersistence.persist(timeline(), mode: .captureFirstRedact, forFinal: final, path: .stop),
            .written
        )
        XCTAssertEqual(MuteTimelineFile.read(forFinal: final)?.spans.count, 2)
        XCTAssertEqual(eventRows(action: "mute_timeline_written").first?["path"] as? String, "stop")

        let other = dir.appendingPathComponent("other.wav")
        XCTAssertEqual(
            MuteTimelinePersistence.persist(timeline(), mode: .regulatedGate, forFinal: other, path: .termination),
            .nothingToWrite
        )
        XCTAssertNil(MuteTimelineFile.read(forFinal: other))
    }

    func test_a_failed_write_reports_with_its_path() {
        let nowhere = dir.appendingPathComponent("missing/\(stem).wav")
        XCTAssertEqual(
            MuteTimelinePersistence.persist(timeline(), mode: .captureFirst, forFinal: nowhere, path: .termination),
            .failed
        )
        XCTAssertEqual(eventRows(action: "mute_timeline_write_failed").first?["path"] as? String, "termination")
    }

    // MARK: - The recorder's call sites

    private func recorderSource() throws -> String {
        let here = URL(fileURLWithPath: #filePath)
        let url = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MeetingPipe/MeetingRecorder.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func body(of signature: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: signature), "\(signature) not found")
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    }\n")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    func test_the_termination_flush_writes_only_after_a_clean_teardown_and_before_the_drain() throws {
        let flush = try body(of: "func flushIntermediatesForTermination()", in: try recorderSource())
        XCTAssertTrue(flush.contains("var tapIsGone = false"), "assume the tap is live until shown otherwise")
        let clean = try XCTUnwrap(flush.range(of: "tapIsGone = teardown.isClean && deviceRecovery.recoveryTask == nil"))
        let finalize = try XCTUnwrap(flush.range(of: "muteTimeline.finalize()"))
        let gate = try XCTUnwrap(flush.range(of: "if tapIsGone {"))
        let write = try XCTUnwrap(flush.range(of: "MuteTimelinePersistence.persist(muteTimeline, mode: captureMode, forFinal: final, path: .termination)"))
        let skipped = try XCTUnwrap(flush.range(of: "\"mute_timeline_write_skipped\""))
        let drain = try XCTUnwrap(flush.range(of: "micWriter?.finish(timeout:"))
        XCTAssertLessThan(clean.lowerBound, gate.lowerBound)
        XCTAssertLessThan(gate.lowerBound, finalize.lowerBound, "even finalize reads the timeline, so it sits inside the gate")
        XCTAssertLessThan(finalize.lowerBound, write.lowerBound)
        XCTAssertLessThan(write.lowerBound, skipped.lowerBound, "the skip is the else branch")
        XCTAssertLessThan(skipped.lowerBound, drain.lowerBound, "written before a slow drain can starve it")
        XCTAssertEqual(flush.components(separatedBy: "muteTimeline").count - 1, 2, "read only inside the clean branch")
    }

    func test_the_stop_path_writes_whether_or_not_the_merge_produced_a_final() throws {
        let persist = try body(of: "private func persistAfterMerge(final: URL, producedUsableFinal: Bool, spanSec: Double) {", in: try recorderSource())
        let finalize = try XCTUnwrap(persist.range(of: "muteTimeline.finalize()"))
        let write = try XCTUnwrap(persist.range(of: "MuteTimelinePersistence.persist("))
        XCTAssertLessThan(finalize.lowerBound, write.lowerBound)
        XCTAssertTrue(persist.contains("path: .stop"))
        let beforeWrite = persist[..<write.lowerBound]
        XCTAssertFalse(beforeWrite.contains("producedUsableFinal"), "nothing about the merge's outcome gates the write")
        XCTAssertFalse(beforeWrite.contains("guard "), "no early exit before the write")
        XCTAssertFalse(persist.contains("fileExists(atPath: final.path)"), "no final-exists gate on the write")
        XCTAssertTrue(persist.contains("if producedUsableFinal, !timelineWriteFailed {"), "the marker is still kept on a failed merge")
    }

    // MARK: - Quit, then recover: redact and enqueue

    func test_an_off_the_record_recording_quit_mid_call_recovers_redacted_not_quarantined() async throws {
        guard RecordingPostProcessor.findFFmpeg() != nil else {
            if ProcessInfo.processInfo.environment["CI"] == "true" { return XCTFail("ffmpeg missing on CI") }
            throw XCTSkip("ffmpeg not available (local run)")
        }
        // What a quit leaves: the start markers, the manifest, and (since REC34) the timeline the
        // termination flush wrote for the stem.
        try "capture_first".write(to: dir.appendingPathComponent("\(stem).capturemode"), atomically: true, encoding: .utf8)
        try OffRecordMarker.write(forFinal: final)
        RecordingManifest.write(summaryMode: .auto, meta: [:], captureMode: .captureFirst, offRecord: true, forStem: stem, in: dir)
        XCTAssertEqual(
            MuteTimelinePersistence.persist(timeline(), mode: .captureFirst, forFinal: final, path: .termination),
            .written
        )

        let result = await OrphanRecordingRecovery.recover(
            stems: [stem], in: dir, isOwned: { _ in false },
            originalsDir: dir.appendingPathComponent("originals"),
            recoverer: { [self] stem, dir in
                let url = dir.appendingPathComponent("\(stem).wav")
                try? writeStereoWav(at: url, seconds: 4, left: 0.5, right: 0.5)
                return url
            }
        )
        XCTAssertEqual(result.ready.map(\.url), [final])
        XCTAssertTrue(result.quarantined.isEmpty)
        XCTAssertTrue(eventRows(action: "orphan_quarantined").isEmpty)

        let outcome = await MuteRedactor.redactIfNeeded(wav: final, originalsDir: dir.appendingPathComponent("originals"))
        XCTAssertEqual(outcome, .redacted)
        let read = try AVAudioFile(forReading: final)
        let buf = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: read.processingFormat, frameCapacity: AVAudioFrameCount(read.length)))
        try read.read(into: buf)
        let rate = read.processingFormat.sampleRate
        let mic = try XCTUnwrap(buf.floatChannelData?[0])
        let system = try XCTUnwrap(buf.floatChannelData?[1])
        let inSpan = Int(2.5 * rate)
        let outside = Int(1.5 * rate)
        XCTAssertEqual(mic[inSpan], 0, accuracy: 1e-4, "the off-the-record span is cut from the mic")
        XCTAssertGreaterThan(abs(mic[outside]), 0.1, "audio outside it is kept")
        XCTAssertGreaterThan(abs(system[inSpan]), 0.1, "the system channel is untouched")
    }

    private func writeStereoWav(at url: URL, seconds: Double, left: Float, right: Float) throws {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 2, interleaved: false)!
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
}
