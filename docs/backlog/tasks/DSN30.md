---
id: DSN30
title: Three `ui_kits/macos_app` recreations have fallen behind the app, and the kit's own known-lag list did not learn about it
category: Design
status: partial
priority: P2
comment: Filed 2026-08-18, reviving the DSN band for the first time since Q5; DSN16 (`q4-final.md`) is the direct precedent. **It needs a row because three tasks each deferred it to the next**: UX45 called it "pre-existing drift noticed, not fixed here", FEAT16 the same, and DOC12 declined it explicitly as mock completeness rather than false prose, so nobody has owned it since DSN16. The intent question is already answered in writing (the kit README calls these "faithful ... recreations of the shipped ... surfaces" with a per-surface Source-of-truth column, and `design/README.md` says "Pixel-faithful"), so the open decision is narrower: whether the README's four "Known lag from `<ID>`" bullets are a debt log every diverging change must append to, or a sanctioned exception list. Measured 2026-08-18: **Integrations** has 5 mock groups against 7 shipped, so 2 of UX45's 3 hold (no OpenAI group, a raw Database ID field where the app ships `NotionDatabasePicker`) while the third, the `secrets.env` caption, **was already fixed by UX45's own commit `1a4ddb6`**, and DOC12 repeated the stale three without re-checking; plus one nobody recorded, the Model Context Protocol group AUTO3 shipped **today** (`471c8cf`). **Actions menu**: 6 mock items against 11 shipped buttons, and the drift runs both ways, since the mock's "Reveal raw files" is not in the shipped menu at all. **MenuBarDropdown**: 6 rows against 11 fixed shipped rows, so **six** are missing (Open Library…, Quick Find…, Manage Workflows…, Diagnostics…, Guide…, Tutorial…), wider than the three or four reported. Scope: re-mock the three surfaces, settle what the known-lag list is for, correct the two stale notes, and say what stops the next one. Owner-gated: whether the kit gets a same-commit contract taxes every future UI task. Spec in [`tasks/DSN30.md`](./DSN30.md). **Items 1, 2 and 3 shipped 2026-08-19; item 4 is the owner's.** **Before and after, all three surfaces:** Integrations **5 to 7** groups (OpenAI and Model Context Protocol added, in the shipped order) and the Notion row is now a picker with a Fetch button rather than a raw hex field, its footer rewritten to match; the actions menu **6 to 11** items (Re-transcribe, Republish and the two FEAT16 copy rows and Copy meeting ID added, `Reveal raw files` dropped since the shipped detail menu has no such row); `MenuBarDropdown` **6 to 13** rows, adding Open Library, Quick Find, Manage Workflows, Recent meetings, Diagnostics, Guide and Tutorial in `populateMenu`'s order and separator grouping. Verified by diffing the mock labels against `SettingsGroup(`, the actions `Menu`'s `Button(` set and `populateMenu`'s `title:` set: nothing shipped is missing and nothing in the mocks is absent from the app. **Three findings the spec did not have.** The count surfaced pre-existing label drift, `Rename…` and `Edit summary…` in the mock against `Rename` and `Edit summary` shipped, and the app is right on the HIG since both act in place; four icon names I first reached for (`upload`, `clipboard`, `braces`, `hash`) are not in `Icons.jsx` and would have rendered blank, so they are real ones now and the whole kit was swept for unknown icon references (none); and `node --check` **cannot** parse JSX, so the acceptance's check is not runnable as written. Substituted a JSX tag-balance check against `HEAD` for all three files, which is the property that matters and which passes; a brace-count check disagreed and was itself wrong, choking on the apostrophe in "don't". **Item 2 took the walkthrough's stated default: the known-lag list is a debt log**, written into the kit README along with the honest answer to item 4's other half, that nothing mechanical stops the next drift and five tasks proved it. **Item 3:** UX45's row and both of DOC12's repetitions no longer claim the `secrets.env` caption is outstanding; it was fixed by UX45's own commit `1a4ddb6` and was wrong when written. Also corrected `design/README.md`'s "Pixel-faithful" overclaim in passing, as the spec allowed. No Swift, Python or test change; the diff is `design/` plus three backlog notes. Truth fences green, dash guard clean, zero dead links. **Item 4 answered 2026-08-19: no contract, the kit stays best-effort**, recorded in the kit README with its reasoning so it is not re-proposed as an oversight; the root CLAUDE.md is untouched and no UI task is taxed. The Known lag list, read as a debt log per item 2, is what keeps the drift visible and owed, and that list going unwritten across several tasks is the evidence that would reopen this. Found while writing it: this task's own item 2 answer from the previous day was rendering inside the bullet above it (no blank line, UX72's run-on class in a second shape). Fence widened and the line fixed in `671873a`. Remainder: walkthrough step 5's close word, plus step 4's optional side-by-side eyeball.
---

