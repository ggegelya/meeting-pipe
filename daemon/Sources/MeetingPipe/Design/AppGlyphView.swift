import AppKit

/// 24×24 stylized glyph that identifies the meeting source.
///
/// The design ships hand-tuned glyphs (`design/assets/app-glyphs/*.svg`) for
/// the well-known meeting apps so the prompt has a consistent visual
/// vocabulary. Unknown sources fall back to the signal-blue waveform mark.
///
/// Why not `NSWorkspace.shared.icon(forFile:)`? Real macOS app icons (Zoom,
/// Teams, etc.) are squircle bitmaps with their vendor's branding — they
/// look noisy next to the calm Paper/Ink/Signal palette. The design's
/// stylized glyphs are intentionally simpler so the prompt feels like a
/// system surface, not an alert window crammed with vendor logos.
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

    /// Process-wide cache of decoded glyphs, keyed by filename. The
    /// library list re-creates `AppGlyphView` instances every time a row
    /// scrolls back into view, and re-reading the same `zoom.svg` /
    /// `teams.svg` from the bundle (Bundle URL lookup + NSImage decode)
    /// per row was the dominant per-row main-thread cost. Loading from
    /// the cache turns the row glyph into an NSImage retain.
    ///
    /// Threading: all access happens from the main run loop. AppGlyphView
    /// is constructed by NSViewRepresentable.makeNSView (main-actor) and
    /// directly by AppKit code on main; no other reader exists today.
    /// If a non-main caller is added later, swap to an NSCache.
    nonisolated(unsafe) private static var glyphCache: [String: NSImage] = [:]

    /// Bundle-ID first (stable), display-name second (handles browsers and
    /// odd capitalizations), `_fallback.svg` last.
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

    /// Maps an `AppSource` to one of the shipped glyph filenames (without
    /// extension). Mirrors `APP_GLYPH_MAP` in the design's `MeetingPrompt.jsx`
    /// but keys on bundleID first because it survives localization and
    /// browser-detected meetings (where displayName is the browser, not
    /// the meeting app).
    private static func filename(for source: AppSource) -> String {
        switch source.bundleID {
        case "us.zoom.xos": return "zoom"
        case "com.microsoft.teams", "com.microsoft.teams2": return "teams"
        case "com.tinyspeck.slackmacgap": return "slack"
        case "com.google.meet": return "meet"
        default: break
        }
        // Browser-detected meetings expose the browser bundle ID; we can't
        // see the URL here, so fall through to displayName matching.
        switch source.displayName {
        case "Zoom": return "zoom"
        case "Teams", "Microsoft Teams": return "teams"
        case "Meet", "Google Meet": return "meet"
        case "Slack", "Slack huddle": return "slack"
        default: return "_fallback"
        }
    }
}
