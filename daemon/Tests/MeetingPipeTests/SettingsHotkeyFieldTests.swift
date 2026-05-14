import XCTest
@testable import MeetingPipe

/// SettingsHotkeyField (TECH-E6) ships two responsibilities worth pinning
/// in tests: rendering a canonical "ctrl+option+m" string into the macOS
/// glyph sequence the user actually sees, and surviving inputs that
/// don't conform (so a hand-edited TOML chord doesn't crash the UI).
final class SettingsHotkeyFieldTests: XCTestCase {

    func test_renderGlyphs_renders_all_four_modifiers_and_letter() {
        // ⌃⌥⇧⌘ + uppercase letter, in macOS canonical order.
        XCTAssertEqual(
            SettingsHotkeyField.renderGlyphs("ctrl+option+shift+cmd+z"),
            "\u{2303}\u{2325}\u{21E7}\u{2318}Z"
        )
    }

    func test_renderGlyphs_handles_synonyms() {
        // alt → ⌥, control → ⌃, command → ⌘.
        XCTAssertEqual(
            SettingsHotkeyField.renderGlyphs("alt+a"),
            "\u{2325}A"
        )
        XCTAssertEqual(
            SettingsHotkeyField.renderGlyphs("control+command+r"),
            "\u{2303}\u{2318}R"
        )
    }

    func test_renderGlyphs_uppercases_letter() {
        XCTAssertEqual(
            SettingsHotkeyField.renderGlyphs("ctrl+option+m"),
            "\u{2303}\u{2325}M"
        )
    }

    func test_renderGlyphs_falls_back_when_no_letter_found() {
        // A hand-edited TOML value with no letter would render as just
        // modifiers; that's confusing, so fall back to the raw string so
        // the user at least sees what's on disk.
        XCTAssertEqual(SettingsHotkeyField.renderGlyphs("ctrl+option"), "ctrl+option")
        XCTAssertEqual(SettingsHotkeyField.renderGlyphs(""), "")
    }
}
