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
}