# DSN30: three `ui_kits/macos_app` recreations have fallen behind the app, and the kit's own known-lag list did not learn about it

Band origin: filed 2026-08-18, reviving the DSN band for the first time since Q5. DSN16 ("refresh macOS_app JSX mockups to current Library", `q4-final.md`) is the direct precedent and shipped the same class of work. Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Why this needs a row rather than a note

Two shipped tasks each recorded this drift and each said somebody else owned it. UX45's row in [`owner-verification.md`](../owner-verification.md) calls it "**Pre-existing drift noticed, not fixed here**"; FEAT16 recorded the actions-menu half the same way; and DOC12's ship note names both and declines them explicitly: "`PreferencesWindow.jsx`'s Integrations recreation is still behind the shipped pane in the three ways UX45 recorded, and `SummaryLibrary.jsx`'s actions menu is still the abbreviated DSN22 illustration FEAT16 described. Both are mock completeness rather than a false claim in prose, neither is on this list, and absorbing them here would hide how far that kit has drifted."

DOC12 was right to decline: its sweep was over prose doc-truth and this is mock completeness. But the effect of three tasks each deferring to the next is that nobody has owned it since DSN16, and it has since grown.

## The intent question is already answered, in writing

A filing could reasonably ask whether these recreations are meant to track the app at all. They are, and the kit says so twice:

- `design/ui_kits/macos_app/README.md` opens: "HTML/JSX recreations of the shipped Swift menu-bar daemon's surfaces, faithful to structure, labels, layout, and the design tokens", and later "Only `OnboardingPermissions` is still a proposed design rather than a faithful recreation of shipped code. Every other surface in this kit mirrors a surface that ships today."
- `design/README.md`'s table row calls `ui_kits/macos_app/` "Pixel-faithful recreations of the Swift/SwiftUI surfaces."

The README even carries a per-surface **Source of truth** column naming the Swift file each mock maps to, and a convention for recording exceptions: four "**Known lag from `<ID>`**" bullets (UX22, FEAT11 plus UX44, UX41, UX36). All four are still accurate; the mock still has no Vocabulary group and `MenuBarDropdown` still has no Finish setup row.

So the real question is narrower and sharper: **is the known-lag list a sanctioned parking place or a debt log, and what keeps it complete?** Every drift measured below is absent from it, so today the list is neither. That decision is what makes this closeable, and it belongs in the scope rather than being left to the pickup's taste.

## What is actually behind, measured 2026-08-18 against `b122e00`

### `PreferencesWindow.jsx`, the Integrations pane

The shipped `PreferencesView+Integrations.swift` has **seven** `SettingsGroup`s: Anthropic, OpenAI, Notion, Model Context Protocol, Obsidian, Filesystem, LAN share. The mock's `PWIntegrationsPane` has **five**: Anthropic, Notion, Obsidian, Filesystem, LAN share.

Of the three gaps UX45 recorded, **two are still true and the third is not**:

- **No OpenAI credential group** (PROV1 / UX31). Still true. The shipped group carries a secret field and a status pill, and its footer reads "Only needed for the OpenAI summarization backend."
- **A raw Database ID field where the app ships a fetched picker.** Still true. The mock has `PWField placeholder="32-char hex from your database URL"`; the shipped pane has `SettingsStackRow("Database")` wrapping `NotionDatabasePicker(databaseID: $store.notionDatabaseId, ...)` backed by `NotionDatabaseList`.
- **A caption naming `secrets.env` where SEC8 moved to the Keychain.** **Already fixed**, and fixed by UX45's own commit (`1a4ddb6`), which replaced "Credentials for outbound services. Stored in ~/.config/meeting-pipe/secrets.env (mode 0600)." with the Keychain wording that is there now. So UX45's note was wrong about its own diff, and DOC12 then repeated "the three ways UX45 recorded" without re-checking. Correct both as part of this task. **This is the defect this task exists to close, one level up**: the mocks fell behind the app, and then the notes recording that fell behind the mocks. A drift log nobody re-checks is drift with extra steps, which is why item 2 below has to decide what the known-lag list is *for* rather than only adding entries to it.

