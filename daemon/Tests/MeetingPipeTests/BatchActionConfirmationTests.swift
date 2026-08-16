import XCTest
@testable import MeetingPipe

/// UX61. The merge ran straight off its button click, so what these assert is
/// the copy rather than the plumbing: a confirmation that appears but does not
/// name what is lost is the same defect one step later.
final class BatchActionConfirmationTests: XCTestCase {

    // MARK: - Merge

    private func mergeCopy(fragments: Int = 1, cloud: Bool = true) -> BatchActionConfirmation {
        BatchActionConfirmation.merge(
            primaryTitle: "Standup 2026-08-16",
            fragmentCount: fragments,
            reachesCloud: cloud
        )
    }

    func testMergeTitleCountsEveryMeetingNotJustTheFragments() {
        XCTAssertEqual(mergeCopy(fragments: 1).title, "Merge 2 meetings into one?")
        XCTAssertEqual(mergeCopy(fragments: 3).title, "Merge 4 meetings into one?")
    }

    /// The four things the spec required it to name, each asserted separately so
    /// a rewrite that drops one fails on that one.
    func testMergeMessageNamesThePrimaryByTitle() {
        XCTAssertTrue(mergeCopy().message.contains("Standup 2026-08-16"), mergeCopy().message)
    }

    func testMergeMessageSaysThePrimaryIsReplacedInPlaceAndNotRecoverable() {
        let m = mergeCopy().message
        XCTAssertTrue(m.contains("rewritten in place"), m)
        XCTAssertTrue(m.contains("recording, its transcript and its summary are all replaced"), m)
        // The half a reader would otherwise assume from the Trash sentence below it.
        XCTAssertTrue(m.contains("not moved to the Trash"), m)
    }

    func testMergeMessageNamesTheEditsAndTicksAsTheThingActuallyLost() {
        let m = mergeCopy().message
        XCTAssertTrue(m.contains("edits you made"), m)
        XCTAssertTrue(m.contains("ticked done"), m)
    }

    func testMergeMessageSaysWhereTheFragmentsGoAndReusesTheOneTrashSentence() {
        let single = mergeCopy(fragments: 1).message
        XCTAssertTrue(single.contains("The other meeting is moved to the Trash"), single)
        let many = mergeCopy(fragments: 3).message
        XCTAssertTrue(many.contains("The other 3 meetings are moved to the Trash"), many)
        // One home for the reassurance, not a fourth spelling of it.
        XCTAssertTrue(many.contains(LibraryDialogs.trashRecoveryNote), many)
    }

    func testMergeNamesTheCostOnlyWhenTheRunActuallyReachesTheCloud() {
        let cloud = mergeCopy(cloud: true).message
        XCTAssertTrue(cloud.contains("paid engine call"), cloud)
        XCTAssertTrue(cloud.contains("rewrite of the page"), cloud)

        // A zero-egress merge summarizes locally and publishes to filesystem
        // sinks. Claiming a paid call there would be the same class of untruth
        // this band exists to remove.
        let local = mergeCopy(cloud: false).message
        XCTAssertFalse(local.contains("paid"), local)
        XCTAssertTrue(local.contains("on this Mac"), local)
        // Still says it republishes, since that is true on both paths.
        XCTAssertTrue(local.contains("published again"), local)
    }

    func testMergeConfirmButtonIsTheVerb() {
        XCTAssertEqual(mergeCopy().confirmButton, "Merge")
    }

    // MARK: - Re-summarize

    func testResummarizeNamesTheLostEditsAndSparesTheRecordings() {
        let m = BatchActionConfirmation.resummarize(count: 5, cloudCount: 5).message
        XCTAssertTrue(m.contains("edits you made"), m)
        XCTAssertTrue(m.contains("ticked done"), m)
        // The reassurance that keeps this from reading as a delete.
        XCTAssertTrue(m.contains("recordings and transcripts are not touched"), m)
    }

    func testResummarizeCostClauseFollowsTheSelectionsRealPosture() {
        let allCloud = BatchActionConfirmation.resummarize(count: 4, cloudCount: 4).message
        XCTAssertTrue(allCloud.contains("Each one is a paid engine call"), allCloud)

        let allLocal = BatchActionConfirmation.resummarize(count: 4, cloudCount: 0).message
        XCTAssertFalse(allLocal.contains("paid"), allLocal)
        XCTAssertTrue(allLocal.contains("nothing to pay"), allLocal)

        // A batch selection may mix postures where a merge may not, so the
        // partial case is a real one and not defensive.
        let mixed = BatchActionConfirmation.resummarize(count: 4, cloudCount: 1).message
        XCTAssertTrue(mixed.contains("1 of them are a paid engine call"), mixed)
        XCTAssertTrue(mixed.contains("the rest summarize on this Mac"), mixed)
    }

    func testResummarizeTitleCarriesTheCount() {
        XCTAssertEqual(
            BatchActionConfirmation.resummarize(count: 7, cloudCount: 0).title,
            "Re-summarize 7 meetings?"
        )
    }

    // MARK: - House rules

    func testNoEmDashesInAnyConfirmationCopy() {
        let all = [
            mergeCopy(fragments: 1, cloud: true),
            mergeCopy(fragments: 3, cloud: false),
            BatchActionConfirmation.resummarize(count: 4, cloudCount: 4),
            BatchActionConfirmation.resummarize(count: 4, cloudCount: 0),
            BatchActionConfirmation.resummarize(count: 4, cloudCount: 2),
        ]
        for c in all {
            for s in [c.title, c.message, c.confirmButton] {
                XCTAssertFalse(s.contains("\u{2014}"), "em-dash in: \(s)")
            }
        }
    }

    /// `MeetingMergeEligibility` requires two or more, so the copy never has to
    /// describe a one-meeting merge, and a zero-fragment string would be the tell
    /// that a caller reached it anyway.
    func testMergeCopyAssumesAtLeastOneFragment() {
        XCTAssertFalse(mergeCopy(fragments: 1).message.contains("other 1 meetings"))
    }
}
