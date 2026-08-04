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
/// Call sites: `LibraryWindow.show()`, `PreferencesWindow.show()`, `DiagnosticsWindow.show()`,
/// `GuideWindow.show()` on open; their `windowWillClose` delegates on close. The panels that stay
/// Dock-less on purpose (QuickFind, Onboarding, Correction) never call in. Threading: main queue
/// only.
///
/// Three rules the sequence encodes (UX39):
///
/// 1. **Policy first, and the activation re-issued once the transition has landed.**
///    `setActivationPolicy` is processed asynchronously, so an `activate` issued in the same turn
///    can still be evaluated against the `.accessory` app: the newly-regular app is appended to the
///    *tail* of the Cmd+Tab MRU list instead of promoted to its front. The symptom was "the Library
///    sits last in Cmd+Tab and one Cmd+Tab cannot switch back to it". Each call site used to run
///    `makeKeyAndOrderFront` + `activate` itself *before* handing over, so the app asked to be
///    frontmost before it had asked to be regular; the raise comes first now, and the follow-up
///    activation a run-loop turn later is what covers an attempt evaluated too early.
/// 2. **Counting by window identity, not by a bare int.** `NSWindow.isVisible` is false for a
///    miniaturized window, so the `if !w.isVisible` guard each call site carried counted a
///    minimize-then-reopen as a fresh open while only one `windowWillClose` ever arrived. The
///    count never returned to zero and the app stayed `.regular` (Dock icon, Cmd+Tab slot) with
///    nothing on screen. A re-show of a window already tracked deminiaturizes it instead.
/// 3. **Hand activation off on the way out.** Dropping to `.accessory` while still the active app
///    leaves this app owning the menu bar with no window and no switcher entry, and the Dock icon
///    outlives the flip until something else takes over.
///
/// A fourth rule arrived with UX48: **the menu bar is part of the same transition.** macOS matches
/// a command-key event against `NSApp.mainMenu` before anything else, so this app's total absence
/// of one is why Cmd+C, Cmd+A and Cmd+W beeped in the Library. The menu is installed in the same
/// step that raises the policy and removed in the same step that drops it, because those are
/// exactly the moments this app does and does not own a menu bar.
///
/// UX56 is where the *shape* of rule 1 changed, in two passes, and the second pass is the one that
/// matters. UX39 made the window **wait** for the transition. A wait is not free: it hands the app
/// the user came from a run-loop turn in which to keep or reclaim focus, and on the macOS 14 floor
/// this app asks for activation cooperatively rather than taking it. The owner walked both paths on
/// 2026-08-04, and they came out opposite ways. A window opened while the app was already `.regular`
/// (the Library toolbar's gear, Cmd+, from the main menu, the Vocabulary and permission
/// cross-links) waited for nothing, and once the first pass stopped making it wait, it came up in
/// front and at the **head** of the switcher. The window that still waited came up **behind** the
/// frontmost app and put this app at the Cmd+Tab **tail**: the wait was paying its cost and not
/// buying the MRU position it exists to buy. That is every open from the status-bar menu with
/// nothing else up, since the last close drops the policy back to `.accessory` and so every one of
/// them is a first-window open.
///
/// So nothing waits. Every window is fronted and activated in the turn that asked for it, which is
/// the turn the user's click is still in, and a policy raise additionally queues **one** activation
/// for the turn after, by which point the transition has certainly landed. On an app that is
/// already frontmost that second call is a no-op; on one whose first attempt was evaluated against
/// the still-accessory app it is the promotion UX39 wanted, so rule 1's guarantee is kept as a
/// retry instead of as a wait. It is queued per transition and not per window, which is what keeps
/// two windows opened in the same turn fronting in the order they were asked for, second on top.
final class WindowActivationManager {
    static let shared = WindowActivationManager()

    /// The AppKit side effects, injected so tests can record what was called and in which order.
    struct Effects {
        var setPolicy: (NSApplication.ActivationPolicy) -> Void
        var activateApp: () -> Void
        var handOffActivation: () -> Void
        var installMainMenu: () -> Void
        var removeMainMenu: () -> Void
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
        ///
        /// The menu pair is UX48: `MainMenu` is the whole menu bar, and `NSApp.mainMenu` is a
        /// single slot, so installing is an assignment and removing is a nil.
        static var appKit: Effects {
            Effects(
                setPolicy: { NSApp.setActivationPolicy($0) },
                activateApp: { NSApp.activate() },
                handOffActivation: { NSApp.deactivate() },
                installMainMenu: { MainMenu.install(into: NSApp) },
                removeMainMenu: { MainMenu.remove(from: NSApp) },
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

    /// Open, re-front, or deminiaturize `window`, raising the app to `.regular` and installing the
    /// menu bar on the first one. Idempotent per window: calling it again for a window already
    /// counted brings that window forward without touching the count.
    ///
    /// The fronting is never deferred (UX39's rule 1, reshaped by UX56): a window the user just
    /// asked for goes up in the turn they asked for it, which is the turn their click is still in.
    /// The asynchronous policy raise is covered by the single follow-up activation queued beside
    /// it, not by making the window wait for it.
    func showWindow(_ window: ActivatableWindow) {
        if shown.insert(ObjectIdentifier(window)).inserted, shown.count == 1 {
            effects.setPolicy(.regular)
            effects.installMainMenu()
            // Queued here rather than beside each window's fronting, so it is one retry per
            // transition however many windows open in this turn, and it runs after all of them.
            // The local copy is what keeps `self` out of the escaping closure; `Effects` is a value.
            let effects = self.effects
            effects.onNextRunLoopTurn { effects.activateApp() }
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        effects.activateApp()
    }

    /// Record `window` as gone; drop back to `.accessory`, take the menu bar down, and hand
    /// activation on when it was the last one. A window that was never counted is ignored, so a
    /// second close notification cannot drop the policy out from under a window that is still up.
    func didCloseWindow(_ window: ActivatableWindow) {
        guard shown.remove(ObjectIdentifier(window)) != nil, shown.isEmpty else { return }
        effects.setPolicy(.accessory)
        // Before the handoff, so the outgoing app is never the one whose menu bar is drawn.
        effects.removeMainMenu()
        effects.handOffActivation()
    }
}
