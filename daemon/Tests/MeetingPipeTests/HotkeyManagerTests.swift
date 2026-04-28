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
}
