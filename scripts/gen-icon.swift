#!/usr/bin/env swift
// Generates AppIcon.icns from SF Symbol "waveform.circle.fill" rendered onto
// a tinted rounded-square background. Output paths are positional args:
//   ./gen-icon.swift <out.icns>
//
// We use Swift here (not sips/ImageMagick) because every macOS install ships
// with Swift + AppKit, and SF Symbols are first-class — no font installs.

import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write("usage: gen-icon.swift <out.icns>\n".data(using: .utf8)!)
    exit(2)
}
let outIcns = URL(fileURLWithPath: args[1])

func renderIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    let rect = NSRect(x: 0, y: 0, width: size, height: size)

    // Rounded-square background — Apple-style icon shape (squircle approximation).
    let cornerRadius = size * 0.225
    let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.12, green: 0.45, blue: 0.95, alpha: 1.0),  // deep blue
        NSColor(calibratedRed: 0.55, green: 0.25, blue: 0.85, alpha: 1.0),  // violet
    ])!
    gradient.draw(in: path, angle: -45)

    // SF Symbol waveform glyph centered on top.
    let glyphConfig = NSImage.SymbolConfiguration(pointSize: size * 0.55, weight: .semibold)
    if let glyph = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(glyphConfig) {
        let glyphSize = NSSize(width: size * 0.6, height: size * 0.6)
        let glyphRect = NSRect(
            x: (size - glyphSize.width) / 2,
            y: (size - glyphSize.height) / 2,
            width: glyphSize.width,
            height: glyphSize.height
        )
        // Tint the glyph white so it reads clearly on the gradient.
        NSColor.white.set()
        let tinted = NSImage(size: glyphSize, flipped: false) { r in
            glyph.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1.0)
            NSColor.white.set()
            r.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: glyphRect)
    }

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
