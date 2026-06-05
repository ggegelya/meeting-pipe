#!/usr/bin/env swift
// Generates the README hero banner (design/assets/readme-hero.png) as a
// pure-Swift AppKit drawing, the same approach as gen-icon.swift so it needs
// no external design tool and regenerates if the brand changes. Output path is
// positional:
//   ./gen-readme-hero.swift <out.png>
//
// Dark ink card (#1A1B1E) with a soft teal glow, the waveform app icon on the
// left, and the wordmark + tagline on the right. Rendered at 2x; the README
// constrains the display width so it stays retina-crisp. Tokens are duplicated
// from design/colors_and_type.css (signal is teal #0E8C82) so this runs
// standalone.

import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write("usage: gen-readme-hero.swift <out.png>\n".data(using: .utf8)!)
    exit(2)
}
let outURL = URL(fileURLWithPath: args[1])

// Tokens (from design/colors_and_type.css).
let paperTop    = NSColor(srgbRed: 1.0,        green: 1.0,        blue: 1.0,        alpha: 1)
let paperBottom = NSColor(srgbRed: 0xF4/255.0, green: 0xF2/255.0, blue: 0xEC/255.0, alpha: 1)
let ink900      = NSColor(srgbRed: 0x14/255.0, green: 0x16/255.0, blue: 0x1A/255.0, alpha: 1)
let signal600   = NSColor(srgbRed: 0x0E/255.0, green: 0x8C/255.0, blue: 0x82/255.0, alpha: 1)
let signal500   = NSColor(srgbRed: 0x14/255.0, green: 0xA8/255.0, blue: 0x9B/255.0, alpha: 1)
let hairlineInk = NSColor(srgbRed: 0x14/255.0, green: 0x16/255.0, blue: 0x1A/255.0, alpha: 0.10)
let canvasDark  = NSColor(srgbRed: 0x1A/255.0, green: 0x1B/255.0, blue: 0x1E/255.0, alpha: 1)
let fgLight     = NSColor(srgbRed: 0xF0/255.0, green: 0xF1/255.0, blue: 0xF3/255.0, alpha: 1)
let fgMuted     = NSColor(srgbRed: 0xB7/255.0, green: 0xBD/255.0, blue: 0xC6/255.0, alpha: 1)

// ---- App icon (mirrors gen-icon.swift / design/assets/app-icon.svg) ----
func renderIcon(size: CGFloat) -> NSImage {
    let s = size / 256.0
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }
    let bounds = NSRect(x: 0, y: 0, width: size, height: size)

    let cp = bounds.width
    let squircle = NSBezierPath()
    squircle.move(to: NSPoint(x: cp * 0.5, y: cp))
    squircle.curve(to: NSPoint(x: cp, y: cp * 0.5),
                   controlPoint1: NSPoint(x: cp * 0.78, y: cp),
                   controlPoint2: NSPoint(x: cp,        y: cp * 0.78))
    squircle.curve(to: NSPoint(x: cp * 0.5, y: 0),
                   controlPoint1: NSPoint(x: cp,        y: cp * 0.22),
                   controlPoint2: NSPoint(x: cp * 0.78, y: 0))
    squircle.curve(to: NSPoint(x: 0, y: cp * 0.5),
                   controlPoint1: NSPoint(x: cp * 0.22, y: 0),
                   controlPoint2: NSPoint(x: 0,         y: cp * 0.22))
    squircle.curve(to: NSPoint(x: cp * 0.5, y: cp),
                   controlPoint1: NSPoint(x: 0,         y: cp * 0.78),
                   controlPoint2: NSPoint(x: cp * 0.22, y: cp))
    squircle.close()

    NSGraphicsContext.current?.saveGraphicsState()
    squircle.addClip()
    if let gradient = NSGradient(colors: [paperTop, paperBottom]) {
        gradient.draw(in: bounds, angle: -90)
    } else {
        paperTop.setFill(); bounds.fill()
    }
    hairlineInk.setStroke()
    let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5 * s, dy: 0.5 * s),
                             xRadius: 56 * s, yRadius: 56 * s)
    edge.lineWidth = 1 * s
    edge.stroke()

    let frameRect = NSRect(x: 40 * s, y: (256 - 92 - 80) * s, width: 176 * s, height: 80 * s)
    let frame = NSBezierPath(roundedRect: frameRect, xRadius: 28 * s, yRadius: 28 * s)
    ink900.setStroke(); frame.lineWidth = 6 * s; frame.stroke()

    let bars: [(x: CGFloat, svgY: CGFloat, h: CGFloat, color: NSColor)] = [
        (64,  128, 20, ink900),
        (84,  118, 40, ink900),
        (104, 106, 64, ink900),
        (124, 96,  84, signal600),
        (144, 106, 64, ink900),
        (164, 118, 40, ink900),
        (184, 128, 20, ink900),
    ]
    for bar in bars {
        let r = NSRect(x: bar.x * s, y: (256 - bar.svgY - bar.h) * s, width: 10 * s, height: bar.h * s)
        bar.color.setFill()
        NSBezierPath(roundedRect: r, xRadius: 5 * s, yRadius: 5 * s).fill()
    }
    NSGraphicsContext.current?.restoreGraphicsState()
    return image
}

