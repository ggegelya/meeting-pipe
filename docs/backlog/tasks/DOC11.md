# DOC11: In-depth user guide: task-oriented recipes

Band origin: filed 2026-07-29 (owner follow-up to the exploratory sweep: "some training or guide how to use in depth. glossary and other things. not something overcomplicated, just simple, yet useful"). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

The doc set has an install story and a reference, and nothing in between. `docs/SETUP.md` (DOC10) takes a non-programmer from a clean Mac to the first summary and deliberately stops there. `README.md` is the operating guide in the reference sense: what the surfaces are and how the system behaves, written beside the code. Neither answers "how do I get X done with this app", and the cost of that gap is exactly what the 2026-07-29 sweep documented: the owner met the day-old Vocabulary editor (FEAT11) with no idea what it was for, the flag hotkey is opt-in-by-reading-Preferences, and the three re-verbs (Re-transcribe / Re-summarize / Reprocess) are distinct enough that the Vocabulary footer had to spend a paragraph disambiguating them inline.

Scope boundary with the out-of-scope rule, stated so nobody re-litigates it: in-app onboarding wizards and first-run tours are deferred selling machinery, but a person learning to use what they installed is the same class as DOC10's setup-ease carve-out, unblocking the user, in scope. This task ships a document plus one menu item, not onboarding machinery.

Register: the SETUP.md persona (no programming background assumed), the PRODUCT.md voice (quiet, deliberate), and the UX44 jargon rule generalized (no "ASR", no "sidecar", no config-key names in body text).

## Scope

**The guide.** `docs/GUIDE.md`, task-oriented recipes, each one screen or less: the goal in one line, the steps naming the real controls, what to expect. The v1 recipe list:

1. Recording: the detection prompt, recording manually, BYO, off-the-record, and flagging a moment.
2. Workflows: what they are, how a meeting picks one, what NDA mode really does, the context prompt and why it matters (FEAT11's "who is in the room" guidance).
3. Vocabulary: teach the transcriber your team's words, when terms apply, fixing an old meeting (seed from UX44's plain-language framing, recorded there).
4. Voices: name people, fix a wrongly attributed speaker, what the roster is, and the three re-verbs section: when Re-transcribe vs Re-summarize vs Reprocess is the one you want.
5. Finding things: search, Quick Find (Cmd+K), smart folders.
6. Ask: what it can answer, citations, what it cannot do.
7. The weekly rhythm: digests, the Facts and People rails, resolving action items.
8. Keeping it safe: backups, restore (written when STOR5 lands; the v1 guide documents only what ships), retention.
9. Hotkeys: the full list, global chords plus window shortcuts, folding in the cheat-sheet gap the sweep noted (Preferences lists only the four global ones).
10. When something looks wrong: the doctor, the Diagnostics window, when a re-transcribe fixes it.

Recipes link deeper docs instead of duplicating them (README for reference detail, SETUP.md for install); the guide never promises unshipped behavior, so sweep-filed fixes appear in it only as their tasks land.

**The entry point.** A "Guide" item in the status-bar menu beside Diagnostics, since a guide only in the repo fails the same invisibility class the sweep just filed against. Rendering options, decide at pickup and record: (a) open the markdown with the system default app (cheapest, reads as raw markdown for a non-technical user), (b) a lightweight in-app viewer window (the `DiagnosticsWindow` shell precedent; start from the summary reader's inline-markdown parsing with headers as sections), (c) pre-render to HTML at build time and open in the browser (still local, no hosting). Recommendation: (b), the smallest honest in-app reading experience; (a) is an acceptable v1 if (b) turns out heavier than it looks.

**The truth contract.** README's doc map and the repo `CLAUDE.md` orientation table gain a `GUIDE.md` row with the SETUP.md rule extended to it: a change to user-visible behaviour or surfaces updates the guide in the same commit. Without this line the guide drifts into the exact class of stale doc DOC7/DOC9 spent two sweeps cleaning up.

## Explicitly not in scope

Interactive tours, first-run wizards, coach marks, videos, or a hosted docs site (deferred selling machinery; BRAND band). Duplicating SETUP.md or README content. Auto-generating docs from code. Localization (EN only for now; the owner reads EN, and a UK translation is unfiled). Per-surface contextual help buttons throughout the app (the menu entry is the v1 affordance; sprinkle links later only where a task touches a surface anyway).

## Acceptance

`docs/GUIDE.md` exists with the ten recipe areas above, each step naming controls that exist on the current build (verified by a review pass against the running app; a recipe that names a control that does not exist is a filing-quality failure, the DOC9 lesson).

The status-bar Guide item opens it via whichever rendering option was recorded; a menu-model test pins the item's presence (the `StatusBarModel` idiom if the row is conditional, a plain assertion if not).

README's doc map and the repo `CLAUDE.md` orientation table carry the GUIDE.md row with the same-commit maintenance rule, in the same commit as the guide.

Repo dash guard green (the guide is prose; U+2014 is the easy slip). `cd daemon && swift build` and `swift test` green if Swift was touched.

Owner eyeball: open the Guide from the menu bar and follow the Vocabulary recipe end to end (add a term, Re-transcribe a meeting, see the correction) without touching any other document.
