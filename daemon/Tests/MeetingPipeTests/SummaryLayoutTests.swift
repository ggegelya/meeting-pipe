import XCTest
@testable import MeetingPipe

/// UX36: the summary reading measure and the action row's metadata band.
///
/// Pure-value checks in the `LibraryLayoutTests` mould rather than an image
/// snapshot, which T2 removed for being unreproducible across macOS / Xcode.
/// What is pinnable headlessly is the measure arithmetic and the band's
/// *contents*; whether the wrapped band clears the narrowest column by eye is
/// the owner check the spec reserves, since rasterising is what T2 took away.
final class SummaryLayoutTests: XCTestCase {

    // MARK: The measure

    /// `design/README.md` ("Layout rules") puts the reading column at 640-720.
    /// The app used to sit at 600 without saying so: the gutter was applied
    /// inside the 640 cap, so the real column was 640 - 2 * 20. UX36 moved the
    /// gutter outside, which is what makes the constant honest, so a later nudge
    /// (the owner-gated 640 -> 680) has to stay inside the band it claims.
    func test_readingMeasure_stays_inside_the_design_systems_reading_column_band() {
        XCTAssertGreaterThanOrEqual(SummaryLayout.readingMeasure, 640)
        XCTAssertLessThanOrEqual(SummaryLayout.readingMeasure, 720)
    }

    /// The two measures are not interchangeable: the notice measure caps centered
    /// text in a full-pane state, and centered prose reads worse long, so it must
    /// stay the tighter of the two rather than drift up to meet the reader.
    func test_noticeMeasure_is_the_narrower_measure() {
        XCTAssertLessThan(SummaryLayout.noticeMeasure, SummaryLayout.readingMeasure)
    }

    /// The gutter now sits outside the cap, so it is subtracted from the *pane*
    /// rather than from the measure. That makes it the thing that squeezes the
    /// column once the detail pane is at its floor, and a generous-looking bump
    /// here would take the text column with it.
    func test_the_gutter_leaves_a_usable_column_at_the_detail_floor() {
        let column = LibraryLayout.detailMinWidth - 2 * SummaryLayout.contentPadding
        XCTAssertGreaterThanOrEqual(
            column, 400,
            "At the detail column floor (\(LibraryLayout.detailMinWidth)) the gutter "
            + "leaves only \(column)pt of text; the action metadata band is sized "
            + "against this width."
        )
    }

    // MARK: The metadata band

    private func row(
        owner: String = "",
        due: String = "",
        confidence: String = "medium",
        evidence: [MeetingSummary.Evidence] = [],
        onCite: ((Double) -> Void)? = { _ in }
    ) -> ActionItemRow {
        ActionItemRow(
            action: .init(
                index: 0, task: "Send the deck",
                owner: owner, due: due, confidence: confidence,
                evidence: evidence
            ),
            onCite: onCite
        )
    }

    private func anchors(_ count: Int) -> [MeetingSummary.Evidence] {
        (0..<count).map { MeetingSummary.Evidence(quote: "line \($0)", t: Double($0) * 61.5) }
    }

    /// Reading order is owner, then due, then confidence. The wrap splits the
    /// band between these chips and the anchors, so their order is what a reader
    /// scans down the left of the second column.
    func test_chips_are_owner_then_due_then_confidence() {
        let chips = row(owner: "Sam", due: "2027-01-20", confidence: "high").chipRow
        XCTAssertEqual(chips.map(\.text), ["Sam", "2027-01-20", "high"])
        XCTAssertEqual(chips.map(\.systemImage), ["person", "calendar", "gauge"])
    }

    /// Medium is the default the model emits, so rendering it would put a chip on
    /// nearly every row and say nothing. Pinned because the band's fit depends on
    /// how many chips there really are.
    func test_a_medium_confidence_chip_is_suppressed() {
        XCTAssertEqual(row(confidence: "medium").chipRow.map(\.text), [])
        XCTAssertEqual(row(confidence: "low").chipRow.map(\.text), ["low"])
    }

    /// `EvidenceChips` draws nothing without a jump handler, so a surface that
    /// cannot take the reader to the transcript (the digest reader, the A16
    /// compare pane) must not reserve band space for anchors it will not show.
    /// Before UX36 the band's own guard read `action.evidence` directly, so such a
    /// row with anchors and no other metadata opened an empty indented band.
    func test_a_reader_with_no_jump_handler_shows_no_anchors_and_no_band() {
        let static_ = row(evidence: anchors(3), onCite: nil)
        XCTAssertEqual(static_.shownEvidence.count, 0)
        XCTAssertFalse(static_.hasMetadataBand, "an empty band must not take a line")
        XCTAssertNotNil(static_.body)

        let live = row(evidence: anchors(3))
        XCTAssertEqual(live.shownEvidence.count, 3)
        XCTAssertTrue(live.hasMetadataBand)
    }

    /// A row can carry chips, anchors, both, or neither, and the guard has to
    /// agree with what the two wrap variants would actually draw.
    func test_the_band_appears_exactly_when_there_is_something_to_show() {
        XCTAssertFalse(row().hasMetadataBand)
        XCTAssertTrue(row(owner: "Sam").hasMetadataBand)
        XCTAssertTrue(row(evidence: anchors(1)).hasMetadataBand)
        XCTAssertTrue(row(owner: "Sam", evidence: anchors(1)).hasMetadataBand)
    }

    /// The case the wrap exists for: the long owner name plus several anchors
    /// that used to compress every chip's text into an ellipsis at the narrow end
    /// of the detail column. Both `ViewThatFits` variants are built from the same
    /// two values, so the fallback cannot silently drop what the flat line showed.
    func test_a_crowded_row_keeps_every_chip_and_every_anchor() {
        let crowded = row(
            owner: "Aleksandra Wonderland-Smythe",
            due: "2027-01-20",
            confidence: "high",
            evidence: anchors(5)
        )
        XCTAssertEqual(crowded.chipRow.count, 3)
        XCTAssertEqual(crowded.shownEvidence.count, 5, "the wrap keeps anchors, it does not trim them")
        XCTAssertTrue(crowded.hasMetadataBand)
        XCTAssertNotNil(crowded.body)
    }
}
