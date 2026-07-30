import XCTest
@testable import MeetingPipe

/// Layout-floor invariants for the three-pane Library window (TECH-UX11).
/// Pure-value checks rather than an image snapshot: the old snapshot tests
/// rasterised views and pixel-compared them, which is not reproducible across
/// macOS / Xcode versions and broke CI (see `RenderedViewSmokeTests`). These
/// guard the same constants the `NavigationSplitView` columns and the
/// `NSWindow` minimum consume, so a future floor bump that re-opens the clip
/// fails the build instead.
final class LibraryLayoutTests: XCTestCase {

    /// The detail column is the flexible trailing one: once the window is
    /// narrower than the sum of the three floors, detail is squeezed under its
    /// content and clips. The window minimum must always clear that sum.
    func test_windowMinWidth_clears_the_sum_of_column_floors() {
        let floors = LibraryLayout.sidebarMinWidth
            + LibraryLayout.listMinWidth
            + LibraryLayout.detailMinWidth
        XCTAssertLessThanOrEqual(
            floors, LibraryLayout.windowMinWidth,
            "Window min (\(LibraryLayout.windowMinWidth)) is below the sum of the "
            + "column floors (\(floors)); the detail column will clip (TECH-UX11)."
        )
    }

    func test_ideal_widths_are_not_below_their_minimums() {
        XCTAssertGreaterThanOrEqual(LibraryLayout.sidebarIdealWidth, LibraryLayout.sidebarMinWidth)
        XCTAssertGreaterThanOrEqual(LibraryLayout.listIdealWidth, LibraryLayout.listMinWidth)
        XCTAssertGreaterThanOrEqual(LibraryLayout.detailIdealWidth, LibraryLayout.detailMinWidth)
    }

    func test_sidebar_ideal_stays_within_its_max() {
        XCTAssertLessThanOrEqual(LibraryLayout.sidebarIdealWidth, LibraryLayout.sidebarMaxWidth)
    }

    // MARK: - Detail ceiling (UX36)

    func test_detail_ideal_stays_within_its_max() {
        XCTAssertLessThanOrEqual(LibraryLayout.detailIdealWidth, LibraryLayout.detailMaxWidth)
    }

    /// The cap exists so the reading surfaces can left-align without a void
    /// beside them, which only works if the capped column still *fits* those
    /// surfaces. Both measured blocks must clear the ceiling with their gutters,
    /// or the cap re-introduces the squeeze the floor exists to prevent.
    func test_detail_ceiling_clears_every_measured_block_inside_it() {
        XCTAssertGreaterThanOrEqual(
            LibraryLayout.detailMaxWidth,
            SummaryLayout.readingMeasure + 2 * SummaryLayout.contentPadding,
            "the summary column plus gutters no longer fits the capped detail column"
        )
        XCTAssertGreaterThanOrEqual(
            LibraryLayout.detailMaxWidth,
            WorkflowInspectorLayout.cardMaxWidth + 2 * WorkflowInspectorLayout.padding,
            "the inspector card plus padding no longer fits the capped detail column"
        )
    }
}
