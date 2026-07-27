import AppKit
import XCTest
@testable import MeetingPipe

/// Pins the DSN24 control-kit primitives' pure geometry and the DSN19 overlay
/// token values. These primitives are built ahead of their consumers (the surface
/// ports DSN25/27/28 wire them in), so unit tests are the guard against silent
/// drift before anything renders them.
final class ControlKitTests: XCTestCase {

    // MARK: - DSN19 overlay tokens

    /// Resolve a (possibly appearance-dynamic) token to a concrete sRGB colour
    /// under a named appearance, matching `DesignTokensTests`' resolution idiom.
    private func resolve(_ color: NSColor, _ name: NSAppearance.Name) -> NSColor {
        var out = NSColor.clear
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
            out = color.usingColorSpace(.sRGB) ?? color
        }
        return out
    }

    func test_overlay_tokens_wash_ink_on_paper_white_in_dark() {
        let cases: [(NSColor, CGFloat, CGFloat)] = [
            (MPColors.overlayFaint, 0.03, 0.04),
            (MPColors.overlayHover, 0.05, 0.06),
            (MPColors.overlayPress, 0.08, 0.10),
        ]
        for (token, lightAlpha, darkAlpha) in cases {
            // Paper: an ink (black) wash, so the fill is visible on near-white.
            let light = resolve(token, .aqua)
            XCTAssertEqual(light.redComponent, 0, accuracy: 0.02, "overlay should wash ink on paper")
            XCTAssertEqual(light.alphaComponent, lightAlpha, accuracy: 0.005)
            // Dark: a white wash on the dark canvas.
            let dark = resolve(token, .darkAqua)
            XCTAssertEqual(dark.redComponent, 1, accuracy: 0.02, "overlay should wash white in dark")
            XCTAssertEqual(dark.alphaComponent, darkAlpha, accuracy: 0.005)
        }
    }

    func test_overlay_ramp_darkens_from_faint_to_press() {
        let faint = resolve(MPColors.overlayFaint, .aqua).alphaComponent
        let hover = resolve(MPColors.overlayHover, .aqua).alphaComponent
        let press = resolve(MPColors.overlayPress, .aqua).alphaComponent
        XCTAssertLessThan(faint, hover)
        XCTAssertLessThan(hover, press)
    }

    // MARK: - RecordKey morph (disc <-> rounded square)

    func test_recordKey_core_is_disc_when_record() {
        let disc = RecordKey.Geometry.core(for: .record)
        XCTAssertEqual(disc.size, 15)
        XCTAssertEqual(disc.cornerRadius, disc.size / 2) // a full circle
    }

    func test_recordKey_core_is_rounded_square_when_stop() {
        let stop = RecordKey.Geometry.core(for: .stop)
        XCTAssertEqual(stop.size, 13)
        XCTAssertEqual(stop.cornerRadius, 3)
        XCTAssertNotEqual(stop.cornerRadius, stop.size / 2) // not a circle: the stop affordance
    }

    // MARK: - LED meter stepping

    func test_ledMeter_litCount_steps_with_level_and_clamps() {
        XCTAssertEqual(LEDMeterView.litCount(forLevel: 0, segments: 10), 0)
        XCTAssertEqual(LEDMeterView.litCount(forLevel: 1, segments: 10), 10)
        XCTAssertEqual(LEDMeterView.litCount(forLevel: 0.55, segments: 10), 6) // rounds to nearest
        XCTAssertEqual(LEDMeterView.litCount(forLevel: 2, segments: 10), 10)   // clamps high
        XCTAssertEqual(LEDMeterView.litCount(forLevel: -1, segments: 10), 0)   // clamps low
        XCTAssertEqual(LEDMeterView.litCount(forLevel: 0.5, segments: 0), 0)   // no divide-by-zero
    }

    // MARK: - Mechanical toggle travel

    func test_toggle_knob_travels_inset_to_inset() {
        let off = MechanicalToggleStyle.Metrics.knobLeadingOffset(isOn: false)
        let on = MechanicalToggleStyle.Metrics.knobLeadingOffset(isOn: true)
        XCTAssertEqual(off, MechanicalToggleStyle.Metrics.knobInset)
        XCTAssertEqual(on, 16) // 34 track - 16 knob - 2 inset
        XCTAssertGreaterThan(on, off)
    }

    // MARK: - MPButton capsule geometry (DSN24 one-button language)

    func test_mpButton_primary_is_capsule_26pt_tall() {
        let button = MPButton(title: "Record", style: .primary, target: nil, action: nil)
        XCTAssertEqual(button.intrinsicContentSize.height, 26)
        XCTAssertEqual(button.layer?.cornerRadius, MPRadius.full) // capsule, not the old sm bezel
    }

    // MARK: - Capsule path geometry

    /// Corner extent of `path` measured from the rect's own corner, as (x, y).
    /// A capsule's two are equal; an ellipse's are not.
    private func cornerExtent(_ path: NSBezierPath, in rect: NSRect) -> (CGFloat, CGFloat) {
        var pts = [NSPoint](repeating: .zero, count: 3)
        var xs: [CGFloat] = [], ys: [CGFloat] = []
        for i in 0..<path.elementCount {
            let kind = path.element(at: i, associatedPoints: &pts)
            for j in 0..<((kind == .curveTo) ? 3 : 1) {
                xs.append(pts[j].x)
                ys.append(pts[j].y)
            }
        }
        let x = (xs.filter { $0 > rect.minX + 0.01 }.min() ?? rect.minX) - rect.minX
        let y = (ys.filter { $0 > rect.minY + 0.01 }.min() ?? rect.minY) - rect.minY
        return (x, y)
    }

    func test_mpCapsule_is_symmetric_on_a_wide_short_rect() {
        // Regression: the prompt's "Last time" button drew via
        // NSBezierPath(roundedRect:xRadius:yRadius:) with MPRadius.full. That
        // initializer clamps xRadius to half the width and yRadius to half the
        // height INDEPENDENTLY, so a 70x22 pill came out an ellipse.
        let rect = NSRect(x: 0, y: 0, width: 70, height: 22)
        let (x, y) = cornerExtent(.mpCapsule(in: rect), in: rect)
        XCTAssertEqual(x, y, accuracy: 0.01, "a capsule's corner must be symmetric")

        let (bx, by) = cornerExtent(
            NSBezierPath(roundedRect: rect, xRadius: MPRadius.full, yRadius: MPRadius.full),
            in: rect
        )
        XCTAssertGreaterThan(bx, by + 1, "the token-as-path form is the ellipse this replaces")
    }

    func test_mpCapsule_on_a_square_is_a_circle() {
        // The chevron beside it is 26x26, where the buggy form happened to be right.
        // Pin that the helper does not regress that case.
        let rect = NSRect(x: 0, y: 0, width: 26, height: 26)
        let (x, y) = cornerExtent(.mpCapsule(in: rect), in: rect)
        XCTAssertEqual(x, y, accuracy: 0.01)
    }

    func test_promptGhostButton_draws_a_capsule_not_an_ellipse() {
        // The user-visible half: the control's own bounds must produce a symmetric
        // corner at the size it actually renders at in the prompt.
        let button = PromptGhostButton(title: "Last time", target: nil, action: nil)
        button.frame = NSRect(x: 0, y: 0, width: button.fittingWidth, height: 22)
        button.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(button.bounds.width, button.bounds.height,
                             "fixture must be wider than tall or it cannot catch the bug")
        let inset = button.bounds.insetBy(dx: 0.5, dy: 0.5)
        let (x, y) = cornerExtent(.mpCapsule(in: inset), in: inset)
        XCTAssertEqual(x, y, accuracy: 0.01)
        // And the layer radius it pairs with stays half-height.
        XCTAssertEqual(button.layer?.cornerRadius, button.bounds.height / 2)
    }

    // MARK: - SwiftUI capsule/icon button geometry (DSN28 Preferences port)

    func test_mpButtonMetrics_match_the_locked_small_buttons() {
        // The SwiftUI `.mpGhost` / `.mpIcon` styles mirror the locked PWSmallButton /
        // PWIconButton: 24pt-tall controls (the ghost capsule padded 12pt each side,
        // the icon a 24x24 box) taking the blessed 0.97 press scale.
        XCTAssertEqual(MPButtonMetrics.height, 24)
        XCTAssertEqual(MPButtonMetrics.ghostPadding, 12)
        XCTAssertEqual(MPButtonMetrics.iconSize, 24)
        XCTAssertEqual(MPButtonMetrics.pressScale, 0.97, accuracy: 0.001)
    }

    // MARK: - Prompt Record button (renders where MPButton could not)

    func test_promptRecordButton_has_an_opaque_teal_fill() {
        // Regression: MPButton fills via layer.backgroundColor behind an NSButtonCell,
        // which did not composite on the prompt's vibrant hudWindow material, so the
        // Record button drew invisible. PromptRecordButton fills the layer directly
        // (like RecordKey). Pin the fill so it can't silently go clear/invisible again.
        let button = PromptRecordButton(target: nil, action: nil)
        button.frame = NSRect(x: 0, y: 0, width: 80, height: 26)
        button.layoutSubtreeIfNeeded()
        let fill = button.layer?.backgroundColor
        XCTAssertNotNil(fill, "the Record capsule must have a fill")
        XCTAssertEqual(fill?.alpha ?? 0, 1, accuracy: 0.01, "the fill must be opaque, not clear/invisible")
        let comps = fill?.components ?? []
        if comps.count >= 3 {
            XCTAssertGreaterThan(comps[1], comps[0], "teal fill: green dominates red")
            XCTAssertGreaterThan(comps[2], comps[0], "teal fill: blue dominates red")
        }
        XCTAssertEqual(button.intrinsicContentSize.height, 26)  // capsule matching the button language
    }
}
