import AppKit

/// Whoever owns the application's menu bar. `NSApplication` satisfies it unchanged, so production
/// hands over `NSApp` and a test hands over a recording fake: whether a second install replaces the
/// menu or appends a second copy of it is then observable without an `NSApplication`.
protocol MainMenuHolder: AnyObject {
    var mainMenu: NSMenu? { get set }
}

extension NSApplication: MainMenuHolder {}

/// The app's `NSApp.mainMenu`, installed while a Dock-participating window is up and removed on the
/// way back to `.accessory` (UX48). `WindowActivationManager` owns both moments.
///
/// macOS hands every command-key event to `NSApp.mainMenu.performKeyEquivalent` before anything
/// else, so an app with no main menu has nothing to match a standard shortcut and the unhandled
/// event becomes the system beep. This app shipped `LSUIElement` with no menu at all, which is why
/// Cmd+C, Cmd+A, Cmd+X, Cmd+V, Cmd+M, Cmd+W and Cmd+, all beeped in the Library and a transcript's
/// text could not be lifted out with the keyboard.
///
/// Nothing here is bespoke: every item is a standard responder-chain action with a **nil target**,
/// so AppKit routes it to whatever is key. The Edit items reach the field editor of whichever text
/// field has focus, Minimize and Close reach the key window, and Preferences reaches `AppDelegate`,
/// which is in a menu item's responder chain where `Coordinator` is not.
///
/// Deliberately absent: the status-bar menu's own rows (Open Library, Quick Find, Manage Workflows,
/// Quit). That menu is the menu-bar-extra surface, it matches its own key equivalents while it is
/// open, and putting a second owner on the same chord is a different task's decision.
enum MainMenu {

    /// Build a fresh menu bar. Nothing here reads or writes global state, so two calls are two
    /// independent object graphs.
    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(windowMenu()))
        return main
    }

    /// Assign, never append. `NSApp.mainMenu` is a single slot, and a `showWindow` that ran twice
    /// has to leave one menu bar rather than two.
    static func install(into holder: MainMenuHolder) {
        holder.mainMenu = build()
    }

    static func remove(from holder: MainMenuHolder) {
        holder.mainMenu = nil
    }

    // MARK: - Submenus

    /// The application menu, which AppKit always draws first and labels with the app's name.
    ///
    /// Preferences is here for a second reason beyond the beep: it replaces the zero-opacity
    /// SwiftUI `Button` carrying `.keyboardShortcut(",")` that `LibraryWindow` used to hide in its
    /// background (commit `292dfe49`). A per-shortcut view-hierarchy patch cannot be repeated for
    /// Copy or Select All, since those have to reach the text under the pointer rather than a
    /// button this app owns.
    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "MeetingPipe")
        menu.addItem(item(
            "Preferences…",
            #selector(AppDelegate.openPreferencesFromMainMenu(_:)),
            ","
        ))
        return menu
    }

    /// The six standard editing actions. `undo:` and `redo:` are spelled as strings because no
    /// public Swift declaration carries them: they are implemented by `NSUndoManager` off the
    /// responder chain, which is exactly the routing a nil target asks for.
    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", NSSelectorFromString("undo:"), "z"))
        // Uppercase is how AppKit spells a Shift-carrying equivalent; the menu draws it as ⇧⌘Z.
        menu.addItem(item("Redo", NSSelectorFromString("redo:"), "Z"))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(.separator())
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        return menu
    }

    /// `performMiniaturize:` and `performClose:` rather than `miniaturize:` / `close:`, so the key
    /// window gets the same validation and the same beep-instead-of-act behaviour the title bar's
    /// yellow and red buttons get.
    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        return menu
    }

    // MARK: - Building blocks

    private static func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        // target stays nil on purpose: AppKit then walks the responder chain from the key window,
        // which is the only way one Copy item can serve every text field in the app.
        NSMenuItem(title: title, action: action, keyEquivalent: key)
    }

    /// A top-level menu bar entry is an item whose only job is to carry a submenu.
    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let holder = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        return holder
    }
}
