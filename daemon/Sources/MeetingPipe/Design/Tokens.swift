import AppKit
import SwiftUI

/// Design tokens mirroring `design/colors_and_type.css`. Source of truth is the CSS file; update here when a token changes there. Spot-checked by `DesignTokensTests`. Naming: `--mp-ink-900` -> `MPColors.ink900`. Prefer the semantic accessors (`MPColors.fg`, `MPColors.bg`) over raw palette steps - they auto-flip in dark mode.
enum MPColors {
    // MARK: Ink (warm near-blacks for foreground)
    static let ink900 = NSColor(srgbRed: 0x14/255.0, green: 0x16/255.0, blue: 0x1A/255.0, alpha: 1)
    static let ink800 = NSColor(srgbRed: 0x1F/255.0, green: 0x22/255.0, blue: 0x27/255.0, alpha: 1)
    static let ink700 = NSColor(srgbRed: 0x2C/255.0, green: 0x30/255.0, blue: 0x37/255.0, alpha: 1)
    static let ink600 = NSColor(srgbRed: 0x4A/255.0, green: 0x4F/255.0, blue: 0x58/255.0, alpha: 1)
    static let ink500 = NSColor(srgbRed: 0x6E/255.0, green: 0x74/255.0, blue: 0x7F/255.0, alpha: 1)
    static let ink400 = NSColor(srgbRed: 0x90/255.0, green: 0x98/255.0, blue: 0xA4/255.0, alpha: 1)
    static let ink300 = NSColor(srgbRed: 0xB7/255.0, green: 0xBD/255.0, blue: 0xC6/255.0, alpha: 1)
    static let ink200 = NSColor(srgbRed: 0xD8/255.0, green: 0xDC/255.0, blue: 0xE2/255.0, alpha: 1)
    static let ink100 = NSColor(srgbRed: 0xEC/255.0, green: 0xEE/255.0, blue: 0xF2/255.0, alpha: 1)
    static let ink50  = NSColor(srgbRed: 0xF5/255.0, green: 0xF6/255.0, blue: 0xF8/255.0, alpha: 1)

    // MARK: Paper (canvas)
    static let paper       = NSColor(srgbRed: 0xFB/255.0, green: 0xFA/255.0, blue: 0xF7/255.0, alpha: 1)
    static let paperSunk   = NSColor(srgbRed: 0xF4/255.0, green: 0xF2/255.0, blue: 0xEC/255.0, alpha: 1)
    static let paperRaised = NSColor.white

    // MARK: Signal (teal - the "live"/on-air color)
    static let signal700 = NSColor(srgbRed: 0x0A/255.0, green: 0x6F/255.0, blue: 0x67/255.0, alpha: 1)
    static let signal600 = NSColor(srgbRed: 0x0E/255.0, green: 0x8C/255.0, blue: 0x82/255.0, alpha: 1) // primary
    static let signal500 = NSColor(srgbRed: 0x14/255.0, green: 0xA8/255.0, blue: 0x9B/255.0, alpha: 1)
    static let signal400 = NSColor(srgbRed: 0x4F/255.0, green: 0xC7/255.0, blue: 0xBC/255.0, alpha: 1)
    static let signal100 = NSColor(srgbRed: 0xDC/255.0, green: 0xF1/255.0, blue: 0xEF/255.0, alpha: 1)

    // MARK: Pulse (recording dot - never decorative)
    static let pulse700 = NSColor(srgbRed: 0xBE/255.0, green: 0x35/255.0, blue: 0x3A/255.0, alpha: 1) // deep coral: light-mode legible Stop label + recording/failed pill text (UX14)
    static let pulse600 = NSColor(srgbRed: 0xE5/255.0, green: 0x48/255.0, blue: 0x4D/255.0, alpha: 1)
    static let pulse500 = NSColor(srgbRed: 0xF5/255.0, green: 0x59/255.0, blue: 0x5E/255.0, alpha: 1)
    static let pulse100 = NSColor(srgbRed: 0xFF/255.0, green: 0xE4/255.0, blue: 0xE4/255.0, alpha: 1)

