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
///
/// A fourth rule arrived with UX48: **the menu bar is part of the same transition.** macOS matches
/// a command-key event against `NSApp.mainMenu` before anything else, so this app's total absence
/// of one is why Cmd+C, Cmd+A and Cmd+W beeped in the Library. The menu is installed in the same
/// step that raises the policy and removed in the same step that drops it, because those are
/// exactly the moments this app does and does not own a menu bar.
///
/// UX56 sharpened rule 1 rather than reversing it: **the wait is for the policy transition, not for
/// the window.** The deferral was unconditional, so a window opened while the app was already
/// `.regular` waited too, with nothing to wait for. That is the second Preferences window opening
/// over the Library (the toolbar gear, Cmd+, from the main menu, the Vocabulary and permission
/// cross-links), and the owner's report was that it landed behind the Library rather than over it.
/// The flag below is what says whether a raise is actually in flight, so a window opened during one
/// still waits (two windows opened in the same turn are one transition, and the second must not
/// activate ahead of it) while a window opened with no raise pending is fronted in the same turn
/// that asked for it.
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

    /// True from the moment the policy is raised to `.regular` until the run-loop turn that fronts
    /// the window, which is exactly the span over which `setActivationPolicy` may not have landed
    /// yet. Any window shown inside that span waits with it: the transition is app-wide, so a
    /// second window fronting immediately would issue its `activate` against the still-accessory
    /// app, which is the Cmd+Tab MRU tail UX39 exists to prevent.
    private var policyRaiseInFlight = false

    private let effects: Effects

    init(effects: Effects = .appKit) {
        self.effects = effects
    }

    /// Open, re-front, or deminiaturize `window`, raising the app to `.regular` and installing the
    /// menu bar on the first one. Idempotent per window: calling it again for a window already
    /// counted brings that window forward without touching the count.
    ///
    /// The fronting waits a run-loop turn only while a policy raise is in flight (UX39's rule 1,
    /// narrowed by UX56). With the app already `.regular` there is no asynchronous transition to
    /// outlive, so the wait bought nothing and cost the thing it looks like it should cost: a turn
    /// in which the app the user came from can keep or reclaim focus, and on macOS 14 an activation
    /// this app asks for cooperatively rather than takes.
    func showWindow(_ window: ActivatableWindow) {
        if shown.insert(ObjectIdentifier(window)).inserted, shown.count == 1 {
            effects.setPolicy(.regular)
            effects.installMainMenu()
            policyRaiseInFlight = true
        }
        let effects = self.effects
        // One spelling for both branches, so "wait a turn" can never drift into doing something
        // different from "do it now".
        let frontAndActivate: (ActivatableWindow) -> Void = { window in
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            effects.activateApp()
        }
        guard policyRaiseInFlight else {
            frontAndActivate(window)
            return
        }
        effects.onNextRunLoopTurn { [weak self, weak window] in
            self?.policyRaiseInFlight = false
            guard let window else { return }
            frontAndActivate(window)
        }
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
