import AppKit
import XCTest
@testable import MeetingPipe

/// DSN18: a computed WCAG 2.1 contrast gate over the real `MPColors` tokens.
/// Resolves each (appearance-dynamic) token under aqua / dark-aqua so the test
/// reads exactly what ships, then asserts every text-on-surface pairing clears
/// its floor in BOTH appearances. Each ratio is also pinned (accuracy 0.05), so
/// a token edit that moves a pair (even above the floor) fails the build and
/// forces a conscious update plus a refresh of the checked-in ratio table
/// (`docs/audits/dsn18-contrast-ratios.md`). Locks in UX14; pairs with the
/// `design-tokens` CI guard that bans bare native `.secondary`/`.tertiary` text.
///
/// Two floors, by token role:
///   - Body text (`fg`, `fgMuted`, `fgSubtle`): AA body floor 4.5 (3:1 only for
///     `fgSubtle` in the shallow bgSunk well, where UX14 keeps real text on
///     `fgMuted`). All pass in both appearances.
///   - Accent / semantic text (`signalAccent`, `successAccent`, `warningAccent`,
///     `danger600`): 4.5 in light (UX14 tuned the deep `700` step to clear it,
///     the original "ugly white theme" complaint), 3:1 in dark. The dark legs
///     resolve to the brighter `600` step, which UX14 deliberately left as the
///     icon-paired status tone (PRODUCT: semantic state is never color-only, the
///     pill always carries text + icon). The residual dark-accent AA gap and the
///     one sub-3:1 pair (danger600 on a raised card in dark, 2.74) are recorded
///     in the ratio table as an owner-owed dark-accent pass; DSN18 only measures
///     and guards, it changes no token value.
enum WCAG {
    /// sRGB components of a (possibly appearance-dynamic) NSColor, resolved in
    /// the given appearance so dynamic catalog tokens pick their light/dark leg.
    static func srgb(_ color: NSColor, dark: Bool) -> (r: Double, g: Double, b: Double) {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        var resolved = color
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? color
        }
        return (Double(resolved.redComponent), Double(resolved.greenComponent), Double(resolved.blueComponent))
    }

    static func relativeLuminance(_ c: (r: Double, g: Double, b: Double)) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    static func ratio(_ fg: NSColor, on bg: NSColor, dark: Bool) -> Double {
        let lf = relativeLuminance(srgb(fg, dark: dark))
        let lb = relativeLuminance(srgb(bg, dark: dark))
        let hi = max(lf, lb), lo = min(lf, lb)
        return (hi + 0.05) / (lo + 0.05)
    }
}

final class ContrastFloorTests: XCTestCase {

    private func assertPair(
        _ fg: NSColor, _ fgName: String,
        on bg: NSColor, _ bgName: String,
        dark: Bool, floor: Double, pin: Double,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let r = WCAG.ratio(fg, on: bg, dark: dark)
        let where_ = "[\(dark ? "dark" : "light")] \(fgName) on \(bgName) = \(String(format: "%.2f", r))"
        XCTAssertGreaterThanOrEqual(r, floor, "\(where_) < floor \(floor)", file: file, line: line)
        XCTAssertEqual(
            r, pin, accuracy: 0.05,
            "\(where_) drifted from pinned \(pin); update the pin and docs/audits/dsn18-contrast-ratios.md",
            file: file, line: line
        )
    }

    /// fg + fgMuted on every surface; fgSubtle on the two canvases. AA body floor.
    func test_body_text_tokens_meet_AA_both_appearances() {
        // Light.
        assertPair(MPColors.fg, "fg", on: MPColors.bg, "bg", dark: false, floor: 4.5, pin: 16.44)
        assertPair(MPColors.fg, "fg", on: MPColors.bgRaised, "bgRaised", dark: false, floor: 4.5, pin: 17.77)
        assertPair(MPColors.fg, "fg", on: MPColors.bgSunk, "bgSunk", dark: false, floor: 4.5, pin: 15.29)
        assertPair(MPColors.fgMuted, "fgMuted", on: MPColors.bg, "bg", dark: false, floor: 4.5, pin: 5.94)
        assertPair(MPColors.fgMuted, "fgMuted", on: MPColors.bgRaised, "bgRaised", dark: false, floor: 4.5, pin: 6.42)
        assertPair(MPColors.fgMuted, "fgMuted", on: MPColors.bgSunk, "bgSunk", dark: false, floor: 4.5, pin: 5.53)
        assertPair(MPColors.fgSubtle, "fgSubtle", on: MPColors.bg, "bg", dark: false, floor: 4.5, pin: 4.91)
        assertPair(MPColors.fgSubtle, "fgSubtle", on: MPColors.bgRaised, "bgRaised", dark: false, floor: 4.5, pin: 5.31)
        // Dark.
        assertPair(MPColors.fg, "fg", on: MPColors.bg, "bg", dark: true, floor: 4.5, pin: 15.07)
        assertPair(MPColors.fg, "fg", on: MPColors.bgRaised, "bgRaised", dark: true, floor: 4.5, pin: 13.03)
        assertPair(MPColors.fg, "fg", on: MPColors.bgSunk, "bgSunk", dark: true, floor: 4.5, pin: 16.14)
        assertPair(MPColors.fgMuted, "fgMuted", on: MPColors.bg, "bg", dark: true, floor: 4.5, pin: 7.71)
        assertPair(MPColors.fgMuted, "fgMuted", on: MPColors.bgRaised, "bgRaised", dark: true, floor: 4.5, pin: 6.66)
        assertPair(MPColors.fgMuted, "fgMuted", on: MPColors.bgSunk, "bgSunk", dark: true, floor: 4.5, pin: 8.26)
        assertPair(MPColors.fgSubtle, "fgSubtle", on: MPColors.bg, "bg", dark: true, floor: 4.5, pin: 5.25)
        assertPair(MPColors.fgSubtle, "fgSubtle", on: MPColors.bgRaised, "bgRaised", dark: true, floor: 4.5, pin: 4.54)
    }

