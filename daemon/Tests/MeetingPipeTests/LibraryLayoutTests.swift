import AppKit
import SwiftUI
import XCTest
@testable import MeetingPipe

/// Layout-floor invariants for the three-pane Library window (TECH-UX11).
/// Pure-value checks rather than an image snapshot: the old snapshot tests
/// rasterised views and pixel-compared them, which is not reproducible across
/// macOS / Xcode versions and broke CI (see `RenderedViewSmokeTests`). These
/// guard the same constants the `NavigationSplitView` columns and the
/// `NSWindow` minimum consume, so a future floor bump that re-opens the clip
/// fails the build instead.
/// T7 source fence (pins implementation): test_the_library_window_does_not_size_itself_from_its_content asserts LibraryWindow sets `host.sizingOptions = []` before NSWindow(contentViewController:). Missing seam: a LibraryWindow factory exposing its hosting controller headless.
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

    // MARK: - UX70: the window does not follow its content's height

    /// Source of a file in the daemon target, for the fence below.
    private func daemonSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MeetingPipeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // daemon
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// A tall stack, standing in for a session of Ask answers.
    private func column(entries: Int) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(0 ..< entries, id: \.self) { _ in
                    Color.clear.frame(width: 300, height: 200)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The size the hosted content pushes back up at AppKit, after a real layout
    /// pass in a real (offscreen) window.
    ///
    /// `intrinsicContentSize` and not `preferredContentSize`, which reads
    /// `(0, 0)` for every input in this harness and would make both tests below
    /// vacuously true. The intrinsic size is the one that moves here, and it is
    /// the same number: it is what the hosting view reports as the height it
    /// wants, and it is exactly what `NSHostingSizingOptions` governs.
    @MainActor
    private func hostedIntrinsicSize<V: View>(_ view: V, sizingOptions: NSHostingSizingOptions?) -> NSSize {
        let host = NSHostingController(rootView: view)
        if let sizingOptions { host.sizingOptions = sizingOptions }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.contentViewController = host
        window.layoutIfNeeded()
        host.view.layoutSubtreeIfNeeded()
        return host.view.intrinsicContentSize
    }

    /// The mechanism, demonstrated rather than asserted about, and the reason the
    /// obvious fix is wrong: a `ScrollView` was already over the Ask session, and
    /// a scroller only takes over once the height it is *offered* is smaller than
    /// its content. A hosted SwiftUI view reports its content's ideal height
    /// upward by default, `NSWindow(contentViewController:)` follows it, and a
    /// window that keeps enlarging itself never offers a smaller height. Measured
    /// here at 200pt for one entry against 8000pt for forty.
    @MainActor
    func test_hosted_content_pushes_its_full_height_at_the_window_by_default() {
        let one = hostedIntrinsicSize(column(entries: 1), sizingOptions: nil)
        let many = hostedIntrinsicSize(column(entries: 40), sizingOptions: nil)

        XCTAssertGreaterThan(
            many.height, one.height,
            "if this stops being true the defect is gone for a different reason; re-derive UX70 before deleting the fix")
    }

    /// The fix, at the level the sizing actually escapes. With the options
    /// emptied, entry count cannot reach the window at all: forty answers report
    /// exactly what one does, which is `noIntrinsicMetric` in both axes, so the
    /// height the scroller is offered stops depending on what is inside it.
    @MainActor
    func test_emptying_sizing_options_makes_the_height_independent_of_entry_count() {
        let one = hostedIntrinsicSize(column(entries: 1), sizingOptions: [])
        let many = hostedIntrinsicSize(column(entries: 40), sizingOptions: [])

        XCTAssertEqual(many, one,
                       "forty answers must report exactly what one does, or the window still grows")
        XCTAssertEqual(many.height, NSView.noIntrinsicMetric,
                       "the content stops claiming a height at all; the window's own frame is what sizes it")
    }

    /// And that the Library window is the one that does it. The two above prove
    /// the mechanism and the remedy; this is what keeps the remedy applied.
    func test_the_library_window_does_not_size_itself_from_its_content() throws {
        let source = try daemonSource("Sources/MeetingPipe/LibraryWindow.swift")
        XCTAssertTrue(source.contains("host.sizingOptions = []"),
                      "the Library window must not adopt its content's preferred size (UX70)")
        guard let assignment = source.range(of: "host.sizingOptions = []"),
              let construction = source.range(of: "NSWindow(contentViewController: host)") else {
            return XCTFail("the Library window no longer has this shape; re-point this fence")
        }
        XCTAssertTrue(assignment.upperBound < construction.lowerBound,
                      "the options have to be emptied before the window takes the controller, or the first sizing pass still lands")
    }
}
