import AppKit

/// Flips the app's `NSApp.setActivationPolicy` based on whether any
/// daemon-owned UI window is visible.
///
/// MeetingPipe is a menu-bar accessory by default (`.accessory` →
/// no Dock icon, no Cmd+Tab presence, no Force Quit listing). That's
/// the right policy when nothing is open; the menu bar is the entire
/// surface. But when the user opens the Library or Preferences window
/// the same policy locks them out of muscle-memory window management:
/// Cmd+Tab away from the window and there's no Cmd+Tab path back, so
/// the window feels lost behind other apps.
///
/// Solution: while at least one window is visible, raise the app to
/// `.regular` (Dock icon + Cmd+Tab + Mission Control). When the last
/// window closes, drop back to `.accessory`. Call sites are the two
/// window owners (`LibraryWindow.show()` and `PreferencesWindow.show()`
/// on open, the windowWillClose delegates on close); the singleton
/// tracks the count so partial open/close sequences don't desync.
///
/// Threading: every public method must run on the main queue, same
/// contract as the rest of the daemon's UI code.
final class WindowActivationManager {
    static let shared = WindowActivationManager()

    private var visibleCount: Int = 0

    private init() {}

    /// Mark one more window as visible. Idempotent only if callers pair
    /// it correctly with `didCloseWindow` — we trust the pairing rather
    /// than tracking individual window references.
    func didShowWindow() {
        visibleCount += 1
        if visibleCount == 1 {
            // Hop into the foreground app stack so Cmd+Tab includes us
            // and the windows can take key focus reliably. Without
            // `activate(ignoringOtherApps: true)` the first show of the
            // Library window can land behind the previously-focused app.
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Mark one window as closed. When the last visible window goes
    /// away we drop back to `.accessory` so the Dock icon disappears
    /// and the app stops claiming a Cmd+Tab slot it doesn't need.
    func didCloseWindow() {
        visibleCount = max(0, visibleCount - 1)
        if visibleCount == 0 {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
