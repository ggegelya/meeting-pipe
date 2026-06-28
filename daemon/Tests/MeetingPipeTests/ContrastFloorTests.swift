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
        assertPair(MPColors.fg, "fg", on: MPColors.bg, "bg", dark: false, floor: 4.5, pin: 17.35)
        assertPair(MPColors.fg, "fg", on: MPColors.bgRaised, "bgRaised", dark: false, floor: 4.5, pin: 18.11)
        assertPair(MPColors.fg, "fg", on: MPColors.bgSunk, "bgSunk", dark: false, floor: 4.5, pin: 16.18)
        assertPair(MPColors.fgMuted, "fgMuted", on: MPColors.bg, "bg", dark: false, floor: 4.5, pin: 7.89)
        assertPair(MPColors.fgMuted, "fgMuted", on: MPColors.bgRaised, "bgRaised", dark: false, floor: 4.5, pin: 8.23)
        assertPair(MPColors.fgMuted, "fgMuted", on: MPColors.bgSunk, "bgSunk", dark: false, floor: 4.5, pin: 7.35)
        assertPair(MPColors.fgSubtle, "fgSubtle", on: MPColors.bg, "bg", dark: false, floor: 4.5, pin: 4.50)
        assertPair(MPColors.fgSubtle, "fgSubtle", on: MPColors.bgRaised, "bgRaised", dark: false, floor: 4.5, pin: 4.70)
        // Dark.
        assertPair(MPColors.fg, "fg", on: MPColors.bg, "bg", dark: true, floor: 4.5, pin: 15.24)
        assertPair(MPColors.fg, "fg", on: MPColors.bgRaised, "bgRaised", dark: true, floor: 4.5, pin: 13.24)
        assertPair(MPColors.fg, "fg", on: MPColors.bgSunk, "bgSunk", dark: true, floor: 4.5, pin: 16.30)
        assertPair(MPColors.fgMuted, "fgMuted", on: MPColors.bg, "bg", dark: true, floor: 4.5, pin: 9.11)
        assertPair(MPColors.fgMuted, "fgMuted", on: MPColors.bgRaised, "bgRaised", dark: true, floor: 4.5, pin: 7.91)
        assertPair(MPColors.fgMuted, "fgMuted", on: MPColors.bgSunk, "bgSunk", dark: true, floor: 4.5, pin: 9.74)
        assertPair(MPColors.fgSubtle, "fgSubtle", on: MPColors.bg, "bg", dark: true, floor: 4.5, pin: 5.36)
        assertPair(MPColors.fgSubtle, "fgSubtle", on: MPColors.bgRaised, "bgRaised", dark: true, floor: 4.5, pin: 4.66)
    }

    /// fgSubtle in the shallow bgSunk well: 3:1 UI floor (UX14 keeps real sunk-well text on fgMuted).
    func test_fgSubtle_in_sunk_well_clears_ui_floor() {
        assertPair(MPColors.fgSubtle, "fgSubtle", on: MPColors.bgSunk, "bgSunk", dark: false, floor: 3.0, pin: 4.20)
        assertPair(MPColors.fgSubtle, "fgSubtle", on: MPColors.bgSunk, "bgSunk", dark: true, floor: 3.0, pin: 5.73)
    }

    /// Accent + semantic text: AA in light, 3:1 (icon-paired UI status tone) in dark.
    func test_accent_text_tokens() {
        // Light: full AA body floor.
        assertPair(MPColors.signalAccent, "signalAccent", on: MPColors.bg, "bg", dark: false, floor: 4.5, pin: 5.78)
        assertPair(MPColors.signalAccent, "signalAccent", on: MPColors.bgRaised, "bgRaised", dark: false, floor: 4.5, pin: 6.03)
        assertPair(MPColors.successAccent, "successAccent", on: MPColors.bg, "bg", dark: false, floor: 4.5, pin: 5.81)
        assertPair(MPColors.successAccent, "successAccent", on: MPColors.bgRaised, "bgRaised", dark: false, floor: 4.5, pin: 6.06)
        assertPair(MPColors.warningAccent, "warningAccent", on: MPColors.bg, "bg", dark: false, floor: 4.5, pin: 5.68)
        assertPair(MPColors.warningAccent, "warningAccent", on: MPColors.bgRaised, "bgRaised", dark: false, floor: 4.5, pin: 5.93)
        assertPair(MPColors.danger600, "danger600", on: MPColors.bg, "bg", dark: false, floor: 4.5, pin: 5.23)
        assertPair(MPColors.danger600, "danger600", on: MPColors.bgRaised, "bgRaised", dark: false, floor: 4.5, pin: 5.46)
        // Dark: 3:1 UI floor. danger600 on a raised card (2.74) is the documented
        // gap and is asserted only on the base canvas here.
        assertPair(MPColors.signalAccent, "signalAccent", on: MPColors.bg, "bg", dark: true, floor: 3.0, pin: 4.18)
        assertPair(MPColors.signalAccent, "signalAccent", on: MPColors.bgRaised, "bgRaised", dark: true, floor: 3.0, pin: 3.63)
        assertPair(MPColors.successAccent, "successAccent", on: MPColors.bg, "bg", dark: true, floor: 3.0, pin: 4.18)
        assertPair(MPColors.successAccent, "successAccent", on: MPColors.bgRaised, "bgRaised", dark: true, floor: 3.0, pin: 3.63)
        assertPair(MPColors.warningAccent, "warningAccent", on: MPColors.bg, "bg", dark: true, floor: 3.0, pin: 4.38)
        assertPair(MPColors.warningAccent, "warningAccent", on: MPColors.bgRaised, "bgRaised", dark: true, floor: 3.0, pin: 3.81)
        assertPair(MPColors.danger600, "danger600", on: MPColors.bg, "bg", dark: true, floor: 3.0, pin: 3.16)
    }

    /// White button labels on the deep light-mode fills (UX14 darkened these off
    /// the brighter 600 steps, which fail white-on-fill at 4.12 / 3.91).
    func test_white_label_on_deep_fills() {
        assertPair(MPColors.fgOnSignal, "white", on: MPColors.signal700, "signal700", dark: false, floor: 4.5, pin: 6.03)
        assertPair(MPColors.fgOnSignal, "white", on: MPColors.pulse700, "pulse700", dark: false, floor: 4.5, pin: 5.59)
        assertPair(MPColors.fgOnSignal, "white", on: MPColors.success700, "success700", dark: false, floor: 4.5, pin: 6.06)
        assertPair(MPColors.fgOnSignal, "white", on: MPColors.warning700, "warning700", dark: false, floor: 4.5, pin: 5.93)
    }
}
