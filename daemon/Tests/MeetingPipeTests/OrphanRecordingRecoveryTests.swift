import XCTest
@testable import MeetingPipe

/// Pure-logic tests for `OrphanRecordingRecovery.detectOrphanStems`.
///
/// The recovery scan is the unit that decides which recordings were
/// lost when the daemon terminated mid-recording. The merge itself
/// shells out to ffmpeg and is runtime-verified during dogfood; only
/// the orphan-detection logic is in scope here.
final class OrphanRecordingRecoveryTests: XCTestCase {

    func test_intermediate_pair_without_final_wav_is_an_orphan() {
        let stems = OrphanRecordingRecovery.detectOrphanStems(fileNames: [
            "20260522-103108.mic.wav",
            "20260522-103108.system.wav",
        ])
        XCTAssertEqual(stems, ["20260522-103108"])
    }

    func test_intermediates_with_a_final_wav_are_not_an_orphan() {
        // stop() ran: the merge produced the final .wav. Even if an
        // intermediate lingered, the recording is not lost.
        let stems = OrphanRecordingRecovery.detectOrphanStems(fileNames: [
            "20260522-103108.mic.wav",
            "20260522-103108.system.wav",
            "20260522-103108.wav",
        ])
        XCTAssertTrue(stems.isEmpty)
    }

    func test_lone_mic_intermediate_is_an_orphan() {
        // Screen Recording denied: only the mic side was captured.
        let stems = OrphanRecordingRecovery.detectOrphanStems(fileNames: ["x.mic.wav"])
        XCTAssertEqual(stems, ["x"])
    }

    func test_lone_system_intermediate_is_an_orphan() {
        let stems = OrphanRecordingRecovery.detectOrphanStems(fileNames: ["x.system.wav"])
        XCTAssertEqual(stems, ["x"])
    }

    func test_sidecars_do_not_count_as_a_final_wav() {
        // A `.mic.wav` name also ends in `.wav`; the scan must not let
        // sidecars or the intermediate itself satisfy the final-wav
        // check.
        let stems = OrphanRecordingRecovery.detectOrphanStems(fileNames: [
            "x.mic.wav", "x.system.wav",
            "x.summary.json", "x.meta.json", "x.md",
        ])
        XCTAssertEqual(stems, ["x"])
    }

    func test_finished_recordings_alongside_one_orphan() {
        let stems = OrphanRecordingRecovery.detectOrphanStems(fileNames: [
            "done.wav", "done.mic.wav",
            "lost.mic.wav", "lost.system.wav",
        ])
        XCTAssertEqual(stems, ["lost"])
    }

    func test_multiple_orphans_are_returned_sorted() {
        let stems = OrphanRecordingRecovery.detectOrphanStems(fileNames: [
            "20260522-110000.system.wav",
            "20260522-100000.mic.wav",
        ])
        XCTAssertEqual(stems, ["20260522-100000", "20260522-110000"])
    }

    func test_empty_directory_has_no_orphans() {
        XCTAssertTrue(OrphanRecordingRecovery.detectOrphanStems(fileNames: []).isEmpty)
    }

    func test_finished_recordings_only_have_no_orphans() {
        let stems = OrphanRecordingRecovery.detectOrphanStems(fileNames: [
            "a.wav", "a.md", "b.wav", "b.summary.json",
        ])
        XCTAssertTrue(stems.isEmpty)
    }