    // MARK: Semantic states (mirror `--mp-success-*` / `--mp-warning-*` / `--mp-danger-*`). Foreground tints only - never full toast backgrounds (design rule: "Semantic states appear only in inline status rows"). The `700` steps are the light-mode-legible deep variants of the `600` tones (UX14); use them as text on paper, the `600` step in dark.
    static let success700 = NSColor(srgbRed: 0x16/255.0, green: 0x71/255.0, blue: 0x3D/255.0, alpha: 1) // light-mode legible (UX14)
    static let success600 = NSColor(srgbRed: 0x1F/255.0, green: 0x8F/255.0, blue: 0x4E/255.0, alpha: 1)
    static let success100 = NSColor(srgbRed: 0xDC/255.0, green: 0xF1/255.0, blue: 0xE2/255.0, alpha: 1)
    static let warning700 = NSColor(srgbRed: 0x8A/255.0, green: 0x5A/255.0, blue: 0x00/255.0, alpha: 1) // light-mode legible (UX14)
    static let warning600 = NSColor(srgbRed: 0xB2/255.0, green: 0x73/255.0, blue: 0x00/255.0, alpha: 1)
    static let warning100 = NSColor(srgbRed: 0xFF/255.0, green: 0xF1/255.0, blue: 0xCC/255.0, alpha: 1)
    static let danger600  = NSColor(srgbRed: 0xC9/255.0, green: 0x2A/255.0, blue: 0x2A/255.0, alpha: 1)
    static let danger100  = NSColor(srgbRed: 0xFC/255.0, green: 0xE4/255.0, blue: 0xE4/255.0, alpha: 1)

    // MARK: Speaker palette (TECH-DSN3)
    /// Categorical per-speaker hues for the transcript view, the one place a
    /// multi-hue set is legitimate (it labels diarized speakers, not a semantic
    /// state). Centralised here so the raw-color CI guard can point everything
    /// else at tokens while this stays a single, intentional source.
    /// Order matches the historical inline palette so speaker -> colour
    /// assignments (`palette[n % count]`) don't reshuffle.
    /// Appearance-aware (UX14): the raw system hues fail WCAG as text on paper
    /// (7 of 8 below 4.5:1), so light mode uses a deep variant of each hue
    /// (>= 4.5:1 on paper) while dark mode keeps the native system colour
    /// (already legible there). The dot and the name label both read this, so
    /// dark mode is unchanged and light-mode speaker names become legible.
    static let speakerPalette: [NSColor] = [
        MPColors.speakerHue(light: 0x1D5BC4, dark: .systemBlue),
        MPColors.speakerHue(light: 0x7A33C2, dark: .systemPurple),
        MPColors.speakerHue(light: 0xBC2D6B, dark: .systemPink),
        MPColors.speakerHue(light: 0xB45309, dark: .systemOrange),
        MPColors.speakerHue(light: 0x0E7C74, dark: .systemTeal),
        MPColors.speakerHue(light: 0x1B7A3D, dark: .systemGreen),
        MPColors.speakerHue(light: 0x4338CA, dark: .systemIndigo),
        MPColors.speakerHue(light: 0x875A2C, dark: .systemBrown),
    ]

