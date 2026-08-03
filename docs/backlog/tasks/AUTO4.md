# AUTO4: In-app automation reference for the meetingpipe:// verbs

Band origin: filed 2026-07-29 (owner exploratory sweep, item 16: capabilities with zero discoverability). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md). Filed P3 by the band's own definition (power-user payoff) with a promote-on-demand clause; **the owner promoted it to P2 on 2026-08-03**, which is that clause firing, the same way AUTO2's did.

## Progress (2026-08-03, shipped; owner-owed eyeball)

Daemon green at **2038** tests, 9 new, from a 2029 baseline measured on this same tree before any edit (the figure this spec was filed with was two weeks stale, so the baseline was measured rather than quoted). `swift build` clean with no new warnings, `sh scripts/pre-commit` (both dash guards) clean, `python3 scripts/truth_fences.py both` clean. No Python touched.

**Eight rows, not seven.** The spec counts seven verbs, and `AutomationCommand.verb` names eight strings, because `record` and `record?byo=1` are separate verbs to the event log and separate things to copy: one starts a recording MeetingPipe will summarize, the other starts one the owner will write up themselves. Keying the fence on `verb` therefore wants a row each, and it makes the back direction exact instead of approximate.

**Where the vocabulary lives is what decides whether the fence is worth anything.** `Automation/AutomationReference.swift` is a pure list (template, the command it parses to, a one-line purpose) and `PreferencesView+Advanced.swift` renders `AutomationReference.rows` through a small `AutomationVerbRow`. A row hand-written into the view would be a second copy of the vocabulary and the fence would be pinning the wrong list, so `AutomationReferenceTests` also pins in source that the pane contains `AutomationReference.rows` and no `meetingpipe://` literal of its own, the way `SummaryLayoutTests` pins the tab underline.

**The fence, in both directions, proved to bite before being called done.** Forward: every template parses and equals the command its row declares, associated values included, so a dropped query key or a renamed verb fails rather than shipping a row that quietly does nothing (verified by mangling `meetingpipe://digest` to `digestt`: the forward test failed with the right message). Back: every case of `AutomationCommand` has a row, asserted inside an exhaustive switch with no `default`, so adding a case cannot compile until somebody opens the test file (verified by deleting the digest row: the back test failed). Around those: the row count is pinned against the command count, so a verb added on one side only also fails at runtime; the parser's three aliases (`start`, a bare `byo`, `open` as a synonym of `library`) are asserted to land on listed commands, so an alias can never be the only route to a capability; templates and verbs are asserted unique, since the template is the `ForEach` id; and every row is asserted to carry a purpose.

**What the fence deliberately does not buy**, stated in the test file rather than left as an implication: a case added to the switch arm with no matching sample in `everyCommand` would pass. Closing that last inch means giving the parser a `CaseIterable` verb enum beside `AutomationCommand.verb`, whose exact strings are the shipped event-log vocabulary (`record_byo`, `open_library`, ...). Touching those to tighten a fence by an inch was judged the wrong trade in a task scoped to add no verbs; the row-count pin plus the compile break are the practical cover.

**The templates carry the README's `<placeholder>` spelling** (`meetingpipe://open?stem=<stem>&t=<seconds>`) rather than a filled-in example, so the two lists read alike. That was measured, not assumed: `URL(string:)` percent-encodes angle brackets instead of refusing them, so the template parses, `<stem>` survives as the stem, `t=<seconds>` degrades to no seek exactly as a hand-edited link would, and the exact string the owner copies is the string the fence walks. There is no separate example that could drift from what is displayed.

**Copy is a seam, not a call site.** `AutomationReference.copyTemplate(to:)` defaults to `.general` and takes the pasteboard, so the acceptance's "Copy button places the template on the pasteboard" is pinned against a scratch pasteboard instead of overwriting whatever the owner last copied. The button confirms itself ("Copied" for 1.4 s, on a MainActor Task like `TranscriptTab`'s citation flash), because a button that writes to the clipboard and changes nothing on screen reads as broken, and this pane has no other place to say it worked.

**Copy register.** The purposes are written for the owner, not as an API reference: "Start recording, without writing the summary for you. You paste your own notes after it stops." rather than anything about BYO or flags; the `open` row says where the stem comes from ("Copy meeting ID in a meeting's menu") instead of naming a stem as if it were a known noun. The footer names the two routes in plain words and leaves the ticket ids (AUTO1/D8) in the code comment where they belong.

