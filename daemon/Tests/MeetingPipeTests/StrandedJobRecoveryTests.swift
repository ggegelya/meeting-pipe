import XCTest
@testable import MeetingPipe

/// `StrandedJobRecovery.detect` finds finished recordings whose pipeline never
/// reached a terminal outcome (PIPE3): the startup sweep marks each `.interrupted`
/// so it stops masquerading as `.processing`. It must stay disjoint from
/// `OrphanRecordingRecovery` (which owns the no-final-WAV case).
final class StrandedJobRecoveryTests: XCTestCase {

    func test_detects_final_wav_without_terminal_sidecar() {
        XCTAssertEqual(
            StrandedJobRecovery.detect(fileNames: ["20260511-143110.wav"]),
            ["20260511-143110"]
        )
    }

    func test_detects_final_wav_with_only_transcript_and_meta() {
        // A transcript / meta sidecar is not a terminal outcome: the pipeline
        // died before writing a summary, error, paste, or empty marker.
        XCTAssertEqual(
            StrandedJobRecovery.detect(fileNames: [
                "20260511-143110.wav",
                "20260511-143110.json",
                "20260511-143110.md",
                "20260511-143110.meta.json",
            ]),
            ["20260511-143110"]
        )
    }

    func test_excludes_when_any_terminal_sidecar_present() {
        for terminal in ["summary.json", "error.json", "READY_FOR_MANUAL.md", "empty.json"] {
            let files = ["20260511-143110.wav", "20260511-143110.\(terminal)"]
            XCTAssertTrue(
                StrandedJobRecovery.detect(fileNames: files).isEmpty,
                "a .\(terminal) sidecar means the pipeline reached a terminal outcome"
            )
        }
    }

    func test_excludes_when_no_final_wav() {
        // Unmerged intermediates only: OrphanRecordingRecovery's job, not ours.
        XCTAssertTrue(StrandedJobRecovery.detect(fileNames: [
            "20260511-143110.mic.wav",
            "20260511-143110.system.wav",
        ]).isEmpty)
        // Sidecars with no WAV at all: a RowWithoutWav orphan, not stranded.
        XCTAssertTrue(StrandedJobRecovery.detect(fileNames: [
            "20260511-143110.meta.json",
            "20260511-143110.json",
        ]).isEmpty)
    }

    func test_multiple_stems_mixed() {
        let result = StrandedJobRecovery.detect(fileNames: [
            "20260511-143110.wav",                                    // stranded
            "20260511-150000.wav", "20260511-150000.summary.json",   // done
            "20260511-160000.wav", "20260511-160000.json",           // stranded (transcript only)
        ])
        XCTAssertEqual(result, ["20260511-143110", "20260511-160000"])
    }
}