    /// One categorical speaker hue: the WCAG-legible deep `light` variant on
    /// paper, the native `dark` system colour in dark mode (UX14).
    private static func speakerHue(light rgb: Int, dark: NSColor) -> NSColor {
        let lightColor = NSColor(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255.0,
            green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
            blue: CGFloat(rgb & 0xFF) / 255.0,
            alpha: 1
        )
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil ? dark : lightColor
        }
    }

    // MARK: Workflow swatches (TECH-DSN11)
    /// Curated workflow colours: a tonal family that holds the one-teal-accent
    /// rule instead of the free-form confetti WF3 allowed. Hex strings, because
    /// `Workflow.color` is hex. Each mirrors an existing token (asserted by
    /// `DesignTokensTests`); teal is the default. Pulse-coral (#E5484D) is
    /// deliberately absent - it is reserved for the live recording dot.
    static let workflowSwatches: [String] = [
        "#0E8C82",  // signal600 - teal (default)
        "#0A6F67",  // signal700 - deep teal
        "#4A4F58",  // ink600 - slate
        "#6E747F",  // ink500 - mid ink
        "#1F8F4E",  // success600 - green
        "#B27300",  // warning600 - amber
    ]

    /// Default workflow colour: teal, the first curated swatch (TECH-DSN11).
    static let defaultWorkflowHex = workflowSwatches[0]

    // MARK: Semantic - auto-flip on appearance.
    /// `--mp-fg` / dark `#F0F1F3`.
    static let fg = NSColor(name: "mp.fg") { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(srgbRed: 0xF0/255.0, green: 0xF1/255.0, blue: 0xF3/255.0, alpha: 1)
            : ink900
    }
    static let fgMuted = NSColor(name: "mp.fg.muted") { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? ink300
            : ink600
    }
    static let fgSubtle = NSColor(name: "mp.fg.subtle") { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(srgbRed: 0x8A/255.0, green: 0x90/255.0, blue: 0x9A/255.0, alpha: 1)
            : ink500
    }
    static let fgFaint = NSColor(name: "mp.fg.faint") { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(srgbRed: 0x5E/255.0, green: 0x64/255.0, blue: 0x70/255.0, alpha: 1)
            : ink400
    }
    static let fgOnSignal = NSColor.white

    // MARK: Accent text - appearance-aware (UX14). The `600` accent tones fail WCAG as text on paper (signal/success ~3.95:1, warning ~3.76:1) but pass in dark; the `700` deep steps pass on paper but fail in dark. So accent *text* resolves to the deep step in light and the existing `600` step in dark, leaving dark mode unchanged. Backing the `.mpSignal` / `.mpSuccess` / `.mpWarning` Color tokens.
    static let signalAccent = NSColor(name: "mp.signal.accent") { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil ? signal600 : signal700
    }
    static let successAccent = NSColor(name: "mp.success.accent") { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil ? success600 : success700
    }
    static let warningAccent = NSColor(name: "mp.warning.accent") { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil ? warning600 : warning700
    }

    static let bg = NSColor(name: "mp.bg") { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(srgbRed: 0x1A/255.0, green: 0x1B/255.0, blue: 0x1E/255.0, alpha: 1)
            : paper
    }
    static let bgRaised = NSColor(name: "mp.bg.raised") { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(srgbRed: 0x25/255.0, green: 0x27/255.0, blue: 0x2B/255.0, alpha: 1)
            : paperRaised
    }
    static let bgSunk = NSColor(name: "mp.bg.sunk") { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(srgbRed: 0x13/255.0, green: 0x14/255.0, blue: 0x17/255.0, alpha: 1)
            : paperSunk
    }

    static let border = NSColor(name: "mp.border") { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor.white.withAlphaComponent(0.08)
            : NSColor.black.withAlphaComponent(0.10)
    }
    static let borderStrong = NSColor(name: "mp.border.strong") { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor.white.withAlphaComponent(0.16)
            : NSColor.black.withAlphaComponent(0.18)
    }
    static let borderFaint = NSColor(name: "mp.border.faint") { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor.white.withAlphaComponent(0.05)
            : NSColor.black.withAlphaComponent(0.06)
    }
}

extension NSAppearance {
    /// Dark when the effective appearance matches a dark variant. Centralises the
    /// `bestMatch(from: [.darkAqua, .vibrantDark])` check the HUD chrome uses to decide whether
    /// a control needs a resting fill (dark material) or can stay de-boxed until hover (light material).
    var mpIsDark: Bool {
        bestMatch(from: [.darkAqua, .vibrantDark]) != nil
    }
}

/// SwiftUI accessors for the semantic state colors (TECH-DSN3), so views use
/// `.mpDanger` / `.mpWarning` / `.mpSuccess` / `.mpSignal` instead of the generic
/// system `.red` / `.orange` / `.green` / `.accentColor`. `.mpDanger` is fixed
/// (danger600 reads legibly on both canvases). The other three back onto the
/// appearance-aware `*Accent` NSColors (UX14): the deep `700` step on paper, the
/// `600` step in dark, so accent text clears WCAG in light without retuning dark.
/// A `static let` is still safe because the dynamic NSColor resolves at draw time.
extension Color {
    static let mpDanger  = Color(nsColor: MPColors.danger600)
    static let mpWarning = Color(nsColor: MPColors.warningAccent)
    static let mpSuccess = Color(nsColor: MPColors.successAccent)
    static let mpSignal  = Color(nsColor: MPColors.signalAccent)
    /// Library list + sidebar selection wash: a translucent signal-teal that
    /// replaces the macOS system-blue selection highlight (which the app `.tint`
    /// can't recolor). Translucent rather than the flat `signal100` token so it
    /// reads on both the paper and dark canvases; ~15% approximates the design
    /// spec's #DCF1EF wash over paper. One constant so the row and sidebar can't drift.
    static let mpSelectionWash = Color(nsColor: MPColors.signal600).opacity(0.15)
}