// ---- Hero composition ----
// 1.6x keeps the 1200x360 logical layout crisp (1920x576 px, ~2.3x at the
// README's display width) while keeping the file lean.
let scale: CGFloat = 1.6
let W: CGFloat = 1200 * scale
let H: CGFloat = 360 * scale

// All layout values below are LOGICAL (1200x360); multiplied by `scale` here so
// text, icon, and accents share one coordinate space.
func text(_ string: String, sizeL: CGFloat, weight: NSFont.Weight, color: NSColor, kern: CGFloat = 0, xL: CGFloat, topYL: CGFloat) {
    let s = NSAttributedString(string: string, attributes: [
        .font: NSFont.systemFont(ofSize: sizeL * scale, weight: weight),
        .foregroundColor: color,
        .kern: kern * scale,
    ])
    let h = s.size().height
    s.draw(at: NSPoint(x: xL * scale, y: H - topYL * scale - h))
}

// Draw into an explicit bitmap (not NSImage.lockFocus) so the output pixel
// size is deterministic, not multiplied by the screen's backing scale.
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
), let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
    FileHandle.standardError.write("bitmap context failed\n".data(using: .utf8)!); exit(1)
}
rep.size = NSSize(width: W, height: H)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx
let bounds = NSRect(x: 0, y: 0, width: W, height: H)

// Rounded-card clip: corners stay transparent so it floats on either GitHub theme.
let card = NSBezierPath(roundedRect: bounds, xRadius: 28 * scale, yRadius: 28 * scale)
card.addClip()

// Dark canvas.
canvasDark.setFill()
bounds.fill()

// One soft teal glow behind the icon (the focal point), plus a whisper of
// depth top-right. Kept low so the canvas stays clean, not muddy.
func glow(centerX: CGFloat, centerY: CGFloat, radius: CGFloat, alpha: CGFloat) {
    let c = NSPoint(x: centerX, y: centerY)
    if let g = NSGradient(colors: [
        signal600.withAlphaComponent(alpha),
        signal600.withAlphaComponent(0),
    ]) {
        g.draw(fromCenter: c, radius: 0, toCenter: c, radius: radius, options: [])
    }
}
glow(centerX: 168 * scale, centerY: H * 0.5, radius: 460 * scale, alpha: 0.18)
glow(centerX: 1120 * scale, centerY: H * 0.18, radius: 360 * scale, alpha: 0.05)

// Icon, left, vertically centered, lifted off the dark canvas with a soft shadow.
let iconSize: CGFloat = 200 * scale
let iconX: CGFloat = 72 * scale
let iconY: CGFloat = (H - iconSize) / 2
let iconRect = NSRect(x: iconX, y: iconY, width: iconSize, height: iconSize)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.50)
shadow.shadowBlurRadius = 34 * scale
shadow.shadowOffset = NSSize(width: 0, height: -10 * scale)
shadow.set()
renderIcon(size: iconSize).draw(in: iconRect)
NSGraphicsContext.restoreGraphicsState()

// Text block, right of the icon (logical coords: icon 72 + 200 + 64 gap).
let textXL: CGFloat = 72 + 200 + 64
text("MACOS MENU-BAR APP", sizeL: 15, weight: .semibold, color: signal500, kern: 2.6, xL: textXL, topYL: 100)
text("meeting-pipe", sizeL: 54, weight: .bold, color: fgLight, xL: textXL, topYL: 124)

// Teal accent underline between the wordmark and the tagline.
signal600.setFill()
NSBezierPath(roundedRect: NSRect(x: textXL * scale, y: H - (202 * scale) - 5 * scale, width: 84 * scale, height: 5 * scale),
             xRadius: 2.5 * scale, yRadius: 2.5 * scale).fill()

text("On-device meeting capture, transcribe and", sizeL: 19, weight: .regular, color: fgMuted, xL: textXL, topYL: 228)
text("summarize without the cloud.", sizeL: 19, weight: .regular, color: fgMuted, xL: textXL, topYL: 256)

NSGraphicsContext.restoreGraphicsState()

// Write PNG.
guard let data = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("png encode failed\n".data(using: .utf8)!); exit(1)
}
try data.write(to: outURL)
print("Wrote \(outURL.path) (\(Int(W))x\(Int(H)))")