**Files:** `daemon/Sources/MeetingPipe/Automation/AutomationReference.swift` (new), `daemon/Sources/MeetingPipe/Preferences/PreferencesView+Advanced.swift`, `daemon/Tests/MeetingPipeTests/AutomationReferenceTests.swift` (new, 9 cases). Docs: `README.md` (a pointer to the in-app list and the fence behind it), `ARCHITECTURE.md` (the `Automation/` bullet), `daemon/CLAUDE.md` (the Automation index row), `design/ui_kits/macos_app/PreferencesWindow.jsx` (the Advanced pane recreation gains the group, with a comment naming the Swift side as the fenced one). `CONVENTIONS.md`, `docs/SETUP.md`, and `PRODUCT.md` were checked and are unaffected: no schema, event category, config key, install step, or design principle changed.

**Owner-owed:** the walkthrough below, and nothing else. Everything mechanically testable is pinned, including the pasteboard write; what is left is the rendered eyeball, which is owner-owed for any visual change in a menu-bar app a session cannot screenshot.

## Context

The `meetingpipe://` URL scheme is done-done and hardware-verified (AUTO1): seven verbs parse and route (`AutomationCommand.swift:13-45`: `record` with an optional `byo` flag, `stop`, `toggle`, `library`, `open?stem=&t=`, `ask?q=`, `digest`), driven today from Raycast, Stream Deck, or a Shortcuts "Open URL" action. Nothing in the app mentions any of this: zero references in any Preferences pane, and the native App Intents that would make the verbs discoverable in Shortcuts are built but blocked on a Developer ID (AUTO1, gated behind `MP_APP_INTENTS=1`). The README documents the scheme, but the app should carry its own reference for the owner who does not keep the README open.

## Scope

A read-only "Automation" group in Preferences, Advanced pane: one row per verb with the URL template, a one-line purpose, and a copy-to-clipboard button. Footer names the two consumption routes (a Shortcuts "Open URL" action today; native Shortcuts actions arrive when the app is Developer-ID signed, AUTO1/D8). The listed vocabulary must be fenced against the parser so it cannot drift: a unit test walks the listed templates through `AutomationCommand.parse` and fails on an unparseable row or an accepted verb missing from the list (the `MeetingPipeAppIntentsTests` idiom, which already pins the intents' URLs the same way).

## Explicitly not in scope

New verbs. Unblocking the native App Intents (AUTO1, gated on D8). A scripting/AppleScript surface. Moving the scheme docs out of the README (the in-app list is a reference, not the spec).

## Acceptance

The fence test described above (every listed row parses; every parser verb is listed). Copy button places the template on the pasteboard.

`cd daemon && swift build` and `swift test` green, 9 new tests. Repo dash guard green.

Owner eyeball: Preferences, Advanced, Automation lists the verbs; copying the ask template and opening it from Raycast prefills Ask (the AUTO1-verified path, now discoverable without the README).

## Owner walkthrough (for the session that picks this up)

Every task gated on an owner action carries one (2026-07-30 rule). Walk the owner through it step by step; the owner does not read code. Steps are tagged [owner] / [session] by who acts.

1. [session] Install the build so Preferences has the new group: `./scripts/rebuild.sh` from the repo root. A plain `swift build` is not enough to see it in the running app.
2. [owner] Open **Preferences ▸ Advanced** and scroll past Configuration and Diagnostics to **Automation**. Expect eight rows, each a `meetingpipe://` URL in a typewriter font with a plain-English line under it, and a **Copy** button on the right. The question here is only whether it reads well: is the purpose line under each URL something you would understand a month from now without opening the README, and does the group sit comfortably at the bottom of the pane rather than crowding it? Anything that reads like an API note rather than a sentence is worth saying out loud, since the copy is the whole point of the row.
3. [owner] Click **Copy** on the `meetingpipe://ask?q=<question>` row. The button should say **Copied** for about a second and then go back. If it does not change at all, say so: the confirmation is deliberate, because a copy button that does nothing visible reads as broken.
4. [owner] Paste it somewhere you can edit (a note, the Raycast bar itself) and replace `<question>` with a real question, no angle brackets, for example `what did we decide about the roster`. Spaces are fine.
5. [owner] Run that URL from Raycast. MeetingPipe should come forward, the Library should open on **Ask**, and your question should already be in the box and running. That path was verified by hand in AUTO1 on 2026-07-20; what this step checks is that the string the app just handed you is the one that works, which is the whole claim of the task.
6. [owner] Optional, and the cheapest confidence there is: click **Copy** on `meetingpipe://library` and run it the same way. It should open the Library on All Meetings.
7. [owner] Say "AUTO4 good to close" (or what is wrong); [session] moves the row and this spec into `q6-final.md` and deletes this file. Nothing is owed on the engineering side either way.