**And one nobody recorded:** the Model Context Protocol group shipped in AUTO3 (`471c8cf`) on **2026-08-18**, in the same ten-task batch that produced this filing, and the kit did not learn about it. That is the mechanism repeating in real time rather than a historical backlog.

### `SummaryLibrary.jsx`, the detail header actions menu

`SLHeaderMenu` is captioned "The header actions menu, shown open (DSN22 audit #5)" and lists six items: Rename…, Edit summary…, Reprocess…, Corrections…, Reveal raw files, Delete….

The shipped menu in `MeetingDetailView+Header.swift` has **eleven** buttons across four dividers: Rename, Edit summary, Reprocess…, Re-transcribe…, Corrections…, Republish, the two `MeetingShare.Surface` copy rows FEAT16 added, Open meta.json, Copy meeting ID, and Delete….

The drift runs **both ways**, which is the part FEAT16's "abbreviated illustration" framing understates: the mock is missing five shipped rows, and it shows one, "Reveal raw files", that the shipped detail menu does not have at all (the app's "Reveal in Finder" lives on `MeetingRow`, `DigestsView` and three Preferences panes, not here). A reviewer using the mock to reason about that menu is wrong in two directions.

### `MenuBarDropdown.jsx`

Widest gap of the three, and wider than reported. `StatusBarController.populateMenu` builds eleven fixed rows: the header, Open Library…, Quick Find…, Manage Workflows…, Open Logs Folder, Diagnostics…, Guide…, Tutorial…, Open Recordings Folder, Preferences…, Quit MeetingPipe, plus conditional rows (Recent meetings…, Finish setup, the permission consequences, failed meetings, Quit (do not relaunch)) and the transport row.

The mock has six: header, the transport row, Open Logs Folder, Open Recordings Folder, Preferences…, Quit MeetingPipe.

So **six** persistent rows are missing, not the three or four that were reported: Open Library…, Quick Find…, Manage Workflows…, Diagnostics…, Guide…, Tutorial…. Their owners are UX48, UX20, DOC11, FEAT15 and others, none of which touched the kit, and FEAT15's Tutorial… row landed on 2026-08-18. The README's Source-of-truth column names `the rebuildMenu() function` for this file, so the mapping is unambiguous and nothing about the gap is a judgement call.

## Scope

**1. Bring the three surfaces up to the shipped app**, at the kit's own stated fidelity ("structure, labels, layout, and the design tokens", not byte-identical AppKit). Integrations gains the OpenAI and Model Context Protocol groups and the Notion database picker; the actions menu gains the five missing rows and loses Reveal raw files; `MenuBarDropdown` gains the six missing rows in their shipped order and separator grouping.

**2. Settle what the known-lag list is for, and write the answer into the kit README.** Two readings, and the pickup picks one with the owner rather than leaving it ambiguous: either it is a *debt log*, in which case anything not re-mocked has to be added to it in the same commit and this task's job is to make it complete; or it is a *sanctioned exception list* for deliberate divergences, in which case ordinary lag does not belong there and something else has to keep the mocks honest. The four current entries are accurate and are not the problem; the absence of any entry for the drift above is.

**3. Correct the two stale notes** that will otherwise keep propagating: UX45's "three ways" (one is fixed, by its own commit) and DOC12's repetition of it.

**4. Say what stops the next one**, in one paragraph in the kit README, and be honest if the answer is "nothing mechanical". `docs/SETUP.md` and `docs/GUIDE.md` carry an explicit same-commit contract in the root `CLAUDE.md`; this kit carries no such rule, which is exactly why five tasks changed a surface and none updated its mock. Whether it should get one is the owner's call, since it is a cost on every UI task.

## Explicitly not / out of scope

**A same-commit contract for the kit, imposed by this task.** Proposing it is item 4; adopting it changes the root `CLAUDE.md` and taxes every future UI task, so it is the owner's decision and not a hygiene sweep's.

**`OnboardingPermissions.jsx`.** The README already labels it a proposed design rather than a recreation, so it has no shipped surface to be behind. Leave it.

**Redesigning anything.** This is fidelity work against surfaces that already shipped and were already designed. If a mock reveals that a shipped surface is bad, that is a UX row, not a kit edit.

