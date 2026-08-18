import CoreGraphics
import XCTest
@testable import MeetingPipe

/// FEAT15's pure halves: where a reader is in the tour, which window has to be
/// up for the step they are on, and where the hole and the card go once it is.
///
/// All three were lifted out of the view deliberately. The interesting cases
/// here (a control at the bottom edge, a control taller than the room a card
/// needs, Back crossing from Preferences to the Library) are the ones that are
/// slowest to provoke by hand and the ones a layout change silently breaks.
final class TutorialTests: XCTestCase {

    // MARK: - The script

    func test_every_anchor_is_used_by_exactly_one_step() {
        let used = TutorialScript.steps.map(\.anchor)
        XCTAssertEqual(Set(used).count, used.count, "an anchor is pointed at twice")
        XCTAssertEqual(Set(used), Set(TutorialAnchor.allCases),
                       "every anchor exists to be toured; an unused one is dead weight the fences still police")
    }

    /// The tour walks each surface once and does not bounce between windows. Not
    /// a style preference: every transition is a window being fronted under the
    /// reader, so a script that alternated would flicker two windows at them.
    func test_the_tour_visits_each_surface_once_in_a_run() {
        let visited = TutorialPlan.entries(for: TutorialScript.steps).compactMap { entry -> TutorialSurface? in
            guard case .open(let surface) = entry else { return nil }
            return surface
        }
        XCTAssertEqual(Set(visited).count, visited.count, "a surface is opened twice; the tour is bouncing")
        XCTAssertEqual(visited, TutorialPlan.surfaces(for: TutorialScript.steps))
    }

    func test_the_script_starts_in_the_library_the_menu_bar_already_opens() {
        XCTAssertEqual(TutorialScript.steps.first?.surface, .library)
    }

    // MARK: - Which window has to be up

    func test_a_step_opens_its_surface_only_when_it_is_not_the_one_on_screen() {
        let libraryStep = TutorialStep(anchor: .record, headline: "h", body: "b")
        XCTAssertEqual(TutorialPlan.entry(for: libraryStep, presented: nil), .open(.library))
        XCTAssertEqual(TutorialPlan.entry(for: libraryStep, presented: .library), .stay)
    }

    /// The regression a forward-only plan produced. Step five is in the Library
    /// and its neighbour on the way down is too, so a plan phrased against the
    /// *previous step* marks it `.stay`. Coming back to it from Preferences, that
    /// left the tour narrating a window the reader could not see.
    func test_stepping_back_out_of_preferences_re_opens_the_library() {
        let libraryStep = TutorialStep(anchor: .preferencesGear, headline: "h", body: "b")
        XCTAssertEqual(TutorialPlan.entry(for: libraryStep, presented: .preferencesPipeline),
                       .open(.library))
    }

    /// Two panes of the same window are two surfaces, because a control on an
    /// unselected pane is exactly as invisible as one in a closed window.
    func test_moving_between_preferences_panes_is_an_open_not_a_stay() {
        let permissionsStep = TutorialStep(anchor: .regulatedMode, headline: "h", body: "b")
        XCTAssertEqual(TutorialPlan.entry(for: permissionsStep, presented: .preferencesPipeline),
                       .open(.preferencesPermissions))
        XCTAssertEqual(TutorialPlan.entry(for: permissionsStep, presented: .preferencesPermissions),
                       .stay)
    }

    func test_the_shipped_scripts_window_moves() {
        XCTAssertEqual(
            TutorialPlan.entries(for: TutorialScript.steps),
            [.open(.library), .stay, .stay, .stay,
             .open(.preferencesPipeline), .stay,
             .open(.preferencesPermissions)]
        )
    }

    // MARK: - Progress through the tour

    func test_a_fresh_run_starts_on_the_first_step() {
        let run = TutorialRun()
        XCTAssertEqual(run.step, TutorialScript.steps.first)
        XCTAssertTrue(run.isFirst)
        XCTAssertFalse(run.isLast)
        XCTAssertEqual(run.progress, "Step 1 of \(TutorialScript.steps.count)")
    }

    func test_back_on_the_first_step_does_nothing() {
        var run = TutorialRun()
        run.rewind()
        XCTAssertEqual(run.index, 0)
        XCTAssertNotNil(run.step)
    }

    func test_next_on_the_last_step_ends_the_tour() {
        var run = TutorialRun(steps: Array(TutorialScript.steps.prefix(2)))
        run.advance()
        XCTAssertTrue(run.isLast)
        run.advance()
        XCTAssertNil(run.step, "the tour is over; there is nothing to point at")
    }

    func test_an_ended_tour_stays_ended() {
        var run = TutorialRun(steps: Array(TutorialScript.steps.prefix(2)))
        run.dismiss()
        run.advance()
        run.rewind()
        XCTAssertNil(run.step)
    }

    /// A script with no steps is not a tour that shows an empty card; it is a
    /// tour that is already over. Reachable only from a test today, and cheap to
    /// keep true.
    func test_an_empty_script_is_done_on_arrival() {
        let run = TutorialRun(steps: [])
        XCTAssertNil(run.step)
    }

    // MARK: - Resolving a control

    private let viewport = CGSize(width: 900, height: 600)

    func test_an_anchor_that_reported_nothing_is_missing() {
        XCTAssertEqual(
            TutorialSpotlight.focus(.record, frames: [:], viewport: viewport),
            .missing
        )
    }

