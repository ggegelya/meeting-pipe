import AppKit
import XCTest
@testable import MeetingPipe

/// Stands in for `NSApplication`, which a unit test has no business booting. The real `NSApp`
/// satisfies `MainMenuHolder` unchanged, so this pins the same assignment production performs.
private final class FakeMenuHolder: MainMenuHolder {
    var mainMenu: NSMenu?
}

/// UX48. The menu itself is the fix: with no `NSApp.mainMenu` there is nothing for macOS to match
/// a command-key event against, so every standard shortcut in the Library became the system beep.
/// None of this observes the window server, so the owner walkthrough is still the place the fix is
/// real; what these pin is the part that can silently rot, namely the selectors and the chords.
final class MainMenuTests: XCTestCase {

    private func submenu(_ title: String, in menu: NSMenu) -> NSMenu? {
        menu.items.first { $0.submenu?.title == title }?.submenu
    }

    private func itemTitled(_ title: String, in menu: NSMenu?) -> NSMenuItem? {
        menu?.items.first { $0.title == title }
    }

    // MARK: - Shape

    func test_menu_carries_app_edit_find_and_window_submenus() {
        let menu = MainMenu.build()

        XCTAssertEqual(
            menu.items.compactMap { $0.submenu?.title },
            ["MeetingPipe", "Edit", "Find", "Window"],
            "AppKit draws the first submenu as the application menu, so the order is load-bearing."
        )
        XCTAssertTrue(menu.items.allSatisfy { $0.submenu != nil },
                      "A menu bar entry exists only to carry a submenu.")
    }

    // MARK: - Edit

    /// The six standard editing actions, each pointing at the responder-chain selector AppKit
    /// already delivers to whatever is key. Getting one of these names wrong is invisible until a
    /// human presses the chord, which is the whole reason to pin them.
    func test_edit_items_target_the_standard_first_responder_selectors() {
        let edit = submenu("Edit", in: MainMenu.build())

        let expected: [(title: String, selector: String, key: String)] = [
            ("Undo", "undo:", "z"),
            ("Redo", "redo:", "Z"),
            ("Cut", "cut:", "x"),
            ("Copy", "copy:", "c"),
            ("Paste", "paste:", "v"),
            ("Select All", "selectAll:", "a")
        ]

        for row in expected {
            guard let item = itemTitled(row.title, in: edit) else {
                return XCTFail("Edit menu has no \(row.title) item")
            }
            XCTAssertEqual(item.action.map(NSStringFromSelector), row.selector, row.title)
            XCTAssertEqual(item.keyEquivalent, row.key, row.title)
            XCTAssertEqual(item.keyEquivalentModifierMask, [.command], row.title)
            XCTAssertNil(
                item.target,
                "\(row.title) has to travel the responder chain; a target pins it to one object."
            )
        }
    }

    /// Redo is the one whose chord is not simply Cmd plus its letter: AppKit reads an uppercase key
    /// equivalent as Shift-carrying, so this is ⇧⌘Z rather than a second ⌘Z that would shadow Undo.
    func test_redo_is_shift_command_z_and_does_not_shadow_undo() {
        let edit = submenu("Edit", in: MainMenu.build())
        XCTAssertEqual(itemTitled("Undo", in: edit)?.keyEquivalent, "z")
        XCTAssertEqual(itemTitled("Redo", in: edit)?.keyEquivalent, "Z")
    }

    // MARK: - Window

    func test_window_items_are_minimize_and_close_on_the_conventional_keys() {
        let window = submenu("Window", in: MainMenu.build())

        let minimize = itemTitled("Minimize", in: window)
        XCTAssertEqual(minimize?.action.map(NSStringFromSelector), "performMiniaturize:")
        XCTAssertEqual(minimize?.keyEquivalent, "m")

        let close = itemTitled("Close", in: window)
        XCTAssertEqual(close?.action.map(NSStringFromSelector), "performClose:")
        XCTAssertEqual(close?.keyEquivalent, "w")
    }

    // MARK: - App menu

