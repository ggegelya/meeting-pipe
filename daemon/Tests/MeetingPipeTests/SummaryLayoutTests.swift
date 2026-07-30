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

    // MARK: - Detail-pane chrome (UX36, second pass)

    /// Source of a file in the daemon target. SwiftUI layout is not observable at
    /// runtime, so the two fences below pin their claims where they are actually
    /// decided, the way `WorkflowDeletionTests` pins a button style.
    private func daemonSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MeetingPipeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // daemon
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// The regression this fence exists for: the tab underline was a bare
    /// `Rectangle` sibling inside the button's `VStack`. A `Rectangle` is a greedy
    /// shape, so with no width constraint it consumed every point offered, made
    /// each tab button greedy, and let three buttons divide the whole pane while
    /// the trailing `Spacer` got nothing. The strip read as left-aligned in source
    /// and shipped as three tabs spread across 1230pt. Re-introducing the sibling
    /// form is the only way to get that back, so that is what is pinned.
    func test_the_tab_underline_sizes_to_its_label_and_not_to_the_pane() throws {
        let view = try daemonSource("Sources/MeetingPipe/MeetingDetailView.swift")
        XCTAssertTrue(view.contains(".overlay(alignment: .bottom)"),
                      "the active-tab underline must be an overlay on the label, which sizes to the text")
        guard let start = view.range(of: "private func tabButton"),
              let end = view.range(of: "@ViewBuilder", range: start.upperBound ..< view.endIndex) else {
            return XCTFail("tabButton no longer exists under that name; re-point this fence")
        }
        let body = String(view[start.lowerBound ..< end.lowerBound])
        guard let overlay = body.range(of: ".overlay("),
              let rect = body.range(of: "Rectangle()") else {
            return XCTFail("tabButton no longer draws an underline the way this fence assumes")
        }
        XCTAssertLessThan(overlay.lowerBound, rect.lowerBound,
                          "the Rectangle must sit inside the overlay; as a VStack sibling it is greedy and spreads the tabs")
    }

    /// The header and tab strip are chrome, banded on the *sunk* surface, and
    /// deliberately NOT on the summary's reading column: `TranscriptTab` and
    /// `AudioTab` are full-width, so a header indented to the summary measure is
    /// misaligned against them the moment the tab changes. Sunk, not raised: the
    /// band shipped on `bgRaised` first, an 11-of-255 step off the dark canvas
    /// that vanished in the owner's screenshot, and an invisible band reads as a
    /// stray offset rather than as chrome. Recessing is also the direction the
    /// mac's own toolbars take, and it leaves `bgRaised` meaning content.
    func test_the_header_and_tabs_are_a_chrome_band_not_a_reading_column() throws {
        let view = try daemonSource("Sources/MeetingPipe/MeetingDetailView.swift")
        XCTAssertTrue(view.contains("private var chromeBand: some View"),
                      "header and tab strip are banded together, so the divider under them reads as the band's edge")
        XCTAssertTrue(view.contains(".background(Color(MPColors.bgSunk))"),
                      "the band recesses; raised was invisible against the dark canvas and read as a stray offset")
        XCTAssertFalse(view.contains(".background(Color(MPColors.bgRaised))"),
                       "bgRaised on the band is the shipped-and-rejected form; raised means content, not chrome")
        XCTAssertFalse(view.contains("SummaryLayout.readingMeasure"),
                       "the chrome must not adopt the summary's measure; that misaligns the other two tabs")
    }

    /// The reading column is left-aligned, not centered, and the two are only
    /// interchangeable because `LibraryLayout.detailMaxWidth` exists: capped, the
    /// column's slack goes to the meeting list and every tab's content shares one
    /// left edge; centered, the summary started 200+ pt right of the header and
    /// transcript and the axis jumped on every tab change (the owner rejected
    /// that on sight). Alignment is not observable at runtime, so the source is
    /// pinned: no cap site in the three summary surfaces may center its block.
    /// Anchored on the next placement frame after each cap rather than on a
    /// character window. The window form was written first and was **vacuous**: a
    /// long explanatory comment sits between the cap and its placement in
    /// `SummaryRenderedView`, so 320 characters never reached the alignment and
    /// the assertion ran zero times. Caught by mutating a site back to `.top` and
    /// watching the test still pass, which is why `checked` is asserted below.
    func test_the_measured_column_left_aligns_under_the_capped_detail_column() throws {
        for file in ["SummaryRenderedView.swift", "SummaryTab.swift", "CorrectionEditor.swift"] {
            let source = try daemonSource("Sources/MeetingPipe/\(file)")
            var rest = Substring(source)
            var checked = 0
            while let cap = rest.range(of: ".frame(maxWidth: SummaryLayout.readingMeasure") {
                let after = rest[cap.upperBound...]
                guard let placement = after.range(of: ".frame(maxWidth: .infinity, alignment: ") else {
                    rest = after
                    continue
                }
                let token = after[placement.upperBound...].prefix(16)
                XCTAssertTrue(
                    token.hasPrefix(".topLeading"),
                    "\(file): a measured block is placed with \(token.prefix(12)); `.top` centers "
                    + "horizontally, which puts the summary 200+ pt right of the header and transcript"
                )
                checked += 1
                rest = after[placement.upperBound...]
            }
            XCTAssertGreaterThan(checked, 0, "\(file): fence found no measured block to check; re-point it")
        }
    }

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