    /// fgSubtle in the shallow bgSunk well: 3:1 UI floor (UX14 keeps real sunk-well text on fgMuted).
    func test_fgSubtle_in_sunk_well_clears_ui_floor() {
        assertPair(MPColors.fgSubtle, "fgSubtle", on: MPColors.bgSunk, "bgSunk", dark: false, floor: 3.0, pin: 4.57)
        assertPair(MPColors.fgSubtle, "fgSubtle", on: MPColors.bgSunk, "bgSunk", dark: true, floor: 3.0, pin: 5.63)
    }

    /// Accent + semantic text: AA in light, 3:1 (icon-paired UI status tone) in dark.
    func test_accent_text_tokens() {
        // Light: full AA body floor.
        assertPair(MPColors.signalAccent, "signalAccent", on: MPColors.bg, "bg", dark: false, floor: 4.5, pin: 5.67)
        assertPair(MPColors.signalAccent, "signalAccent", on: MPColors.bgRaised, "bgRaised", dark: false, floor: 4.5, pin: 6.13)
        assertPair(MPColors.successAccent, "successAccent", on: MPColors.bg, "bg", dark: false, floor: 4.5, pin: 5.61)
        assertPair(MPColors.successAccent, "successAccent", on: MPColors.bgRaised, "bgRaised", dark: false, floor: 4.5, pin: 6.06)
        assertPair(MPColors.warningAccent, "warningAccent", on: MPColors.bg, "bg", dark: false, floor: 4.5, pin: 5.48)
        assertPair(MPColors.warningAccent, "warningAccent", on: MPColors.bgRaised, "bgRaised", dark: false, floor: 4.5, pin: 5.93)
        assertPair(MPColors.danger600, "danger600", on: MPColors.bg, "bg", dark: false, floor: 4.5, pin: 5.05)
        assertPair(MPColors.danger600, "danger600", on: MPColors.bgRaised, "bgRaised", dark: false, floor: 4.5, pin: 5.46)
        // Dark: signalAccent now resolves to the bright display teal (#36C6B8, DSN23)
        // and clears the 4.5 body floor; success/warning/danger keep the 3:1
        // icon-paired UI floor (semantic state is never colour-only). danger600 on a
        // raised card (~2.7) stays the documented gap, asserted only on the base canvas.
        assertPair(MPColors.signalAccent, "signalAccent", on: MPColors.bg, "bg", dark: true, floor: 4.5, pin: 7.98)
        assertPair(MPColors.signalAccent, "signalAccent", on: MPColors.bgRaised, "bgRaised", dark: true, floor: 4.5, pin: 6.90)
        assertPair(MPColors.successAccent, "successAccent", on: MPColors.bg, "bg", dark: true, floor: 3.0, pin: 4.10)
        assertPair(MPColors.successAccent, "successAccent", on: MPColors.bgRaised, "bgRaised", dark: true, floor: 3.0, pin: 3.54)
        assertPair(MPColors.warningAccent, "warningAccent", on: MPColors.bg, "bg", dark: true, floor: 3.0, pin: 4.30)
        assertPair(MPColors.warningAccent, "warningAccent", on: MPColors.bgRaised, "bgRaised", dark: true, floor: 3.0, pin: 3.71)
        assertPair(MPColors.danger600, "danger600", on: MPColors.bg, "bg", dark: true, floor: 3.0, pin: 3.09)
    }

    /// White button labels on the deep light-mode fills (UX14 darkened these off
    /// the brighter 600 steps, which fail white-on-fill at 4.12 / 3.91).
    func test_white_label_on_deep_fills() {
        assertPair(MPColors.fgOnSignal, "white", on: MPColors.signal700, "signal700", dark: false, floor: 4.5, pin: 6.13)
        assertPair(MPColors.fgOnSignal, "white", on: MPColors.pulse700, "pulse700", dark: false, floor: 4.5, pin: 5.59)
        assertPair(MPColors.fgOnSignal, "white", on: MPColors.success700, "success700", dark: false, floor: 4.5, pin: 6.06)
        assertPair(MPColors.fgOnSignal, "white", on: MPColors.warning700, "warning700", dark: false, floor: 4.5, pin: 5.93)
    }

    /// DSN23: white on the new deep signal fill (primary buttons, active scope row).
    /// The fill is fixed in both modes, so the ratio holds across appearances.
    func test_white_label_on_signal_fill() {
        assertPair(MPColors.fgOnSignal, "white", on: MPColors.signalFill, "signalFill", dark: false, floor: 4.5, pin: 4.88)
        assertPair(MPColors.fgOnSignal, "white", on: MPColors.signalFill, "signalFill", dark: true, floor: 4.5, pin: 4.88)
    }

    /// DSN23: the "Instrument" record-action label on its fill. Light: white on the
    /// deep teal fill. Dark: a near-black backlit label on the brighter fill.
    func test_record_action_label_on_fill() {
        assertPair(MPColors.recordLabel, "recordLabel", on: MPColors.recordFill, "recordFill", dark: false, floor: 4.5, pin: 4.88)
        assertPair(MPColors.recordLabel, "recordLabel", on: MPColors.recordFill, "recordFill", dark: true, floor: 4.5, pin: 4.88)
    }
}
