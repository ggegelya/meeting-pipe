import XCTest
@testable import MeetingPipe

/// REC21: the redaction markers' failure modes, and the recovery seam one step past them. Every
/// test here is a path by which a recording that owed a cut used to reach a consumer uncut: a
/// marker that could not be read, a manifest that recovered as `.auto`, a quarantine whose failed
/// move left the final with its markers already deleted, and a merge temp read as a final.
final class RedactionMarkerFailClosedREC21Tests: XCTestCase {

    private var dir: URL!
    private var logs: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rec21-\(UUID().uuidString)", isDirectory: true)
        logs = dir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        setenv("MEETINGPIPE_LOGS_DIR", logs.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("MEETINGPIPE_LOGS_DIR")
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    private let stem = "20261116-100000"
    private var final: URL { dir.appendingPathComponent("\(stem).wav") }
    private var captureModeMarker: URL { dir.appendingPathComponent("\(stem).capturemode") }

    private func writeMarker(_ text: String) throws {
        try Data(text.utf8).write(to: captureModeMarker)
    }

    private func writeManifestRaw(_ body: String) throws {
        try Data(body.utf8).write(to: RecordingManifest.url(forStem: stem, in: dir))
    }

    /// A recoverer that "merges" by writing a stand-in final, so the routing runs without ffmpeg.
    private func recover(originalsDir: URL? = nil) async -> OrphanRecordingRecovery.Recovered {
        await OrphanRecordingRecovery.recover(
            stems: [stem], in: dir, isOwned: { _ in false },
            originalsDir: originalsDir ?? dir.appendingPathComponent("originals"),
            recoverer: { stem, dir in
                let url = dir.appendingPathComponent("\(stem).wav")
                try? Data("RIFF-stand-in".utf8).write(to: url)
                return url
            }
        )
    }

    /// An originals directory the move cannot land in: its path runs under a regular file.
    private func unwritableOriginals() throws -> URL {
        let blocker = dir.appendingPathComponent("not-a-directory")
        try Data("x".utf8).write(to: blocker)
        return blocker.appendingPathComponent("originals")
    }

    private func eventRows(action: String) -> [[String: Any]] {
        let text = (try? String(contentsOf: logs.appendingPathComponent("events.jsonl"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }.filter { $0["action"] as? String == action }
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    // MARK: - The capture-mode marker read

    func test_the_capture_mode_marker_read_tells_absent_from_unreadable() throws {
        XCTAssertEqual(CaptureMode.readMarker(forFinal: final), .absent)
        try writeMarker("capture_first_redact\n")
        XCTAssertEqual(CaptureMode.readMarker(forFinal: final), .recorded(.captureFirstRedact))
        try writeMarker("lossless")
        XCTAssertEqual(CaptureMode.readMarker(forFinal: final), .unreadable, "an unknown token is not absent")
        try Data([0xFF, 0xFE, 0xFD]).write(to: captureModeMarker)
        XCTAssertEqual(CaptureMode.readMarker(forFinal: final), .unreadable, "bytes that are not UTF-8")
        XCTAssertTrue(CaptureMode.MarkerRead.unreadable.owesRedaction)
        XCTAssertFalse(CaptureMode.MarkerRead.recorded(.captureFirst).owesRedaction)
    }

    // MARK: - Recovery fails closed on what it cannot read (item 4)

    func test_a_manifest_saying_off_record_quarantines_with_no_offrecord_file() async throws {
        try writeMarker("capture_first")
        RecordingManifest.write(summaryMode: .auto, meta: [:], captureMode: .captureFirst, offRecord: true, forStem: stem, in: dir)
        let result = await recover()
        XCTAssertTrue(result.ready.isEmpty)
        XCTAssertEqual(result.quarantined.count, 1)
        XCTAssertEqual(eventRows(action: "orphan_quarantined").first?["reason"] as? String, "off_record_no_timeline")
    }

    func test_a_manifest_saying_capture_first_redact_quarantines_with_no_capturemode_file() async throws {
        RecordingManifest.write(summaryMode: .auto, meta: [:], captureMode: .captureFirstRedact, forStem: stem, in: dir)
        let result = await recover()
        XCTAssertEqual(result.quarantined.count, 1)
        XCTAssertEqual(eventRows(action: "orphan_quarantined").first?["reason"] as? String, "capture_first_no_timeline")
    }

    func test_an_unreadable_manifest_quarantines() async throws {
        try writeMarker("capture_first")
        try writeManifestRaw(#"{"schema_version": 1, "summary_mode": "cloud", "meta": {}}"#)
        let result = await recover()
        XCTAssertTrue(result.ready.isEmpty, "an unknown token must not recover as auto")
        XCTAssertEqual(eventRows(action: "orphan_quarantined").first?["reason"] as? String, "manifest_unreadable")
    }

    func test_an_unreadable_manifest_quarantines_even_with_a_timeline() throws {
        // A routing failure, not a redaction one: a timeline does not say which path the meeting
        // was meant to take.
        MuteTimelineFile.write(spans: [MuteTimeline.Span(startSec: 0, endSec: 1)], forFinal: final)
        try writeManifestRaw("{ torn")
        XCTAssertEqual(
            OrphanRecordingRecovery.quarantineReason(
                stem: stem, final: final, in: dir, manifest: RecordingManifest.load(forStem: stem, in: dir)
            ),
            .manifestUnreadable
        )
    }

    func test_an_unreadable_capturemode_quarantines() async throws {
        try writeMarker("not a mode")
        RecordingManifest.write(summaryMode: .auto, meta: [:], forStem: stem, in: dir)
        let result = await recover()
        XCTAssertEqual(result.quarantined.count, 1)
        XCTAssertEqual(eventRows(action: "orphan_quarantined").first?["reason"] as? String, "marker_unreadable")
    }

    func test_a_plain_capture_first_orphan_with_a_readable_manifest_still_recovers_with_its_mode() async throws {
        try writeMarker("capture_first")
        RecordingManifest.write(summaryMode: .byo, meta: [:], captureMode: .captureFirst, forStem: stem, in: dir)
        let result = await recover()
        XCTAssertEqual(result.ready, [OrphanRecordingRecovery.ReadyRecording(url: final, summaryMode: .byo)])
        XCTAssertTrue(result.quarantined.isEmpty)
        XCTAssertFalse(exists(captureModeMarker))
        XCTAssertEqual(RecordingManifest.load(forStem: stem, in: dir), .absent)
    }

    // MARK: - Quarantine first, clear the markers after (item 5, F026)

    func test_a_failed_quarantine_keeps_the_markers_and_the_redactor_still_holds_it() async throws {
        try writeMarker("capture_first_redact")
        RecordingManifest.write(summaryMode: .auto, meta: [:], captureMode: .captureFirstRedact, forStem: stem, in: dir)
        try Data("{}".utf8).write(to: dir.appendingPathComponent("\(stem).recordfail.json"))

        let result = await recover(originalsDir: try unwritableOriginals())

        XCTAssertTrue(result.ready.isEmpty)
        XCTAssertTrue(result.quarantined.isEmpty)
        XCTAssertTrue(exists(final), "the final stays in raw/")
        XCTAssertTrue(exists(captureModeMarker), "the marker that holds a later Retry is kept")
        XCTAssertNotNil(RecordingManifest.load(forStem: stem, in: dir).parsed, "and so is the manifest")
        XCTAssertFalse(exists(dir.appendingPathComponent("\(stem).recordfail.json")), "the merge worked, so the breadcrumb is stale")
        let failed = eventRows(action: "orphan_quarantine_failed")
        XCTAssertEqual(failed.count, 1)
        XCTAssertEqual(failed.first?["stem"] as? String, stem)
        XCTAssertEqual(failed.first?["reason"] as? String, "capture_first_no_timeline")
        XCTAssertNotNil(failed.first?["error_domain"] as? String)
        XCTAssertNotNil(failed.first?["error_code"] as? Int)

        let outcome = await MuteRedactor.redactIfNeeded(wav: final, originalsDir: dir.appendingPathComponent("o2"))
        XCTAssertEqual(outcome, .failed(.timelineMissing))
    }

    func test_a_successful_quarantine_still_clears_all_four_start_files() async throws {
        try writeMarker("capture_first_redact")
        try OffRecordMarker.write(forFinal: final)
        RecordingManifest.write(summaryMode: .auto, meta: [:], captureMode: .captureFirstRedact, forStem: stem, in: dir)
        try Data("{}".utf8).write(to: dir.appendingPathComponent("\(stem).recordfail.json"))

        let result = await recover()

        XCTAssertEqual(result.quarantined.count, 1)
        XCTAssertFalse(exists(final))
        for suffix in ["capturemode", "offrecord", "recordfail.json", "recovery.json"] {
            XCTAssertFalse(exists(dir.appendingPathComponent("\(stem).\(suffix)")), suffix)
        }
    }

    func test_a_manifest_unreadable_orphan_whose_move_fails_is_refused_by_retry() async throws {
        try writeManifestRaw("{ torn")
        _ = await recover(originalsDir: try unwritableOriginals())
        XCTAssertEqual(RecordingManifest.load(forStem: stem, in: dir), .unreadable, "kept beside the final")

        var enqueued: [URL] = []
        let root = dir!
        let service = MeetingLibraryService(
            outputDir: { root }, launcher: FakePipelineDriver(), notifyError: { _ in },
            enqueue: { file, _, _ in enqueued.append(file) }
        )
        guard case .failure(let error) = service.retryMeeting(stem: stem) else {
            return XCTFail("a retry of a recording whose routing cannot be read must refuse")
        }
        XCTAssertEqual(error as? MeetingLibraryService.LibraryError, .recoveryManifestUnreadable(stem: stem))
        XCTAssertTrue(enqueued.isEmpty)
    }

    /// The advisor's trace: the manifest is the only thing saying a cut was owed, the move failed,
    /// and the redactor never reads the manifest. Retry has to carry it onto the job.
    func test_a_retry_carries_a_manifest_only_redaction_onto_the_job() async throws {
        RecordingManifest.write(summaryMode: .auto, meta: [:], captureMode: .captureFirstRedact, forStem: stem, in: dir)
        _ = await recover(originalsDir: try unwritableOriginals())
        XCTAssertFalse(exists(captureModeMarker), "no disk marker: the manifest is the only record")

        var owed: [Bool] = []
        let root = dir!
        let service = MeetingLibraryService(
            outputDir: { root }, launcher: FakePipelineDriver(), notifyError: { _ in },
            enqueue: { _, _, redactionOwed in owed.append(redactionOwed) }
        )
        XCTAssertNoThrow(try service.retryMeeting(stem: stem).get())
        XCTAssertEqual(owed, [true])
        XCTAssertTrue(OffRecordMarker.exists(forFinal: final), "the debt is on disk before the manifest goes")
        XCTAssertEqual(RecordingManifest.load(forStem: stem, in: dir), .absent)
        let outcome = await MuteRedactor.redactIfNeeded(
            wav: final, redactionOwed: owed[0], originalsDir: dir.appendingPathComponent("o2")
        )
        XCTAssertEqual(outcome, .failed(.timelineMissing))
    }

    func test_a_retranscribe_refuses_an_unreadable_manifest_and_records_an_owed_cut() async throws {
        try Data("RIFF-stand-in".utf8).write(to: final)
        try writeManifestRaw("{ torn")
        var queued: [URL] = []
        let root = dir!
        let service = MeetingLibraryService(
            outputDir: { root }, launcher: FakePipelineDriver(), notifyError: { _ in },
            enqueue: { _, _, _ in },
            enqueueRetranscribe: { file, _ in queued.append(file) }
        )
        var refused: Error?
        service.retranscribeMeeting(stem: stem) { if case .failure(let e) = $0 { refused = e } }
        XCTAssertEqual(refused as? MeetingLibraryService.LibraryError, .recoveryManifestUnreadable(stem: stem))
        XCTAssertTrue(queued.isEmpty)

        RecordingManifest.write(summaryMode: .auto, meta: [:], captureMode: .captureFirst, offRecord: true, forStem: stem, in: dir)
        service.retranscribeMeeting(stem: stem) { _ in }
        XCTAssertEqual(queued, [final])
        XCTAssertTrue(OffRecordMarker.exists(forFinal: final), "the redactor in the re-transcribe job reads it")
    }

    // MARK: - The redactor's job input (item 3)

    func test_a_job_that_owes_a_redaction_with_no_timeline_and_no_markers_fails_closed() async {
        try? Data("RIFF".utf8).write(to: final)
        let originals = dir.appendingPathComponent("originals")
        let owed = await MuteRedactor.redactIfNeeded(wav: final, redactionOwed: true, originalsDir: originals)
        XCTAssertEqual(owed, .failed(.timelineMissing))
        let notOwed = await MuteRedactor.redactIfNeeded(wav: final, redactionOwed: false, originalsDir: originals)
        XCTAssertEqual(notOwed, .notNeeded)
    }

    func test_an_unreadable_capturemode_beside_a_final_fails_closed_in_the_redactor() async throws {
        try? Data("RIFF".utf8).write(to: final)
        try writeMarker("garbage")
        let outcome = await MuteRedactor.redactIfNeeded(wav: final, originalsDir: dir.appendingPathComponent("o"))
        XCTAssertEqual(outcome, .failed(.timelineMissing))
    }

    // MARK: - The merge temp is not a final (item 7, F164)

    func test_a_merge_temp_beside_the_intermediates_is_not_a_stranded_final() {
        XCTAssertEqual(
            StrandedJobRecovery.detect(fileNames: ["\(stem).mic.wav", "\(stem).system.wav", "\(stem).merging.wav"]),
            []
        )
        XCTAssertEqual(StrandedJobRecovery.detect(fileNames: ["\(stem).wav"]), [stem])
    }

    // MARK: - The marker write reports (item 1)

    func test_the_offrecord_marker_write_throws_when_it_cannot_land() {
        let nowhere = dir.appendingPathComponent("missing-dir/\(stem).wav")
        XCTAssertThrowsError(try OffRecordMarker.write(forFinal: nowhere))
    }

}
