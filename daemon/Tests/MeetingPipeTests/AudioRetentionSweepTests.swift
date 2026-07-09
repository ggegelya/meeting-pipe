import XCTest
@testable import MeetingPipe

/// The filesystem half of STOR1: which stems become candidates, and what the
/// sweep does to them. The `compress` path needs ffmpeg, so it is exercised only
/// when one is on the box; the `drop` path is pure `FileManager`.
final class AudioRetentionSweepTests: XCTestCase {

    private var dir: URL!
    private let workflow = UUID()

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mp-retention-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ name: String, _ contents: String = "x") throws {
        try contents.write(
            to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8
        )
    }

    /// A settled, published meeting recorded by `workflow`.
    private func writeSettledMeeting(stem: String, ext: String = "wav") throws {
        try write("\(stem).\(ext)")
        try write("\(stem).summary.json", "{}")
        try write("\(stem).meta.json", #"{"workflow_id": "\#(workflow.uuidString)"}"#)
        try write("\(stem).run.json", #"{"publish_state": "full"}"#)
    }

    // MARK: candidates()

    func test_candidates_include_a_summarized_meeting_with_its_workflow_and_publish_state() throws {
        try writeSettledMeeting(stem: "20260101-120000")
        let candidates = AudioRetentionSweep.candidates(in: dir)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.workflowID, workflow)
        XCTAssertEqual(candidates.first?.publishState, "full")
        XCTAssertEqual(candidates.first?.status, .done)
    }

    func test_candidates_skip_a_meeting_with_no_summary() throws {
        // No `<stem>.summary.json` means `buildMeeting` would not call it `.done`,
        // so it can never be settled and is not worth two JSON reads.
        try write("20260101-120000.wav")
        XCTAssertEqual(AudioRetentionSweep.candidates(in: dir).count, 0)
    }

    func test_candidates_skip_capture_intermediates() throws {
        try write("20260101-120000.mic.wav")
        try write("20260101-120000.system.wav")
        try write("20260101-120000.summary.json", "{}")
        XCTAssertEqual(AudioRetentionSweep.candidates(in: dir).count, 0)
    }

    func test_candidates_find_a_compressed_recording() throws {
        try writeSettledMeeting(stem: "20260101-120000", ext: "flac")
        XCTAssertEqual(
            AudioRetentionSweep.candidates(in: dir).first?.audioURL.pathExtension, "flac"
        )
    }

    // MARK: sweep()

    func test_sweep_short_circuits_when_every_workflow_keeps_forever() throws {
        try writeSettledMeeting(stem: "20260101-120000")
        let outcome = AudioRetentionSweep.sweep(in: dir, policies: [workflow: WorkflowRetention()])
        XCTAssertEqual(outcome, AudioRetentionSweep.Outcome())
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("20260101-120000.wav").path
        ))
    }

    func test_sweep_drops_audio_past_the_window_and_keeps_every_sidecar() throws {
        try writeSettledMeeting(stem: "20260101-120000")
        let outcome = AudioRetentionSweep.sweep(
            in: dir,
            policies: [workflow: WorkflowRetention(policy: .drop, afterDays: 1)],
            now: Date(timeIntervalSince1970: 2_000_000_000)
        )
        XCTAssertEqual(outcome.dropped, 1)
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("20260101-120000.wav").path))
        for sidecar in ["summary.json", "meta.json", "run.json"] {
            XCTAssertTrue(
                fm.fileExists(atPath: dir.appendingPathComponent("20260101-120000.\(sidecar)").path),
                "\(sidecar) must survive a drop"
            )
        }
    }

    func test_sweep_leaves_a_needs_you_meeting_alone() throws {
        try write("20260101-120000.wav")
        try write("20260101-120000.summary.json", "{}")
        try write("20260101-120000.meta.json", #"{"workflow_id": "\#(workflow.uuidString)"}"#)
        try write("20260101-120000.run.json", #"{"publish_state": "partial"}"#)
        let outcome = AudioRetentionSweep.sweep(
            in: dir,
            policies: [workflow: WorkflowRetention(policy: .drop, afterDays: 1)],
            now: Date(timeIntervalSince1970: 2_000_000_000)
        )
        XCTAssertEqual(outcome.dropped, 0)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("20260101-120000.wav").path
        ))
    }
}
