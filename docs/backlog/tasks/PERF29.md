---
id: PERF29
title: Every Preferences and Guide open is a cold main-thread build, and the Guide reads and parses its whole document on main
category: Performance
status: partial
priority: P2
comment: Shipped 2026-11-17 (item 3): GuideDocumentCache parses the bundled guide once per process off main, GuideWindow is kept across closes. Owed: item 2 (keep the Preferences window), gated on a cold-open `window_opened` measurement from the laptop and on a visibility signal for the panes' onAppear/onDisappear hooks (see Progress).
---

# PERF29: Every Preferences and Guide open is a cold main-thread build, and the Guide reads and parses its whole document on main

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Sources: P014 and P018 in [2026-11-13-responsiveness-audit.md](../../audits/2026-11-13-responsiveness-audit.md) (both low, both "not measurable from the field pack: no event brackets a window open"). Every code claim below was re-read at HEAD `3a2da4fc` on 2026-11-13.

**Preferences rebuilds on every open (P014).** `PreferencesWindow.show` reuses `window` only while it is non-nil, and the close path clears it: `PreferencesWindowDelegate.windowWillClose` calls the closure `{ [weak self] closing in self?.window = nil; WindowActivationManager.shared.didCloseWindow(closing) }`. Every open after a close therefore builds a new `PreferencesView`, `NSHostingController` and `NSWindow` on main, and nothing is drawn until `WindowActivationManager.shared.showWindow(w)` at the end. The entry points are the menu row, Cmd+comma, the Library gear and the permission and setup deeplinks. The build cost is unmeasured.

**The Guide rebuilds and re-parses on every open (P018).** `GuideWindow.show` has the same shape (`GuideWindowDelegate` clears `window` on close), and `GuideView`'s `body` ends `.onAppear(perform: load)`. `load()` runs on main: `GuideDocument.bundledMarkdown()` (`String(contentsOf:)` of the bundled `GUIDE.md`, 63,560 bytes in `docs/GUIDE.md` at HEAD), `GuideDocument.parse`, `GuideDocument.rendered` (one `AttributedString(markdown: s, options: opts)` per paragraph, bullet, numbered item and table cell, about 264 by the audit's count), then `GuideDocument.sections`. The document column is a non-lazy stack on purpose (PERF13: the rail's mark needs every heading's offset), so the first layout covers the whole document. The bundled guide cannot change while the process runs, so all of this is repeated work after the first open.

**`LibraryWindow` is the in-repo precedent.** Its delegate closure keeps the reference (`_ = self`, "Keep the reference so re-open restores the same frame and scroll/selection state"), with `isReleasedWhenClosed = false`, so a re-open is an order-front. It suspends its watcher while hidden for the same reason the kept Preferences window needs care below.

**The trap in keeping Preferences alive.** The panes take their machine readings on appear: General `.onAppear { launchAtLogin.refresh() }`, Integrations `.onAppear { Task { await mcp.refresh() } }`, Permissions `.onAppear { refreshLocalModelMissing() }` and `.onAppear { center.startPolling() }`, Storage `.task { await stats.rescan() }` and `.onAppear { refreshLastBackup() }`, plus `.onAppear` blocks in the Pipeline pane and `VocabularyEditor`. And `daemon/CLAUDE.md` forbids caching a machine reading for a view's lifetime ("the pane re-reads on `.onAppear`, never per render", UX67). A kept window is re-shown without rebuilding its view tree, and whether SwiftUI re-fires `onAppear` on an order-front of the same hosting view is not something this spec can promise. If it does not, a kept window would show launch-at-login, permission and storage readings from the previous open.

Correction at filing: P018 reads the Guide's main-thread parse as residue of [PERF13](./PERF13.md) (done), whose commit `e04c07b0` subject says it moved the "Guide parse ... off main". PERF13's spec item 4 asked only that the inline markdown be parsed once per load instead of in `body`, and that is what shipped. So this is not a regression of PERF13; the commit subject overstates it. Also corrected from P014: the General pane's synchronous `launchctl print-disabled` (`LaunchAtLoginModel.init`; the audit timed `launchctl print-disabled` at a median 4.3 ms, n=15, on the Mac it ran on, not the work laptop) runs only when General is the pane shown, since `PreferencesSelectionState` survives a close and a plain reopen lands on the last-visited pane.

Related: [OBS7](./OBS7.md) adds `window_opened` with `cold` and `ms_to_key`, which is how this is measured; [UX100](./UX100.md) is the Library's first-open target drop; [UX56](./UX56.md) and [HYG22](./HYG22.md) touch the same window controllers; [DOC13](./DOC13.md) owns what the guide renders; [FEAT18](./FEAT18.md) asks the owner whether the in-app Guide reader stays at all.

## Scope

1. **Measure first.** Once OBS7's `window_opened` exists, record cold and warm opens of both windows on the laptop. If a cold Preferences open is under one frame's budget on that machine, item 2 is dropped and the result recorded here; item 3 stands on its own, since it removes repeated work whatever it costs.
2. **Keep the Preferences window across closes.** In `PreferencesWindow.show`'s delegate closure, keep `window` as `LibraryWindow` does instead of setting it to nil. Every `show()` then re-reads the panes' machine state explicitly (a published refresh token on the selection state, or a `refresh()` the panes observe), so no reading depends on `onAppear` re-firing. `store.reloadIfUnparsed()` stays at the top of `show()`.
3. **Parse and render the guide once, off main.** Add a process-wide cache in `GuideDocument` (blocks, rendered blocks, sections) built on a background queue the first time it is asked for. `GuideView` renders with its `blocks` empty, as it does today before `load()` runs, until the cache delivers on main, and later opens take the cached value. Keep `GuideWindow`'s window across closes the same way, so a reopen is an order-front with the reader's scroll position intact.