    // MARK: - Age bound (scanOrphanStems)

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp-orphan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeIntermediatePair(stem: String, in dir: URL, modified: Date) throws {
        for suffix in [".mic.wav", ".system.wav"] {
            let url = dir.appendingPathComponent("\(stem)\(suffix)")
            try Data("x".utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: modified], ofItemAtPath: url.path)
        }
    }

    func test_scanOrphanStems_skips_orphans_older_than_the_age_bound() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        try writeIntermediatePair(stem: "fresh", in: dir, modified: now.addingTimeInterval(-3600))
        try writeIntermediatePair(stem: "stale", in: dir, modified: now.addingTimeInterval(-72 * 3600))

        let stems = OrphanRecordingRecovery.scanOrphanStems(in: dir, now: now)
        XCTAssertEqual(stems, ["fresh"], "weeks-old test debris must not be recovered")
    }

    func test_scanOrphanStems_recovers_a_recent_orphan_next_to_a_finished_one() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        // A finished recording: the .wav exists, so it is not an orphan
        // even though a stray intermediate lingers.
        try Data("x".utf8).write(to: dir.appendingPathComponent("done.wav"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("done.mic.wav"))
        try writeIntermediatePair(stem: "recent", in: dir, modified: now.addingTimeInterval(-600))

        let stems = OrphanRecordingRecovery.scanOrphanStems(in: dir, now: now)
        XCTAssertEqual(stems, ["recent"])
    }

    // MARK: - REC6: recurring sweep guards

    func test_scanOrphanStems_excludes_the_live_recording_stem_REC6() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        // REC6 runs the sweep after every job completion, so a recording may be in
        // flight. Its intermediates must never be treated as an orphan and merged.
        try writeIntermediatePair(stem: "live", in: dir, modified: now.addingTimeInterval(-30))
        try writeIntermediatePair(stem: "past", in: dir, modified: now.addingTimeInterval(-600))

        let stems = OrphanRecordingRecovery.scanOrphanStems(in: dir, now: now, excludingStems: ["live"])
        XCTAssertEqual(stems, ["past"], "the live recording's in-flight intermediates must be excluded")
    }

    // MARK: - REC23: the recorder's owned stems

    /// The window REC23 closes: during the engine start the stem has a growing `.mic.wav` and a
    /// `.capturemode`, no final and no recovery marker, and the UI mirror does not name it yet.
    /// Owned by the recorder, it is not an orphan.
    func test_scanOrphanStems_excludes_a_starting_stem_the_recorder_owns_REC23() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        let starting = "20261026-100500"
        try Data(repeating: 0, count: 8192).write(to: dir.appendingPathComponent("\(starting).mic.wav"))
        try writeMarker(.captureFirst, stem: starting, in: dir)
        try writeIntermediatePair(stem: "20261026-090000", in: dir, modified: now.addingTimeInterval(-600))

        XCTAssertEqual(
            OrphanRecordingRecovery.scanOrphanStems(in: dir, now: now),
            ["20261026-090000", starting],
            "the precondition: unowned, the starting stem reads exactly like an orphan"
        )
        XCTAssertEqual(
            OrphanRecordingRecovery.scanOrphanStems(in: dir, now: now, excludingStems: [starting]),
            ["20261026-090000"]
        )
    }

    /// The wide path: an earlier orphan's merge runs first, the start finishes meanwhile, and
    /// the stale snapshot then names a stem the recorder owns. The per-stem re-check must leave
    /// every file of it alone. A stand-in ffmpeg makes the merge succeed for any stem it reaches,
    /// so without the check the live stem would be merged, its intermediates deleted, and its
    /// markers cleared.
    @MainActor
    func test_recover_skips_a_stem_that_became_owned_while_an_earlier_one_merged_REC23() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let logs = dir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let merged = dir.appendingPathComponent("merged-source.bin")
        try makeWavData(seconds: 1.0).write(to: merged)
        setenv("MEETINGPIPE_FFMPEG", try fakeFFmpeg(in: dir, writing: merged).path, 1)
        setenv("MEETINGPIPE_LOGS_DIR", logs.path, 1)
        defer {
            unsetenv("MEETINGPIPE_FFMPEG")
            unsetenv("MEETINGPIPE_LOGS_DIR")
        }

        let earlier = "20261026-090000"
        let live = "20261026-100500"
        for stem in [earlier, live] {
            try makeWavData(seconds: 1.0).write(to: dir.appendingPathComponent("\(stem).mic.wav"))
            try makeWavData(seconds: 1.0).write(to: dir.appendingPathComponent("\(stem).system.wav"))
        }
        try writeMarker(.captureFirst, stem: live, in: dir)
        RecordingManifest.write(summaryMode: .auto, meta: [:], forStem: live, in: dir)
        let liveFiles = ["mic.wav", "system.wav", "capturemode", "recovery.json"].map {
            dir.appendingPathComponent("\(live).\($0)")
        }
        let before = try liveFiles.map { try Data(contentsOf: $0) }

        var asked: [String] = []
        let result = await OrphanRecordingRecovery.recover(stems: [earlier, live], in: dir, isOwned: { stem in
            asked.append(stem)
            return asked.count > 1  // the start finished while the first stem merged
        })

        XCTAssertEqual(asked, [earlier, live], "asked once per stem, immediately before its merge")
        XCTAssertEqual(result.ready.map { $0.url.lastPathComponent }, ["\(earlier).wav"], "the unowned orphan still recovers")
        XCTAssertEqual(try liveFiles.map { try Data(contentsOf: $0) }, before, "every file of the owned stem is untouched")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(live).wav").path),
                       "no stub final is promoted for the live meeting")

        let events = (try? String(contentsOf: logs.appendingPathComponent("events.jsonl"), encoding: .utf8)) ?? ""
        let skips = events.split(separator: "\n").compactMap { line -> [String: Any]? in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["action"] as? String == "orphan_recovery_skipped_owned" else { return nil }
            return object
        }
        XCTAssertEqual(skips.count, 1)
        XCTAssertEqual(skips.first?["category"] as? String, "coordinator")
        XCTAssertEqual(skips.first?["stem"] as? String, live)
    }

    /// REC26: the flags written mid-recording survive recovery. A crash, quit or rebuild relaunch
    /// leaves intermediates, a manifest and the per-press `<stem>.markers.json`; the real merge path
    /// (a stand-in ffmpeg, not a stubbed recoverer, so the merge's own cleanup is under test) and
    /// `cleanupStartMarkers` must leave the markers where the recovered final finds them by stem.
    @MainActor
    func test_recover_keeps_the_markers_written_before_the_interruption_REC26() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let logs = dir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let merged = dir.appendingPathComponent("merged-source.bin")
        try makeWavData(seconds: 1.0).write(to: merged)
        setenv("MEETINGPIPE_FFMPEG", try fakeFFmpeg(in: dir, writing: merged).path, 1)
        setenv("MEETINGPIPE_LOGS_DIR", logs.path, 1)
        defer {
            unsetenv("MEETINGPIPE_FFMPEG")
            unsetenv("MEETINGPIPE_LOGS_DIR")
        }

        let stem = "20261112-090000"
        let final = dir.appendingPathComponent("\(stem).wav")
        try makeWavData(seconds: 1.0).write(to: dir.appendingPathComponent("\(stem).mic.wav"))
        try makeWavData(seconds: 1.0).write(to: dir.appendingPathComponent("\(stem).system.wav"))
        try writeMarker(.captureFirst, stem: stem, in: dir)
        RecordingManifest.write(summaryMode: .auto, meta: [:], forStem: stem, in: dir)
        MarkerFile.write(seconds: [12.5, 340.0], forFinal: final)

        let result = await OrphanRecordingRecovery.recover(stems: [stem], in: dir, isOwned: { _ in false })

        XCTAssertEqual(result.ready.map(\.url), [final], "the orphan recovers to its final")
        XCTAssertNil(RecordingManifest.read(forStem: stem, in: dir), "the start-time manifest is cleared")
        let markers = try XCTUnwrap(MarkerFile.read(forFinal: final), "the flags survive the recovery")
        XCTAssertEqual(markers.markers.map(\.tSeconds), [12.5, 340.0])
    }

    /// A PCM WAV of `seconds` of silence: decodable, past the 4,096-byte has-audio floor.
    private func makeWavData(seconds: Double, sampleRate: UInt32 = 16000) -> Data {
        let payloadBytes = Int(Double(sampleRate) * seconds) * 2
        var data = Data()
        func le<T: FixedWidthInteger>(_ value: T) { data.append(contentsOf: withUnsafeBytes(of: value.littleEndian, Array.init)) }
        data.append(contentsOf: "RIFF".utf8); le(UInt32(36 + payloadBytes))
        data.append(contentsOf: "WAVEfmt ".utf8); le(UInt32(16)); le(UInt16(1)); le(UInt16(1))
        le(sampleRate); le(sampleRate * 2); le(UInt16(2)); le(UInt16(16))
        data.append(contentsOf: "data".utf8); le(UInt32(payloadBytes))
        data.append(Data(count: payloadBytes))
        return data
    }

    /// A stand-in ffmpeg that ignores its arguments, drops `source` at the output path, and
    /// exits 0, so a merge succeeds without a real ffmpeg (and so without a skip).
    private func fakeFFmpeg(in dir: URL, writing source: URL) throws -> URL {
        let script = dir.appendingPathComponent("fake-ffmpeg")
        let body = """
        #!/bin/sh
        for last; do :; done
        /bin/cp "\(source.path)" "$last"
        exit 0
        """
        try Data(body.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    func test_scanOrphanStems_recovery_marker_exempts_a_stale_orphan_REC6() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        // A genuinely interrupted recording can sit for days on a launchd daemon; its
        // start-time .recovery.json marker exempts it from the staleness cutoff (REC6).
        try writeIntermediatePair(stem: "old_marked", in: dir, modified: now.addingTimeInterval(-72 * 3600))
        try Data("{}".utf8).write(to: dir.appendingPathComponent("old_marked.recovery.json"))
        // A stale orphan with no marker is still skipped as test debris.
        try writeIntermediatePair(stem: "old_bare", in: dir, modified: now.addingTimeInterval(-72 * 3600))

        let stems = OrphanRecordingRecovery.scanOrphanStems(in: dir, now: now)
        XCTAssertEqual(stems, ["old_marked"], "a recovery-marked orphan survives the cutoff; a bare stale one does not")
    }

    func test_scanOrphanStems_recordfail_marker_exempts_a_stale_orphan_REC6() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        try writeIntermediatePair(stem: "failed_merge", in: dir, modified: now.addingTimeInterval(-72 * 3600))
        try Data("{}".utf8).write(to: dir.appendingPathComponent("failed_merge.recordfail.json"))

        let stems = OrphanRecordingRecovery.scanOrphanStems(in: dir, now: now)
        XCTAssertEqual(stems, ["failed_merge"], "a stop-time merge-failure breadcrumb exempts the orphan from the cutoff")
    }

    // MARK: - Capture-first orphan quarantine (TECH-MIC5 review)

    private func writeMarker(_ mode: CaptureMode, stem: String, in dir: URL) throws {
        try mode.marker.write(
            to: dir.appendingPathComponent("\(stem).capturemode"),
            atomically: true, encoding: .utf8
        )
    }

    func test_shouldQuarantine_true_for_redact_optin_orphan_without_timeline() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeMarker(.captureFirstRedact, stem: "rec", in: dir)
        XCTAssertTrue(
            OrphanRecordingRecovery.shouldQuarantine(stem: "rec", final: dir.appendingPathComponent("rec.wav"), in: dir),
            "a redaction-opt-in orphan with no timeline cannot be redacted and must not auto-publish un-redacted"
        )
    }

    func test_shouldQuarantine_false_for_default_capture_first_orphan() throws {
        // TECH-MIC9: the default keeps the full mic with no redaction, so a
        // default capture-first orphan is safe to auto-process even with no
        // timeline (there was never anything to redact).
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeMarker(.captureFirst, stem: "rec", in: dir)
        XCTAssertFalse(
            OrphanRecordingRecovery.shouldQuarantine(stem: "rec", final: dir.appendingPathComponent("rec.wav"), in: dir),
            "default capture-first keeps the full mic; no redaction was intended, so it is safe to process"
        )
    }

    func test_shouldQuarantine_true_for_capture_first_orphan_with_a_manual_span() throws {
        // MIC14: a default capture-first recording that had an off-record span, but crashed before
        // stop() wrote the manual-only timeline, must be quarantined - auto-publishing it would
        // leak the off-record audio. The `.offrecord` marker (written at the first toggle) is the
        // signal that survives the crash.
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let final = dir.appendingPathComponent("rec.wav")
        try writeMarker(.captureFirst, stem: "rec", in: dir)
        OffRecordMarker.write(forFinal: final)
        XCTAssertTrue(
            OrphanRecordingRecovery.shouldQuarantine(stem: "rec", final: final, in: dir),
            "a lost manual off-record span must not auto-publish"
        )
    }

    func test_shouldQuarantine_false_when_a_timeline_exists() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let final = dir.appendingPathComponent("rec.wav")
        try writeMarker(.captureFirstRedact, stem: "rec", in: dir)
        MuteTimelineFile.write(spans: [MuteTimeline.Span(startSec: 0, endSec: 1)], forFinal: final)
        XCTAssertFalse(
            OrphanRecordingRecovery.shouldQuarantine(stem: "rec", final: final, in: dir),
            "a recording that reached stop() has a timeline and is redactable"
        )
    }

    func test_shouldQuarantine_false_for_regulated_orphan() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeMarker(.regulatedGate, stem: "rec", in: dir)
        XCTAssertFalse(
            OrphanRecordingRecovery.shouldQuarantine(stem: "rec", final: dir.appendingPathComponent("rec.wav"), in: dir),
            "regulated orphans were gated at capture; safe to process"
        )
    }

    func test_shouldQuarantine_false_for_legacy_orphan_without_marker() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(
            OrphanRecordingRecovery.shouldQuarantine(stem: "rec", final: dir.appendingPathComponent("rec.wav"), in: dir),
            "a pre-MIC4 orphan has no marker and was gated at capture"
        )
    }

    // MARK: - Meta sidecar restore from the manifest (REC2 / AUD-6)

    func test_restoreMetaSidecar_writes_meta_json_when_absent() throws {
        // The NDA / regulated flags in the rebuilt sidecar are what arm the
        // pipeline egress guard for a recovered orphan, so the write must happen.
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let meta: [String: Any] = ["workflow_nda_mode": true, "meeting_title": "Board sync"]

        OrphanRecordingRecovery.restoreMetaSidecar(meta, forStem: "rec", in: dir)

        let sidecar = dir.appendingPathComponent("rec.meta.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))
        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: sidecar)) as? [String: Any]
        XCTAssertEqual(written?["workflow_nda_mode"] as? Bool, true)
        XCTAssertEqual(written?["meeting_title"] as? String, "Board sync")
    }

    func test_restoreMetaSidecar_does_not_clobber_an_existing_sidecar() throws {
        // A stop() that wrote the sidecar before its merge failed, or a prior
        // recovery, must win over a re-derived one.
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sidecar = dir.appendingPathComponent("rec.meta.json")
        try Data(#"{"meeting_title":"original"}"#.utf8).write(to: sidecar)

        OrphanRecordingRecovery.restoreMetaSidecar(["meeting_title": "from manifest"], forStem: "rec", in: dir)

        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: sidecar)) as? [String: Any]
        XCTAssertEqual(written?["meeting_title"] as? String, "original", "an existing sidecar must not be overwritten")
    }

    func test_restoreMetaSidecar_skips_empty_meta() throws {
        // A manual, workflow-less, non-regulated recording has no sidecar; the
        // pipeline's global-config fallback is correct, so write nothing.
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        OrphanRecordingRecovery.restoreMetaSidecar([:], forStem: "rec", in: dir)

        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("rec.meta.json").path))
    }
}
