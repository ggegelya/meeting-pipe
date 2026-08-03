import Foundation
import SwiftUI
import XCTest
@testable import MeetingPipe

/// UX51: the shared wrapping layout, promoted out of `PreferencesView+Recording.swift`
/// when the cast strip became its second caller.
///
/// SwiftUI layout is not observable at runtime and `LayoutSubviews` cannot be built
/// outside a live layout pass, which is why the break arithmetic is a static function
/// over measured sizes: that is the half a test can actually reach, and "do these chips
/// wrap or does the last one get sliced" is decided entirely inside it. Sizes here are
/// synthetic on purpose. Pinning real rendered chip widths would pin the system font
/// metrics of whichever macOS ran the suite, which is what T2 removed image snapshots
/// for.
final class FlowLayoutTests: XCTestCase {

    private func sizes(_ widths: [CGFloat], height: CGFloat = 22) -> [CGSize] {
        widths.map { CGSize(width: $0, height: height) }
    }

    // MARK: - Breaking

    func test_a_row_that_fits_is_not_broken() {
        let rows = FlowLayout.rows(for: sizes([100, 100, 100]), width: 720, spacing: 6)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].indices, [0, 1, 2])
        // Three 100pt chips with two 6pt gaps between them, not three gaps: the row's
        // width is glyph edge to glyph edge, so a trailing gap would over-report it and
        // break one item early.
        XCTAssertEqual(rows[0].width, 312)
    }

    func test_a_run_wider_than_the_width_breaks_onto_more_rows() {
        // The shape of the owner's report: eight chips that cannot share one row.
        let rows = FlowLayout.rows(for: sizes(Array(repeating: 110, count: 8)), width: 720, spacing: 6)
        XCTAssertGreaterThan(rows.count, 1, "a run past the width must wrap, not ride off the edge")
        XCTAssertEqual(rows.map(\.indices), [[0, 1, 2, 3, 4, 5], [6, 7]])
        for row in rows {
            XCTAssertLessThanOrEqual(row.width, 720, "no row may exceed the width it was given")
        }
    }

    /// The claim the whole task rests on: wrapping moves a subview, it never drops one.
    /// A layout that lost the tail would reproduce the reported defect exactly, with the
    /// count in the header above the strip no longer reconcilable with what is visible.
    func test_every_subview_lands_in_exactly_one_row() {
        let widths: [CGFloat] = [40, 300, 90, 210, 160, 75, 130, 260, 55]
        let rows = FlowLayout.rows(for: sizes(widths), width: 400, spacing: 6)
        let placed = rows.flatMap(\.indices)
        XCTAssertEqual(placed.sorted(), Array(0 ..< widths.count))
        XCTAssertEqual(placed, placed.sorted(), "order is preserved: reading order is left to right, top to bottom")
    }

    /// A subview wider than the whole width has nowhere better to go, so it takes a row
    /// of its own rather than being dropped. The break is only ever taken against a row
    /// that already holds something, which is what makes this fall out rather than need
    /// a special case.
    func test_a_subview_wider_than_the_width_gets_its_own_row_rather_than_being_dropped() {
        let rows = FlowLayout.rows(for: sizes([50, 900, 50]), width: 400, spacing: 6)
        XCTAssertEqual(rows.map(\.indices), [[0], [1], [2]])
    }

    func test_a_row_is_as_tall_as_its_tallest_subview() {
        let mixed = [CGSize(width: 100, height: 22), CGSize(width: 100, height: 40)]
        let rows = FlowLayout.rows(for: mixed, width: 720, spacing: 6)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].height, 40)
    }

    func test_nothing_in_means_no_rows_out() {
        XCTAssertTrue(FlowLayout.rows(for: [], width: 720, spacing: 6).isEmpty)
    }

    // MARK: - Where it lives (UX51's promotion)

    private var daemonRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MeetingPipeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // daemon
    }

    /// Which files in the daemon target *declare* a `FlowLayout`, by file name.
    private func declaringFiles() throws -> Set<String> {
        let sources = daemonRoot.appendingPathComponent("Sources/MeetingPipe")
        guard let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else {
            XCTFail("could not walk \(sources.path)")
            return []
        }
        var hits: Set<String> = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains("struct FlowLayout: Layout") { hits.insert(url.lastPathComponent) }
        }
        return hits
    }

    /// One declaration, in the shared design-system home, visible to the module. UX30's
    /// `MPDangerButtonStyle` is the cautionary tale this repeats: a shared-looking
    /// primitive left `private` is invisible to the next surface that needs it, and the
    /// next surface then writes its own and drifts. A second `FlowLayout` anywhere in the
    /// target is that failure happening again, so it is what this fails on.
    func test_the_wrapping_layout_is_declared_once_in_the_shared_controls_file() throws {
        XCTAssertEqual(try declaringFiles(), ["PreferencesControls.swift"])
        let controls = try String(
            contentsOf: daemonRoot.appendingPathComponent("Sources/MeetingPipe/Preferences/PreferencesControls.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(controls.contains("private struct FlowLayout"),
                       "promoting it and leaving it private would be the UX30 mistake with extra steps")
    }
}
