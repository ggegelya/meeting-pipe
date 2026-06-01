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

    // MARK: Signal (electric blue - the "live" color)
    static let signal700 = NSColor(srgbRed: 0x1B/255.0, green: 0x53/255.0, blue: 0xD6/255.0, alpha: 1)
    static let signal600 = NSColor(srgbRed: 0x26/255.0, green: 0x67/255.0, blue: 0xF0/255.0, alpha: 1) // primary
    static let signal500 = NSColor(srgbRed: 0x3D/255.0, green: 0x80/255.0, blue: 0xFF/255.0, alpha: 1)
    static let signal400 = NSColor(srgbRed: 0x6B/255.0, green: 0xA0/255.0, blue: 0xFF/255.0, alpha: 1)
    static let signal100 = NSColor(srgbRed: 0xE3/255.0, green: 0xEC/255.0, blue: 0xFF/255.0, alpha: 1)

    // MARK: Pulse (recording dot - never decorative)
    static let pulse600 = NSColor(srgbRed: 0xE5/255.0, green: 0x48/255.0, blue: 0x4D/255.0, alpha: 1)
    static let pulse500 = NSColor(srgbRed: 0xF5/255.0, green: 0x59/255.0, blue: 0x5E/255.0, alpha: 1)
    static let pulse100 = NSColor(srgbRed: 0xFF/255.0, green: 0xE4/255.0, blue: 0xE4/255.0, alpha: 1)

    // MARK: Semantic states (mirror `--mp-success-*` / `--mp-warning-*` / `--mp-danger-*`). Foreground tints only - never full toast backgrounds (design rule: "Semantic states appear only in inline status rows").
    static let success600 = NSColor(srgbRed: 0x1F/255.0, green: 0x8F/255.0, blue: 0x4E/255.0, alpha: 1)
    static let success100 = NSColor(srgbRed: 0xDC/255.0, green: 0xF1/255.0, blue: 0xE2/255.0, alpha: 1)
    static let warning600 = NSColor(srgbRed: 0xB2/255.0, green: 0x73/255.0, blue: 0x00/255.0, alpha: 1)
    static let warning100 = NSColor(srgbRed: 0xFF/255.0, green: 0xF1/255.0, blue: 0xCC/255.0, alpha: 1)
    static let danger600  = NSColor(srgbRed: 0xC9/255.0, green: 0x2A/255.0, blue: 0x2A/255.0, alpha: 1)
    static let danger100  = NSColor(srgbRed: 0xFC/255.0, green: 0xE4/255.0, blue: 0xE4/255.0, alpha: 1)

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