**The four existing "Known lag" entries.** All four are still true, verified 2026-08-18. They stay unless item 2's decision retires the convention.

**Any Swift change.** The app is the source of truth here by the kit's own definition, and a mock disagreeing with it is the mock's defect.

**Observed but not filed:** `design/README.md` calls these "Pixel-faithful recreations" while the kit's own README says "faithful to structure, labels, and tokens (not byte-identical to AppKit)". Those are two different promises and the second is the honest one. Fix the first in passing if this task touches `design/README.md`; it is not worth its own row.

## Acceptance

- For each of the three surfaces, every row, group or field the shipped Swift renders is present in the mock, and nothing the mock shows is absent from the app. Checkable by listing `SettingsGroup(` in `PreferencesView+Integrations.swift`, the `Button` set in `MeetingDetailView+Header.swift`'s actions `Menu`, and the `NSMenuItem(title:` set in `StatusBarController.populateMenu`, against the mock's own labels. The ship note carries all three before-and-after counts.
- The Notion row is a picker rather than a free-text hex field, matching `NotionDatabasePicker`.
- The kit README's Source-of-truth table still names a real Swift symbol for every component, and the mapping for the three touched files is re-checked rather than assumed.
- The kit README states what the known-lag list is for, and its contents match that statement.
- UX45's row and DOC12's ship note no longer claim the `secrets.env` caption is outstanding.
- `index.html` still composes without error and every touched `.jsx` parses: `node --check` on each changed file, matching the check `/spike` requires of JS.
- No Swift, Python, or test change. The diff touches `design/` plus the two backlog notes in item 3.
- `python3 scripts/truth_fences.py both` green.
- No em-dashes in changed lines.

## Progress, 2026-08-19: item 4 answered, no contract

**Owner decision 2026-08-19: the kit stays best-effort.** Walkthrough step 3 answered directly, so no same-commit contract is imposed and the root `CLAUDE.md` is untouched. Recorded in the kit README as a decision with its reasoning, not as a bare no, because item 4's own wording asks that a no be written down so the next session does not re-propose it.

The reasoning is in the README rather than summarised twice, but the load-bearing half is worth having here too: the contract that `docs/SETUP.md` and `docs/GUIDE.md` carry protects documents a **person reads**, where a stale sentence misleads directly. A lagging mock is a stale reference that gets checked against the running app before it is trusted, and updating one faithfully needs a rendered eyeball a session does not have. So the "Known lag" list, read as a debt log per item 2, is what keeps the drift visible and owed, and the condition that would reopen this is that list going unwritten across several tasks the way the mocks did.

**One real defect found while writing that paragraph, and fixed.** The item 2 answer this task added the previous day sat directly under a list item with no blank line between them, so markdown was rendering the whole paragraph **inside** the `OnboardingPermissions` bullet above it. That is UX72's run-on class in a second shape, it was invisible in the diff that introduced it, and HYG8's new `links` fence did not catch it because the first version of that check matched only `**[DONE]` lines. The fence was widened to the general shape (measured: exactly one hit across 231 files, which was this one) and the blank line added, both in `671873a`. Worth carrying: this task's own output was the counterexample to the fence shipped an hour earlier.

## Owner walkthrough (for the session that picks this up)

Per the 2026-07-30 standing rule. Steps are tagged [owner] / [session] by who acts.

Item 1 is mechanically checkable and needs nobody. Items 2 and 4 are the owner's, because both are decisions about what future tasks are required to do.

1. [session] Do item 1 and item 3, and report the before-and-after counts for all three surfaces.
2. [owner] Item 2: say whether "Known lag" is a debt log that every diverging change must append to, or a list of deliberate exceptions. If you have no preference, the session takes debt log, since that is how the four existing entries read.
3. [owner] Item 4: say whether the kit gets a same-commit contract like `docs/SETUP.md` and `docs/GUIDE.md` have, or stays best-effort. A no is a real answer and gets recorded in the README as one, so the next session does not re-propose it.
4. [owner] Optional, and only if you want the eyeball: open `design/ui_kits/macos_app/index.html` in a browser beside the running app and compare the menu bar dropdown. The other two surfaces are in windows the kit draws with its own chrome, so a side-by-side there compares less cleanly.
5. [owner] Say "DSN30 good to close" (or what is wrong); [session] moves the row and this spec into `q6-final.md` and deletes this file.
