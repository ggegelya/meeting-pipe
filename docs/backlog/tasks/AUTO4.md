# AUTO4: In-app automation reference for the meetingpipe:// verbs

Band origin: filed 2026-07-29 (owner exploratory sweep, item 16: capabilities with zero discoverability). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md). P3 by the band's own definition (power-user payoff); promote on demand.

## Context

The `meetingpipe://` URL scheme is done-done and hardware-verified (AUTO1): seven verbs parse and route (`AutomationCommand.swift:13-45`: `record` with an optional `byo` flag, `stop`, `toggle`, `library`, `open?stem=&t=`, `ask?q=`, `digest`), driven today from Raycast, Stream Deck, or a Shortcuts "Open URL" action. Nothing in the app mentions any of this: zero references in any Preferences pane, and the native App Intents that would make the verbs discoverable in Shortcuts are built but blocked on a Developer ID (AUTO1, gated behind `MP_APP_INTENTS=1`). The README documents the scheme, but the app should carry its own reference for the owner who does not keep the README open.

## Scope

A read-only "Automation" group in Preferences, Advanced pane: one row per verb with the URL template, a one-line purpose, and a copy-to-clipboard button. Footer names the two consumption routes (a Shortcuts "Open URL" action today; native Shortcuts actions arrive when the app is Developer-ID signed, AUTO1/D8). The listed vocabulary must be fenced against the parser so it cannot drift: a unit test walks the listed templates through `AutomationCommand.parse` and fails on an unparseable row or an accepted verb missing from the list (the `MeetingPipeAppIntentsTests` idiom, which already pins the intents' URLs the same way).

## Explicitly not in scope

New verbs. Unblocking the native App Intents (AUTO1, gated on D8). A scripting/AppleScript surface. Moving the scheme docs out of the README (the in-app list is a reference, not the spec).

## Acceptance

The fence test described above (every listed row parses; every parser verb is listed). Copy button places the template on the pasteboard.

`cd daemon && swift build` and `swift test` green (baseline at filing: 1770). Repo dash guard green.

Owner eyeball: Preferences, Advanced, Automation lists the verbs; copying the ask template and opening it from Raycast prefills Ask (the AUTO1-verified path, now discoverable without the README).
