import AppKit
import XCTest
@testable import MeetingPipe

/// Pins the source-to-glyph mapping the HUD (TECH-UX6) and the library row both rely on.
/// The HUD builds `AppGlyphView(source:)` for the recording app and falls back to the
/// waveform mark when there is no source; this asserts the filename resolution that drives
/// which glyph the HUD shows during a call.
final class AppGlyphViewTests: XCTestCase {

    private func source(_ bundleID: String, _ displayName: String, _ kind: AppSourceKind = .native) -> AppSource {
        AppSource(bundleID: bundleID, displayName: displayName, kind: kind)
    }

    func test_native_bundle_ids_map_to_their_glyph() {
        XCTAssertEqual(AppGlyphView.filename(for: source("us.zoom.xos", "Zoom")), "zoom")
        XCTAssertEqual(AppGlyphView.filename(for: source("com.microsoft.teams", "Microsoft Teams")), "teams")
        XCTAssertEqual(AppGlyphView.filename(for: source("com.microsoft.teams2", "Microsoft Teams")), "teams")
        XCTAssertEqual(AppGlyphView.filename(for: source("com.tinyspeck.slackmacgap", "Slack")), "slack")
        XCTAssertEqual(AppGlyphView.filename(for: source("com.google.meet", "Meet")), "meet")
    }

    func test_browser_sources_fall_through_to_display_name() {
        // Browser-detected meetings expose the browser bundle id, so resolution falls to displayName.
        XCTAssertEqual(AppGlyphView.filename(for: source("com.google.Chrome", "Google Meet", .browser)), "meet")
        XCTAssertEqual(AppGlyphView.filename(for: source("company.thebrowser.Browser", "Meet", .browser)), "meet")
        XCTAssertEqual(AppGlyphView.filename(for: source("com.google.Chrome", "Zoom", .browser)), "zoom")
        XCTAssertEqual(AppGlyphView.filename(for: source("com.tinyspeck.slackmacgap", "Slack huddle")), "slack")
    }

    func test_unknown_source_uses_fallback() {
        XCTAssertEqual(AppGlyphView.filename(for: source("com.unknown.app", "Mystery App")), "_fallback")
    }

    func test_bundle_id_wins_over_display_name() {
        // A Zoom bundle id with a stale browser-style displayName still resolves to zoom.
        XCTAssertEqual(AppGlyphView.filename(for: source("us.zoom.xos", "Chrome")), "zoom")
    }

    // Regression (glyph bundling): the filename mapping above is only half the
    // contract - the file must also resolve from the resource bundle. `.process`
    // flattens resources to the bundle root, so the old `subdirectory: "AppGlyphs"`
    // lookup returned nil and rendered every glyph blank on the prompt, HUD, and
    // library rows. These load through the real bundle so the regression can't return.
    func test_known_source_actually_loads_its_glyph_from_the_bundle() {
        let view = AppGlyphView(source: source("com.microsoft.teams", "Microsoft Teams"))
        XCTAssertNotNil(view.image, "Teams glyph should resolve and load from the resource bundle")
    }

    func test_unknown_source_loads_the_fallback_glyph_from_the_bundle() {
        let view = AppGlyphView(source: source("com.unknown.app", "Mystery App"))
        XCTAssertNotNil(view.image, "Unknown source should fall back to _fallback.svg from the bundle")
    }
}
