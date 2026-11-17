import XCTest
@testable import MeetingPipe

/// STOR18: the batch pane's Move to Trash over a selection that includes the meeting being
/// recorded. The service refuses that one; the pane reports it as skipped, by name, not failed.
final class SoftDeleteTallySTOR18Tests: XCTestCase {

    func test_three_stems_one_blocked_end_two_ok_and_one_skipped() {
        let results: [(String, Result<Void, Error>)] = [
            ("Standup", .success(())),
            ("Live call", .failure(MeetingLibraryService.LibraryError.meetingInUse(stem: "s2", reason: .recording))),
            ("Retro", .success(())),
        ]
        var tally = SoftDeleteTally()
        for (title, result) in results { tally.record(result, title: title) }

        XCTAssertEqual(tally, SoftDeleteTally(succeeded: 2, failed: 0, skipped: ["Live call"]))
        XCTAssertEqual(SoftDeleteTally.skippedLine(tally.skipped), "Skipped, being recorded or processed: Live call")
    }

    func test_any_other_failure_is_still_a_failure() {
        var tally = SoftDeleteTally()
        tally.record(.failure(MeetingLibraryService.LibraryError.noFiles(stem: "x")), title: "Gone")
        tally.record(.failure(CocoaError(.fileWriteNoPermission)), title: "Locked")
        XCTAssertEqual(tally, SoftDeleteTally(succeeded: 0, failed: 2, skipped: []))
    }

    func test_the_surfaces_block_the_live_stem_and_a_busy_one() {
        XCTAssertEqual(SoftDeleteTally.presentationBlock(isLiveRecording: true, processing: .idle), .recording)
        XCTAssertNil(SoftDeleteTally.presentationBlock(isLiveRecording: false, processing: .idle))
        XCTAssertFalse(SoftDeleteTally.disabledHelp(.recording).isEmpty)
        XCTAssertNotEqual(SoftDeleteTally.disabledHelp(.recording), SoftDeleteTally.disabledHelp(.processing))
    }

    func test_the_confirm_says_how_many_will_be_skipped() {
        XCTAssertEqual(SoftDeleteTally.skipNote(count: 0), "")
        XCTAssertTrue(SoftDeleteTally.skipNote(count: 1).contains("One meeting"))
        XCTAssertTrue(SoftDeleteTally.skipNote(count: 3).contains("3 meetings"))
    }

    func test_the_refusal_explains_itself() {
        let error = MeetingLibraryService.LibraryError.meetingInUse(stem: "20261117-162938", reason: .recording)
        XCTAssertEqual(
            error.errorDescription,
            "20261117-162938 is being recorded. It can be moved to the Trash once that finishes."
        )
    }
}
