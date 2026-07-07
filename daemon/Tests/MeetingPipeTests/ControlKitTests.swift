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
