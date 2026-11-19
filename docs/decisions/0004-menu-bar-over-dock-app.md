# ADR 0004: Menu-bar app, not a dock app

| Property            | Value              |
| ------------------- | ------------------ |
| **Status**          | Accepted; amended 2026-11-19 (DOC19): the shipped app is Option C |
| **Date**            | 2026-05-18         |
| **Decision Makers** | Project owner      |
| **Technical Area**  | Surface / UX       |
| **Related Tasks**   | none (foundational)|

## Context

MeetingPipe runs continuously while the user works. The user opens it
implicitly (a meeting starts, the app detects it, recording happens) and
inspects it explicitly only for the library or a specific recording.
There is no document model and no primary window the user spends time
in. The app is a background presence that has a UI surface only for
state inspection and configuration.

## Decision Drivers

- **Always-on background presence.** A dock icon for an app the user
  does not focus on for hours at a time becomes noise; the user does
  not Cmd-Tab to it.
- **No primary document window.** Most macOS apps with a dock icon have
  a window the user lives in. MeetingPipe does not.
- **Indicator real estate matters.** The menu bar already carries
  glanceable state for many system processes; the daemon's recording
  status, mic-mute verdict, and current meeting fit naturally there.
- **Window appears on demand.** The Library and Preferences windows
  open from menu items and close when the user is done with them.
  Treating them as transient is consistent with the app's nature.

## Options Considered

### Option A: Dock app (`LSUIElement = false`)

Pros: standard macOS app surface; the user can drag files onto the dock
icon; activation via Cmd-Tab is fast. Cons: the icon is always present
in the dock even when the user is not interacting; right-click menu
duplicates state already in the menu bar; the app's "background-ness"
is misrepresented to the user.

### Option B: Menu-bar app (`LSUIElement = true`, `NSApplication.setActivationPolicy(.accessory)`)

Pros: no dock icon; the status bar item is the home; transient windows
do not pollute the dock; matches user expectations for a background
recorder. Cons: no Cmd-Tab access; the user has to know to click the
menu bar; surfacing critical errors requires notifications (which the
daemon already uses).

### Option C: Hybrid (menu bar by default, dock icon when a window is open)

Pros: best of both. Cons: `NSApp.setActivationPolicy` switches are
visible to the user as the dock icon appears and disappears; the
implementation has to track every open window and flip the policy at
the right moment; adds complexity for marginal benefit.

## Decision

**Option B.** The app launches with `LSUIElement = true` and
`NSApp.setActivationPolicy(.accessory)`. The status bar item
(`StatusBarController`) is the home. The Library window, Preferences
window, and Recording HUD are transient windows opened from the menu.

## Consequences

- The status bar item is the load-bearing surface. Icon and tooltip
  state changes are user-visible signals; the design system in
  `StatusBarController` is the place where state-to-glyph mapping
  lives.
- The Recording HUD floats over other windows (`NSWindow.level =
  .floating`) so the user can see recording status without alt-tabbing
  to MeetingPipe (there is no app to alt-tab to).
- The hotkey manager (`HotkeyManager.swift`) is the primary
  user-initiated input channel. Without a dock icon to click, the
  hotkey is the user's "summon" gesture.
- Critical errors surface as system notifications via `Notifier.swift`;
  the menu bar alone is too quiet for failure modes that need
  immediate user attention.

## Amendment 2026-11-19 (DOC19): the app is the hybrid, Option C

**What changed.** The app now does what Option C described and this ADR rejected. `WindowActivationManager` toggles `NSApp.activationPolicy` between `.accessory` (no Dock icon) and `.regular` (Dock icon, Cmd+Tab) according to which windows are open, and every Dock-participating window shows itself through `WindowActivationManager.shared.showWindow`: `LibraryWindow`, `PreferencesWindow`, `DiagnosticsWindow` and `GuideWindow`. It arrived over three tasks: UX39 (the window waits for the policy flip and is fronted by the manager, which counts windows by identity), UX48 (the main menu bar is part of the same transition, so Cmd-key shortcuts work while a window is up) and UX56 (the sequence that reaches the promotion without making the window wait).

**Whether the decision stands.** Not as written. Option B is the launch state and the resting state: the app starts as `.accessory`, the status-bar item is still the home, and with no window open there is no Dock icon. But "Option B" is no longer the decision; the shipped behaviour is Option C, and the cost this ADR named against it (tracking every open window and flipping the policy at the right moment) is the cost the project chose to pay, in one owner (`WindowActivationManager`) rather than in each window. The Consequences about the status-bar item, the floating Recording HUD, the hotkey and notifications still hold; "there is no app to alt-tab to" holds only while no window is open.
