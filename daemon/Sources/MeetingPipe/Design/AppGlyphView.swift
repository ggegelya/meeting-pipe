import AppKit

/// 24x24 glyph identifying the meeting source (`design/assets/app-glyphs/*.svg`). Unknown sources fall back to the signal-blue waveform mark. Uses hand-tuned SVGs instead of `NSWorkspace.icon(forFile:)` because real app icons (squircle vendor bitmaps) look noisy next to the Paper/Ink/Signal palette.
final class AppGlyphView: NSImageView {
    init(source: AppSource) {
        super.init(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = MPRadius.sm
        layer?.masksToBounds = true
        imageScaling = .scaleProportionallyUpOrDown
        image = Self.loadGlyph(for: source)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Glyph resolution

    /// Process-wide glyph cache keyed by filename. Re-reading the same SVG from the bundle on every library scroll was the dominant per-row main-thread cost. Threading: all access is main-thread only (NSViewRepresentable.makeNSView + AppKit); swap to NSCache if a non-main caller is added.
    nonisolated(unsafe) private static var glyphCache: [String: NSImage] = [:]

    /// Bundle-ID first (stable across localizations), display-name second (handles browsers), `_fallback.svg` last.
    private static func loadGlyph(for source: AppSource) -> NSImage? {
        let name = filename(for: source)
        if let cached = glyphCache[name] { return cached }
        if let url = Bundle.module.url(forResource: name, withExtension: "svg", subdirectory: "AppGlyphs"),
           let img = NSImage(contentsOf: url) {
            glyphCache[name] = img
            return img
        }
        // Fallback path — should always exist; if it doesn't, NSImageView
        // just renders blank, which is a graceful degradation.
        if let cached = glyphCache["_fallback"] { return cached }
        if let url = Bundle.module.url(forResource: "_fallback", withExtension: "svg", subdirectory: "AppGlyphs"),
           let img = NSImage(contentsOf: url) {
            glyphCache["_fallback"] = img
            return img
        }
        return nil
    }

    /// Maps `AppSource` to a glyph filename. Mirrors `APP_GLYPH_MAP` in `MeetingPrompt.jsx`; bundleID takes priority because displayName is the browser name for browser-detected meetings.
    private static func filename(for source: AppSource) -> String {
        switch source.bundleID {
        case "us.zoom.xos": return "zoom"
        case "com.microsoft.teams", "com.microsoft.teams2": return "teams"
        case "com.tinyspeck.slackmacgap": return "slack"
        case "com.google.meet": return "meet"
        default: break
        }
        // Browser-detected meetings expose the browser bundle ID; fall through to displayName matching.
        switch source.displayName {
        case "Zoom": return "zoom"
        case "Teams", "Microsoft Teams": return "teams"
        case "Meet", "Google Meet": return "meet"
        case "Slack", "Slack huddle": return "slack"
        default: return "_fallback"
        }
    }
}