    /// Cmd+, replaces the zero-opacity SwiftUI `Button` that carried `.keyboardShortcut(",")` in
    /// `LibraryWindow`'s background (292dfe49). It dispatches to the app delegate rather than to
    /// `Coordinator`, because a nil-target menu item walks the responder chain and `NSApp`'s
    /// delegate is on it while the coordinator is not.
    func test_preferences_is_command_comma_and_routes_through_the_responder_chain() {
        let app = submenu("MeetingPipe", in: MainMenu.build())
        let prefs = itemTitled("Preferences…", in: app)

        XCTAssertEqual(prefs?.keyEquivalent, ",")
        XCTAssertEqual(prefs?.keyEquivalentModifierMask, [.command])
        XCTAssertEqual(
            prefs?.action.map(NSStringFromSelector),
            NSStringFromSelector(#selector(AppDelegate.openPreferencesFromMainMenu(_:)))
        )
        XCTAssertNil(prefs?.target)
    }

    // MARK: - Find

    /// Quick Find on the main menu, added on the owner's yes during UX48's walkthrough.
    ///
    /// The point of the row is that `NSApp.mainMenu.performKeyEquivalent` cannot see an
    /// `NSStatusItem`'s menu, so the status-bar Cmd+K only ever matched while that menu was open
    /// and the chord did nothing from a MeetingPipe window. Same nil-target responder-chain route
    /// as Preferences, for the same reason: `AppDelegate` is on that chain and `Coordinator` is not.
    func test_quick_find_is_command_k_and_routes_through_the_responder_chain() {
        let find = submenu("Find", in: MainMenu.build())
        let quick = itemTitled("Quick Find…", in: find)

        XCTAssertEqual(quick?.keyEquivalent, "k")
        XCTAssertEqual(quick?.keyEquivalentModifierMask, [.command])
        XCTAssertEqual(
            quick?.action.map(NSStringFromSelector),
            NSStringFromSelector(#selector(AppDelegate.openQuickFindFromMainMenu(_:)))
        )
        XCTAssertNil(quick?.target, "A target here would bypass the responder chain the row exists to use.")
    }

    // MARK: - Collisions

    /// Two items sharing a chord means one of them silently never fires. Cheap to check now, and
    /// the only thing standing between a later addition and a shortcut that stops working.
    func test_no_two_items_claim_the_same_chord() {
        var seen: Set<String> = []
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if !item.keyEquivalent.isEmpty {
                    let chord = "\(item.keyEquivalentModifierMask.rawValue):\(item.keyEquivalent)"
                    XCTAssertTrue(seen.insert(chord).inserted, "Two items claim \(chord)")
                }
                if let sub = item.submenu { walk(sub) }
            }
        }
        walk(MainMenu.build())
    }

    // MARK: - Install / remove

    /// `NSApp.mainMenu` is one slot, and `showWindow` can run any number of times. Installing has
    /// to replace rather than append, or a second open would leave two menu bars' worth of items.
    func test_installing_twice_leaves_exactly_one_menu() {
        let holder = FakeMenuHolder()

        MainMenu.install(into: holder)
        let first = holder.mainMenu
        MainMenu.install(into: holder)

        XCTAssertEqual(holder.mainMenu?.items.count, 4)
        XCTAssertEqual(holder.mainMenu?.items.compactMap { $0.submenu?.title },
                       ["MeetingPipe", "Edit", "Find", "Window"])
        XCTAssertFalse(first === holder.mainMenu, "Each install builds a fresh menu.")
    }

    func test_remove_clears_the_menu() {
        let holder = FakeMenuHolder()

        MainMenu.install(into: holder)
        XCTAssertNotNil(holder.mainMenu)

        MainMenu.remove(from: holder)
        XCTAssertNil(holder.mainMenu)
    }

    /// Two builds are two independent object graphs, so nothing a later caller does to one menu
    /// can reach the other.
    func test_build_shares_no_state_between_calls() {
        let a = MainMenu.build()
        let b = MainMenu.build()

        XCTAssertFalse(a === b)
        XCTAssertFalse(a.items[0].submenu === b.items[0].submenu)
        XCTAssertEqual(a.items.count, b.items.count)
    }
}