/// Fixed-size SwiftUI font tokens mirroring the `MPType` size ramp, so a call site
/// can set the size through a token instead of a raw `.system(size:)` literal (the
/// TECH-DSN3 guard rejects new font-size literals outside this file). Fixed, not
/// Dynamic-Type, to match the existing metadata rows.
extension Font {
    /// 11pt, the extra-small caption/label size (`MPType.textXS`).
    static let mpTextXS = Font.system(size: MPType.textXS)
}

/// Same tokens as a `ShapeStyle` leading-dot, so `.foregroundStyle(.mpDanger)`
/// resolves (a bare `.foregroundStyle(_:)` looks the member up on `ShapeStyle`,
/// not `Color`).
extension ShapeStyle where Self == Color {
    static var mpDanger:  Color { .mpDanger }
    static var mpWarning: Color { .mpWarning }
    static var mpSuccess: Color { .mpSuccess }
    static var mpSignal:  Color { .mpSignal }
}

/// Wraps a hosting-root view so native controls (list / sidebar selection,
/// toggles, focus rings, picker checkmarks) inherit signal-teal instead of the
/// user's System Settings accent (TECH-DSN10). DSN3/DSN4 tokenised custom views
/// but never set the app accent; applying `.tint` at every `NSHostingController`
/// root closes that gap. A nameable wrapper (not a `some View` extension) so
/// `CorrectionWindow`'s typed `NSHostingController<…>` reuse path can name it
/// without `AnyView`. Per-view tints (Record button, tab underline, slider),
/// the recording dot, the speaker palette, and semantic colours set their own
/// colours and are unaffected.
struct MPControlAccent<Content: View>: View {
    let content: Content
    init(_ content: Content) { self.content = content }
    var body: some View { content.tint(Color(MPColors.signal600)) }
}

/// Type tokens mirroring `--mp-text-*` and `--mp-weight-*`. The daemon uses SF Pro (system font), not Inter Tight; the display tokens exist for future surfaces that may load it.
enum MPType {
    static let textXS:   CGFloat = 11
    static let textSM:   CGFloat = 12
    static let textBase: CGFloat = 13   // mac-native default
    static let textMD:   CGFloat = 15
    static let textLG:   CGFloat = 17   // panel titles (NSPanel title weight)
    static let textXL:   CGFloat = 22
    static let text2XL:  CGFloat = 28
    static let text3XL:  CGFloat = 40
    static let text4XL:  CGFloat = 56

    // Apple convention: regular / medium / semibold. No bold.
    static let regular  = NSFont.Weight.regular
    static let medium   = NSFont.Weight.medium
    static let semibold = NSFont.Weight.semibold

    /// Eyebrow label: uppercase, +0.08em tracking.
    static let trackingCaps: CGFloat = 0.08
}

/// 4-px grid spacing, mirrors `--mp-space-*`.
enum MPSpace {
    static let s1:  CGFloat = 4
    static let s2:  CGFloat = 8
    static let s3:  CGFloat = 12
    static let s4:  CGFloat = 16
    static let s5:  CGFloat = 20
    static let s6:  CGFloat = 24
    static let s8:  CGFloat = 32
    static let s10: CGFloat = 40
    static let s12: CGFloat = 48
    static let s16: CGFloat = 64
}

/// Corner radii, mirrors `--mp-radius-*`.
enum MPRadius {
    static let xs: CGFloat = 4    // chips, tags
    static let sm: CGFloat = 6    // buttons, inputs
    static let md: CGFloat = 10   // cards
    static let lg: CGFloat = 14   // panels / sheets - matches NSPanel cornerRadius
    static let xl: CGFloat = 20   // hero cards
}

/// Motion durations and easing, mirrors `--mp-dur-*` and `--mp-ease-out`.
enum MPMotion {
    static let durFast: TimeInterval = 0.12
    static let durBase: TimeInterval = 0.18   // panel fade-in (matches existing code)
    static let durSlow: TimeInterval = 0.28

    /// Apple's default-ish ease-out curve. Used for fades.
    static let easeOut = CAMediaTimingFunction(controlPoints: 0.22, 0.61, 0.36, 1.0)
}

/// Pre-built fonts matching the type ramp and weight conventions.
extension NSFont {
    static func mpTitle() -> NSFont   { .systemFont(ofSize: MPType.textLG, weight: MPType.semibold) } // 17 / semibold - panel title
    static func mpEyebrow() -> NSFont { .systemFont(ofSize: MPType.textXS, weight: MPType.semibold) } // 11 / semibold - uppercase label
}
