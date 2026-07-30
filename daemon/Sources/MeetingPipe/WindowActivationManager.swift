import AppKit

/// The `NSWindow` surface the activation dance touches. `NSWindow` already satisfies it, so
/// production hands over the real window and a test hands over a recording fake: the counting
/// rules and the call ordering are then drivable without a window server or an `NSApplication`.
protocol ActivatableWindow: AnyObject {
    var isMiniaturized: Bool { get }
    func makeKeyAndOrderFront(_ sender: Any?)
    func deminiaturize(_ sender: Any?)
}

extension NSWindow: ActivatableWindow {}

/// Toggles `NSApp.activationPolicy` between `.accessory` (no Dock icon) and `.regular` (Dock +
/// Cmd+Tab) according to which windows are open, and owns the whole open and close sequence so the
/// participating windows cannot re-diverge on the ordering. Without the policy flip, Cmd+Tab away
/// from the Library or Preferences window leaves no path back.
///
/// Call sites: `LibraryWindow.show()`, `PreferencesWindow.show()`, `DiagnosticsWindow.show()` on
/// open; their `windowWillClose` delegates on close. The panels that stay Dock-less on purpose
/// (QuickFind, Onboarding, Correction) never call in. Threading: main queue only.
///
/// Three rules the sequence encodes (UX39):
///
/// 1. **Policy first, then front and activate one run-loop turn later.** `setActivationPolicy` is
///    processed asynchronously, so an `activate` issued in the same turn is evaluated against the
///    still-`.accessory` app: the newly-regular app is appended to the *tail* of the Cmd+Tab MRU
///    list instead of promoted to its front. The symptom was "the Library sits last in Cmd+Tab and
///    one Cmd+Tab cannot switch back to it". Each call site used to run
///    `makeKeyAndOrderFront` + `activate` itself *before* handing over, which fronted the window
///    while the app was still an accessory, so the whole dance lives here now.
/// 2. **Counting by window identity, not by a bare int.** `NSWindow.isVisible` is false for a
///    miniaturized window, so the `if !w.isVisible` guard each call site carried counted a
///    minimize-then-reopen as a fresh open while only one `windowWillClose` ever arrived. The
///    count never returned to zero and the app stayed `.regular` (Dock icon, Cmd+Tab slot) with
///    nothing on screen. A re-show of a window already tracked deminiaturizes it instead.
/// 3. **Hand activation off on the way out.** Dropping to `.accessory` while still the active app
///    leaves this app owning the menu bar with no window and no switcher entry, and the Dock icon
///    outlives the flip until something else takes over.
final class WindowActivationManager {
    static let shared = WindowActivationManager()

    /// The AppKit side effects, injected so tests can record what was called and in which order.
    struct Effects {
        var setPolicy: (NSApplication.ActivationPolicy) -> Void
        var activateApp: () -> Void
        var handOffActivation: () -> Void
        var onNextRunLoopTurn: (@escaping () -> Void) -> Void

        /// The real thing.
        ///
        /// `NSApp.activate()` is the macOS 14 replacement for the deprecated
        /// `activate(ignoringOtherApps:)`; on this app's macOS 14 floor the old flag no longer
        /// bought anything, since cooperative activation decides either way.
        ///
        /// The close handoff is `NSApp.deactivate()`, picked over the two alternatives (UX39):
        /// `yieldActivation(to:)` is documented to neither deactivate this app nor activate the
        /// other one, so it does nothing on its own and there is no MRU API to name the "other
        /// one" with; `NSApp.hide(nil)` does move focus on, but it hides *every* window this app
        /// owns, which would take the recording HUD and the detection prompt down with the
        /// Library. `deactivate()` touches no window of ours, and its worst case is a no-op that
        /// leaves the pre-UX39 behaviour, not a regression.
        static var appKit: Effects {
            Effects(
                setPolicy: { NSApp.setActivationPolicy($0) },
                activateApp: { NSApp.activate() },
                handOffActivation: { NSApp.deactivate() },
                onNextRunLoopTurn: { work in DispatchQueue.main.async(execute: work) }
            )
        }
    }

    /// The windows currently counted as open, by identity. Every participant sets
    /// `isReleasedWhenClosed = false` and fires `windowWillClose`, so an entry is always removed
    /// while its window is still alive; a window deallocated without closing would leave a stale
    /// identifier that a later allocation at the same address could match.
    private var shown: Set<ObjectIdentifier> = []
    private let effects: Effects

    init(effects: Effects = .appKit) {
        self.effects = effects
    }

    /// Open, re-front, or deminiaturize `window`, raising the app to `.regular` on the first one.
    /// Idempotent per window: calling it again for a window already counted brings that window
    /// forward without touching the count.
    func showWindow(_ window: ActivatableWindow) {
        if shown.insert(ObjectIdentifier(window)).inserted, shown.count == 1 {
            effects.setPolicy(.regular)
        }
        // Deferred so the policy transition above has landed before this app claims frontmost.
        let effects = self.effects
        effects.onNextRunLoopTurn { [weak window] in
            guard let window else { return }
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            effects.activateApp()
        }
    }

    /// Record `window` as gone; drop back to `.accessory` and hand activation on when it was the
    /// last one. A window that was never counted is ignored, so a second close notification cannot
    /// drop the policy out from under a window that is still up.
    func didCloseWindow(_ window: ActivatableWindow) {
        guard shown.remove(ObjectIdentifier(window)) != nil, shown.isEmpty else { return }
        effects.setPolicy(.accessory)
        effects.handOffActivation()
    }
}