    /// A control inside a branch the window is not showing still reports, at zero
    /// size. That reads to a person exactly like a deleted one, so it resolves
    /// the same way rather than cutting an invisible hole.
    func test_a_collapsed_frame_is_missing() {
        let frames: [TutorialAnchor: CGRect] = [.record: CGRect(x: 40, y: 40, width: 0, height: 0)]
        XCTAssertEqual(TutorialSpotlight.focus(.record, frames: frames, viewport: viewport), .missing)
    }

    func test_a_control_scrolled_out_of_the_window_is_missing() {
        let frames: [TutorialAnchor: CGRect] = [
            .regulatedMode: CGRect(x: 40, y: 900, width: 400, height: 90)
        ]
        XCTAssertEqual(TutorialSpotlight.focus(.regulatedMode, frames: frames, viewport: viewport), .missing)
    }

    /// Half on screen is still something to point at: the hole is clipped rather
    /// than refused, because a reader can see the half that is showing.
    func test_a_partly_visible_control_still_resolves_and_the_hole_is_clipped() {
        let frames: [TutorialAnchor: CGRect] = [
            .regulatedMode: CGRect(x: 40, y: 560, width: 400, height: 90)
        ]
        guard case .control(let hole) = TutorialSpotlight.focus(
            .regulatedMode, frames: frames, viewport: viewport
        ) else { return XCTFail("a control overlapping the viewport is not missing") }
        XCTAssertEqual(hole.maxY, viewport.height, accuracy: 0.001)
        XCTAssertEqual(hole.minY, 554, accuracy: 0.001, "grown by the padding, then clipped")
    }

    func test_the_hole_is_the_control_plus_padding() {
        let control = CGRect(x: 100, y: 100, width: 120, height: 26)
        let hole = TutorialSpotlight.hole(around: control, in: viewport)
        XCTAssertEqual(hole, control.insetBy(dx: -TutorialSpotlight.padding, dy: -TutorialSpotlight.padding))
    }

    // MARK: - Where the card goes

    private let card = CGSize(width: 360, height: 280)

    func test_the_card_sits_under_a_control_with_room_beneath_it() {
        let hole = CGRect(x: 100, y: 60, width: 120, height: 26)
        let placed = TutorialSpotlight.card(for: hole, in: viewport, size: card)
        XCTAssertEqual(placed.placement, .below)
        XCTAssertEqual(placed.frame.minY, hole.maxY + TutorialSpotlight.gap, accuracy: 0.001)
    }

    func test_the_card_moves_above_a_control_near_the_bottom() {
        let hole = CGRect(x: 100, y: 520, width: 120, height: 26)
        let placed = TutorialSpotlight.card(for: hole, in: viewport, size: card)
        XCTAssertEqual(placed.placement, .above)
        XCTAssertEqual(placed.frame.maxY, hole.minY - TutorialSpotlight.gap, accuracy: 0.001)
    }

    /// The Library's rail: a control that is the full height of the window, so
    /// neither above nor below can hold a card. It goes beside it.
    func test_a_full_height_control_puts_the_card_beside_it() {
        let hole = CGRect(x: 0, y: 0, width: 220, height: 600)
        let placed = TutorialSpotlight.card(for: hole, in: viewport, size: card)
        XCTAssertEqual(placed.placement, .trailing)
        XCTAssertEqual(placed.frame.minX, hole.maxX + TutorialSpotlight.gap, accuracy: 0.001)
    }

    func test_a_control_filling_the_window_centres_the_card() {
        let hole = CGRect(origin: .zero, size: viewport)
        let placed = TutorialSpotlight.card(for: hole, in: viewport, size: card)
        XCTAssertEqual(placed.placement, .centered)
    }

    func test_no_hole_centres_the_card() {
        let placed = TutorialSpotlight.card(for: nil, in: viewport, size: card)
        XCTAssertEqual(placed.placement, .centered)
        XCTAssertEqual(placed.frame.midX, viewport.width / 2, accuracy: 0.001)
        XCTAssertEqual(placed.frame.midY, viewport.height / 2, accuracy: 0.001)
    }

    /// The one rule that is not preference, swept over the whole window rather
    /// than spot-checked: a card covering the control it describes is worse than
    /// no card. `.centered` is the declared exception, taken only when nothing
    /// else fits.
    func test_the_card_never_covers_the_control_it_describes() {
        for x in stride(from: CGFloat(0), through: 840, by: 60) {
            for y in stride(from: CGFloat(0), through: 560, by: 40) {
                let hole = CGRect(x: x, y: y, width: 60, height: 30)
                let placed = TutorialSpotlight.card(for: hole, in: viewport, size: card)
                if placed.placement == .centered { continue }
                XCTAssertFalse(placed.frame.intersects(hole),
                               "card at \(placed.frame) covers the control at \(hole)")
            }
        }
    }

    func test_the_card_stays_inside_the_window() {
        for x in stride(from: CGFloat(0), through: 840, by: 60) {
            for y in stride(from: CGFloat(0), through: 560, by: 40) {
                let hole = CGRect(x: x, y: y, width: 60, height: 30)
                let frame = TutorialSpotlight.card(for: hole, in: viewport, size: card).frame
                XCTAssertGreaterThanOrEqual(frame.minX, 0)
                XCTAssertGreaterThanOrEqual(frame.minY, 0)
                XCTAssertLessThanOrEqual(frame.maxX, viewport.width)
                XCTAssertLessThanOrEqual(frame.maxY, viewport.height)
            }
        }
    }
}
