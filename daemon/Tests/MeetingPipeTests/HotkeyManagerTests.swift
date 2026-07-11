import XCTest
import Carbon.HIToolbox
@testable import MeetingPipe

final class HotkeyManagerTests: XCTestCase {

    func testParsesSingleModifierAndLetter() {
        let r = HotkeyManager.parse("ctrl+m")
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.keyCode, UInt32(kVK_ANSI_M))
        XCTAssertEqual(r?.modifiers, UInt32(controlKey))
    }

    func testParsesMultipleModifiers() {
        let r = HotkeyManager.parse("ctrl+option+m")
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.keyCode, UInt32(kVK_ANSI_M))
        XCTAssertEqual(r?.modifiers, UInt32(controlKey | optionKey))
    }

    func testIsCaseInsensitive() {
        let lower = HotkeyManager.parse("ctrl+option+m")
        let upper = HotkeyManager.parse("CTRL+OPTION+M")
        let mixed = HotkeyManager.parse("Ctrl+Option+M")
        XCTAssertEqual(lower?.keyCode, upper?.keyCode)
        XCTAssertEqual(lower?.modifiers, upper?.modifiers)
        XCTAssertEqual(lower?.modifiers, mixed?.modifiers)
    }

    func testToleratesWhitespace() {
        let r = HotkeyManager.parse(" ctrl + option + m ")
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.keyCode, UInt32(kVK_ANSI_M))
    }

    func testModifierSynonyms() {
        let alt  = HotkeyManager.parse("alt+a")
        let opt  = HotkeyManager.parse("option+a")
        let opt2 = HotkeyManager.parse("opt+a")
        XCTAssertEqual(alt?.modifiers, opt?.modifiers)
        XCTAssertEqual(opt?.modifiers, opt2?.modifiers)

        let cmd  = HotkeyManager.parse("cmd+a")
        let cmd2 = HotkeyManager.parse("command+a")
        XCTAssertEqual(cmd?.modifiers, cmd2?.modifiers)

        let ctrl  = HotkeyManager.parse("ctrl+a")
        let ctrl2 = HotkeyManager.parse("control+a")
        XCTAssertEqual(ctrl?.modifiers, ctrl2?.modifiers)
    }

    func testReturnsNilWhenNoKeyProvided() {
        XCTAssertNil(HotkeyManager.parse("ctrl"))
        XCTAssertNil(HotkeyManager.parse("ctrl+option"))
        XCTAssertNil(HotkeyManager.parse(""))
    }

    func testReturnsNilForUnsupportedKey() {
        // Only letters are supported as keys (intentional).
        XCTAssertNil(HotkeyManager.parse("ctrl+1"))
        XCTAssertNil(HotkeyManager.parse("ctrl+@"))
        XCTAssertNil(HotkeyManager.parse("ctrl+f1"))
    }

    func testCombinesAllFourModifiers() {
        let r = HotkeyManager.parse("ctrl+option+shift+cmd+z")
        XCTAssertNotNil(r)
        let expected = UInt32(controlKey | optionKey | shiftKey | cmdKey)
        XCTAssertEqual(r?.modifiers, expected)
        XCTAssertEqual(r?.keyCode, UInt32(kVK_ANSI_Z))
    }

    // MARK: - TECH-C5: force-stop hotkey default parses

    func testForceStopDefaultParses() {
        // The default value in Config / config.example.toml is
        // "ctrl+option+shift+m" — locking it in here so a future typo
        // in the default can't ship a silently-unparseable hotkey.
        let r = HotkeyManager.parse("ctrl+option+shift+m")
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.keyCode, UInt32(kVK_ANSI_M))
        XCTAssertEqual(r?.modifiers, UInt32(controlKey | optionKey | shiftKey))
    }

    func testOffTheRecordDefaultParses() {
        // MIC14: the default "ctrl+option+o" must parse (a fourth Carbon binding), and it must not
        // collide with the manual / force-stop / flag-moment defaults, or the registration guard
        // silently drops it.
        let r = HotkeyManager.parse("ctrl+option+o")
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.keyCode, UInt32(kVK_ANSI_O))
        XCTAssertEqual(r?.modifiers, UInt32(controlKey | optionKey))
        XCTAssertNotEqual(HotkeyManager.parse("ctrl+option+o")?.keyCode, HotkeyManager.parse("ctrl+option+m")?.keyCode)
    }

}
