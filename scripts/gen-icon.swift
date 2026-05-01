#!/usr/bin/env swift
// Generates AppIcon.icns by re-rendering design/assets/app-icon.svg as a
// pure-Swift AppKit drawing. Output path is positional:
//   ./gen-icon.swift <out.icns>
//
// We use Swift here (not librsvg / Inkscape / sips on the SVG) because every
// macOS install ships with Swift + AppKit, so the installer needs zero extra
// dependencies. The shapes below mirror the SVG one-for-one — when the design
// SVG changes, mirror the change here. The design tokens (#FBFAF7 paper,
// #2667F0 signal600, #14161A ink900, etc.) are duplicated rather than imported
// from the daemon target so this script can run standalone.

import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write("usage: gen-icon.swift <out.icns>\n".data(using: .utf8)!)
    exit(2)
}
let outIcns = URL(fileURLWithPath: args[1])

// Design tokens (duplicated from design/colors_and_type.css).
let paperTop    = NSColor(srgbRed: 1.0,        green: 1.0,        blue: 1.0,        alpha: 1)
let paperBottom = NSColor(srgbRed: 0xF4/255.0, green: 0xF2/255.0, blue: 0xEC/255.0, alpha: 1)
let ink900      = NSColor(srgbRed: 0x14/255.0, green: 0x16/255.0, blue: 0x1A/255.0, alpha: 1)
let signal600   = NSColor(srgbRed: 0x26/255.0, green: 0x67/255.0, blue: 0xF0/255.0, alpha: 1)
let hairline    = NSColor(srgbRed: 0x14/255.0, green: 0x16/255.0, blue: 0x1A/255.0, alpha: 0.10)

func renderIcon(size: CGFloat) -> NSImage {
    // SVG viewBox is 256×256; scale every coordinate by `s`.
    let s = size / 256.0

    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    let bounds = NSRect(x: 0, y: 0, width: size, height: size)

    // Squircle clip — same control points as the SVG path.
    let cp = bounds.width   // 256s
    let squircle = NSBezierPath()
    squircle.move(to: NSPoint(x: cp * 0.5, y: cp))                // 128, 256 (top)
    squircle.curve(to: NSPoint(x: cp, y: cp * 0.5),               // 256, 128 (right)
                   controlPoint1: NSPoint(x: cp * 0.78, y: cp),
                   controlPoint2: NSPoint(x: cp,        y: cp * 0.78))
    squircle.curve(to: NSPoint(x: cp * 0.5, y: 0),                // 128, 0   (bottom)
                   controlPoint1: NSPoint(x: cp,        y: cp * 0.22),
                   controlPoint2: NSPoint(x: cp * 0.78, y: 0))
    squircle.curve(to: NSPoint(x: 0, y: cp * 0.5),                // 0, 128   (left)
                   controlPoint1: NSPoint(x: cp * 0.22, y: 0),
                   controlPoint2: NSPoint(x: 0,         y: cp * 0.22))
    squircle.curve(to: NSPoint(x: cp * 0.5, y: cp),               // 128, 256
                   controlPoint1: NSPoint(x: 0,         y: cp * 0.78),
                   controlPoint2: NSPoint(x: cp * 0.22, y: cp))
    squircle.close()

    NSGraphicsContext.current?.saveGraphicsState()
    squircle.addClip()

    // Paper gradient — top-to-bottom, white -> #F4F2EC.
    if let gradient = NSGradient(colors: [paperTop, paperBottom]) {
        gradient.draw(in: bounds, angle: -90)
    } else {
        paperTop.setFill()
        bounds.fill()
    }

    // Hairline border just inside the squircle edge.
    hairline.setStroke()
    let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5 * s, dy: 0.5 * s),
                             xRadius: 56 * s, yRadius: 56 * s)
    edge.lineWidth = 1 * s
    edge.stroke()

    // Frame ("screen"): x=40 y=92 w=176 h=80 rx=28 stroke=ink900 width=6.
    // SVG y=92 means 92pt from the top. AppKit is bottom-up: y' = 256 - 92 - 80.
    let frameRect = NSRect(x: 40 * s, y: (256 - 92 - 80) * s,
                            width: 176 * s, height: 80 * s)
    let frame = NSBezierPath(roundedRect: frameRect, xRadius: 28 * s, yRadius: 28 * s)
    ink900.setStroke()
    frame.lineWidth = 6 * s
    frame.stroke()

    // 7 waveform bars. SVG: each x stride = 20pt, w=10, rx=5, vary y/h.
    // Heights symmetric: 20, 40, 64, 84 (signal), 64, 40, 20.
    // Center bar (index 3) uses signal600; others ink900.
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
        let r = NSRect(
            x: bar.x * s,
            y: (256 - bar.svgY - bar.h) * s,    // SVG -> AppKit y-flip
            width: 10 * s,
            height: bar.h * s
        )
        bar.color.setFill()
        NSBezierPath(roundedRect: r, xRadius: 5 * s, yRadius: 5 * s).fill()
    }

    NSGraphicsContext.current?.restoreGraphicsState()
    return image
}

func writePNG(_ image: NSImage, size: CGFloat, to url: URL) throws {
    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        throw NSError(domain: "gen-icon", code: 1)
    }
    let bitmap = NSBitmapImageRep(cgImage: cgImage)
    bitmap.size = NSSize(width: size, height: size)
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "gen-icon", code: 2)
    }
    try data.write(to: url)
}

// Build an .iconset directory, then iconutil produces the .icns.
let iconsetDir = outIcns.deletingPathExtension().appendingPathExtension("iconset")
try? FileManager.default.removeItem(at: iconsetDir)
try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

// Apple's required sizes for a complete iconset.
let sizes: [(filename: String, pixels: CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for (filename, pixels) in sizes {
    let img = renderIcon(size: pixels)
    let url = iconsetDir.appendingPathComponent(filename)
    try writePNG(img, size: pixels, to: url)
}

// iconutil -c icns <iconset> -o <icns>
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconsetDir.path, "-o", outIcns.path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil failed (\(task.terminationStatus))\n".data(using: .utf8)!)
    exit(Int32(task.terminationStatus))
}

// Cleanup intermediate iconset.
try? FileManager.default.removeItem(at: iconsetDir)
print("Wrote \(outIcns.path)")
