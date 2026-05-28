import AppKit

/// Toggles `NSApp.activationPolicy` between `.accessory` (no Dock icon) and `.regular` (Dock + Cmd+Tab) based on visible window count. Without this, Cmd+Tab away from the Library or Preferences window leaves no path back. Call sites: `LibraryWindow.show()` / `PreferencesWindow.show()` on open; `windowWillClose` delegates on close. Threading: main queue only.
final class WindowActivationManager {
    static let shared = WindowActivationManager()

    private var visibleCount: Int = 0

    private init() {}

    /// Increment visible-window count; raise to `.regular` on the first open. `activate(ignoringOtherApps: true)` is required: without it the first Library window open can land behind the previously-focused app.
    func didShowWindow() {
        visibleCount += 1
        if visibleCount == 1 {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Decrement visible-window count; drop back to `.accessory` when the last window closes.
    func didCloseWindow() {
        visibleCount = max(0, visibleCount - 1)
        if visibleCount == 0 {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
