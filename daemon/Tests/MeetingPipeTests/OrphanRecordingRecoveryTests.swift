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

    // MARK: - Capture-first orphan quarantine (TECH-MIC5 review)

    private func writeMarker(_ mode: CaptureMode, stem: String, in dir: URL) throws {
        try mode.marker.write(
            to: dir.appendingPathComponent("\(stem).capturemode"),
            atomically: true, encoding: .utf8
        )
    }

    func test_shouldQuarantine_true_for_capture_first_orphan_without_timeline() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeMarker(.captureFirst, stem: "rec", in: dir)
        XCTAssertTrue(
            OrphanRecordingRecovery.shouldQuarantine(stem: "rec", final: dir.appendingPathComponent("rec.wav"), in: dir),
            "a lossless capture-first orphan with no timeline cannot be redacted and must not auto-publish"
        )
    }

    func test_shouldQuarantine_false_when_a_timeline_exists() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let final = dir.appendingPathComponent("rec.wav")
        try writeMarker(.captureFirst, stem: "rec", in: dir)
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
}