## Explicitly not

- The General pane's synchronous first `launchctl` read: [PERF24](./PERF24.md)'s Explicitly not and UX67 keep it on purpose (a placeholder before launchd answers is the defect UX42 removed). Seeding it from the status menu's cached value is a separate owner call, not this task.
- A `LazyVStack` for the guide: PERF13 records why the rail's mark needs every heading realized.
- Building either window hidden at launch: it moves the cost to launch, where UX54's startup rules apply, for windows most sessions never open.
- The Diagnostics window's load: already off main since PERF13.

## Acceptance

- `PreferencesWindow` test, through an internal read-only accessor for the built window (the seam this task adds; `window` is private and `show()` returns nothing today): `show()`, close, `show()` leaves the same `NSWindow` instance; a reading changed between the two opens (an injected launch-at-login status) is what the reopened pane shows.
- `GuideWindow` test through the same kind of accessor: a second `show()` after a close reuses the window.
- `GuideDocumentTests`: the cache is built off main (the build closure records `Thread.isMainThread == false`), a second request returns the cached value without re-reading the bundle (an injected reader is called once), and the rendered blocks equal today's `GuideDocument.rendered(parse(markdown))` for the bundled guide.
- PERF13's source fence in `GuideDocumentTests` (`AttributedString(markdown` does not appear in `GuideView.swift`) stays green, as do `TutorialFenceTests` (Preferences carries tutorial anchors).
- `cd daemon && swift build` and `swift test` green, N new tests named in the commit body; `bash scripts/ci-local.sh` green.
- Evidence line (after OBS7 lands): `window_opened` for Preferences and Guide shows `cold` false on every open after the first in a process.

## Owner walkthrough

1. [session] Confirm OBS7 has landed and the laptop runs a build with it (`./scripts/rebuild.sh` if not).
2. [owner] After a relaunch, open Preferences, close it, open it again; then the same for Guide… from the menu bar. Cost: under a minute.
3. [session] Read the four `window_opened` rows (`cold`, `ms_to_key`) from that day's `events.jsonl` and record them here; they decide scope item 2 and are the before-figure for the evidence line.

**Progress (2026-11-17): item 3 shipped, item 2 held.** `GuideDocumentCache` (build off main, served from memory afterwards, one build shared by concurrent askers), `GuideView` seeded from it, `GuideWindow` kept across closes with a cold-path prewarm. Tests: `GuideDocumentCacheTests` (6: off-main build, read once, shared build, equals `rendered(parse(...))`, missing-copy path, window reuse after close). Not done: item 2. Two things the spec did not list make a kept Preferences window more than a delegate-closure edit. (1) `PermissionsCenter` polling stops in the Permissions pane's `onDisappear` and `VocabularyEditor` flushes unsaved glossary edits in its `onDisappear`; a window that is only ordered out never fires either, so a kept window would poll TCC while hidden and could lose glossary edits on a later quit. (2) Re-running the six `onAppear` readings (General, Integrations, Permissions, Pipeline, Storage, VocabularyEditor) needs one published visibility flag on `PreferencesSelectionState` that each pane observes. And scope item 1 gates the whole item: it needs `window_opened` rows for a cold Preferences open from the laptop, which this session cannot produce. 
**Owner decision (2026-11-17): measure first; do not build item 2 yet.** What the owner owes: on a build that carries OBS7, relaunch, open Preferences, close it, open it again (the walkthrough's step 2), then hand over the `window_opened` rows for `window: "preferences"` (`cold` and `ms_to_key`; `python3 scripts/latency_report.py` prints their median) from that day's `events.jsonl`. If the cold `ms_to_key` is under one frame (about 16 ms), item 2 is dropped and that result recorded here. If not, a later session builds it, and must carry the two hazards above: a kept window never fires `onDisappear`, so (a) `PermissionsCenter` TCC polling, stopped in the Permissions pane's `.onDisappear { center.stopPolling() }`, would keep running while the window is hidden, and (b) `VocabularyEditor`'s `.onDisappear { glossary.flush() }` would not run on close, so unsaved glossary edits would wait for a flush that only a pane change or quit gives. The fix shape is one published visibility flag on `PreferencesSelectionState`, set by `PreferencesWindow.show()` and the delegate's close closure, that each pane observes to re-run its `onAppear` reading (General, Integrations, Permissions, Pipeline, Storage, VocabularyEditor) and, on hide, run both `onDisappear` hooks.

**Two more hazards a review of this change found (2026-11-17), for whoever builds item 2.** A kept window also never fires the hotkey field's `.onDisappear { stopCapture() }` (`PreferencesControls.swift`), so closing it while the field is capturing leaves its local key monitor installed, which swallows every keyDown app-wide and saves the next modifier+letter as the hotkey. And `GlossaryStore` reads its file only in `init`, so a kept Pipeline pane would hold stale terms across closes and its next edit would rewrite the file without terms added meanwhile from the Transcript tab (`TranscriptTab` adds through its own `GlossaryStore()`); it must reload on show. Probe result: with the window kept and closed, then shown again, neither `onDisappear` nor `onAppear` fired. Also, the Guide's view tree now stays in memory after its first open (it was freed on close).
