# ADR 0004: Menu-bar app, not a dock app

| Property            | Value              |
| ------------------- | ------------------ |
| **Status**          | Accepted           |
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
