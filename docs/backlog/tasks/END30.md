---
id: END30
title: Zoom's end-side window reading matches any Zoom window, so the main Zoom window keeps a finished call's window present and can mask a minimised one; give Zoom END24's window identity
category: Detection
status: partial
priority: P2
comment: Shipped 2026-11-17: one shared, permissive Zoom call-window recognizer (MeetingTitlePatterns.zoomWindow rejects the launcher, main window, account window, dialogs and chrome), zoomWindowShape and zoomLockRank (a "Zoom Meeting" title first); NativeLifecycleConfig.zoom runs END24's identity mode; the scanner calls the same predicate; window_titles.json Zoom rows carry shapes plus Workplace, account, settings, webinar and localised rows, with a cross-side agreement test. Remainder: real Zoom captures, including a screen share and a breakout (rows stay seeded, as VALOWN1 is for Teams). Nothing else owed; the owner closes it.
---

# END30: Zoom's end-side window reading matches any Zoom window, so the main Zoom window keeps a finished call's window present and can mask a minimised one; give Zoom END24's window identity

Band origin: filed 2026-11-16 (group A's end-engine batch, at the owner's request after the minimised-window analysis for [END21](./END21.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

[END24](./END24.md) (2026-11-16) fixed the Teams window reading by identity: `ShareableContentSignal.start(context:lockRank:titleMatch:)` with a non-nil `lockRank` locks the call window's SCWindow id at the first present reading (ranked by `MeetingTitlePatterns.teamsLockRank`, so the main window's `Chat |` shape is not followed) and from then on reads present only while that id is listed. `NativeLifecycleConfig.teams` passes `windowLockRank: MeetingTitlePatterns.teamsLockRank`; every other native config passes nil and stays on the title rule.

Zoom stayed on the title rule, and its title rule is loose. `MeetingTitlePatterns.zoom` matches any title containing one of `zoomTokens`: `"zoom meeting"`, `"zoom -"`, `"reunion zoom"`, `"zoom"`. The last token matches every Zoom window, including the main "Zoom Workplace" window that stays open all day. Two consequences, both code-derived on 2026-11-16 with no field incident filed:

1. **After a leave the window can keep reading present.** When the meeting window closes, any other Zoom window on screen still matches, so `ShareableContentSignal` emits no window-gone. The end then rests on the mic release (`processAudioIsRunningInput`, which Zoom publishes since DET8, unmeasured for Zoom per [DET24](./DET24.md)) and the Leave button, so the pair still forms, but one of its three readings is blind.
2. **A minimised meeting window is masked, or read as gone, depending on what else is open.** `ShareableContentSignal` lists on-screen windows only (`onScreenWindowsOnly: true`), so a minimised call window or one on another Space reads gone under Teams' identity mode. Under Zoom's title rule the reading depends on whether another Zoom window happens to be on screen, so it is noise rather than a fact about the call. The owner's minimised-window question of 2026-11-16 is what surfaced it.

## Scope

1. **A Zoom call-window recognizer and lock rank in `MeetingTitlePatterns`**, the way END24 did `teamsWindow` and `teamsLockRank`: the meeting window ranks first, the main Workplace window and other chrome rank last or are rejected. The start side (`MeetingSourceScanner.isActiveMeetingWindow` for Zoom) and the end side share it, so they cannot disagree (END24's lesson).
2. **`NativeLifecycleConfig.zoom` passes `windowLockRank`**, so the Zoom window signal runs in END24's identity mode with no change to `ShareableContentSignal` itself.
3. **Fixture rows.** `daemon/Tests/MeetingPipeTests/Fixtures/window_titles.json` gains Zoom rows with END24's `kind` and `shape` columns (meeting window, Workplace main window, Chat, Settings, a mini or floating meeting bar if Zoom has one), seeded until real captures exist, and `WindowRecognizerFixtureTests` gains a cross-side agreement test for Zoom like Teams'.

## Explicitly not

- Real Zoom window captures: the titles are seeded until the owner captures them (as VALOWN1 does for Teams); the fixture test reports seeded rows rather than asserting them as truth.
- Webex and Slack: their matchers have the same looseness ("webex" token, Slack's huddle word). File separately if wanted.
- Zoom's process-audio reading: [DET24](./DET24.md)'s spike.

## Acceptance

- `ShareableContentSignalTests` (or a Zoom-specific suite) for Zoom in identity mode: the meeting window locked at the first present reading; removing it reads gone even while the Workplace main window stays listed; a Zoom window opened after the lock never reads present for the call; a minimised meeting window reads gone and present again when restored.
- `LifecycleAdapterTests`: `NativeLifecycleConfig.zoom` carries a lock rank, and the Zoom recognizer accepts the meeting shape and rejects the Workplace main window.
- `WindowRecognizerFixtureTests`: start and end sides agree on every Zoom row.
- The existing Zoom corpus traces (`zoom_native_clean_leave_en`, `zoom_native_lifecycle_pair_dwell_trim`, `zoom_native_lifecycle_end18_leave_return_declined`) stay green; `cd daemon && swift test` green with the new tests named in the commit body; `bash scripts/ci-local.sh` green.

**Progress (2026-11-17): shipped; real Zoom captures remain.** `MeetingTitlePatterns.zoomWindow` is shared by the scanner and `NativeLifecycleConfig.zoom`, and is permissive like `teamsWindow`: it rejects the known non-call shapes (the launcher and the main window as "Zoom", "Zoom Workplace..." or "Zoom - <account>", the schedule and join dialogs, chrome tabs such as Settings or Team Chat) and accepts the rest. `zoomWindowShape` (`meeting_window`, `meeting_window_with_topic`, `other_window`, `main_window`, `chrome`, `empty`) feeds the lock row, whose classifier is now picked by bundle (`MeetingTitlePatterns.windowShape`). `zoomLockRank` puts a "Zoom Meeting" title first and any other accepted window second.

Decisions not in the spec: the first draft lifted the start side's old rule ("Zoom Meeting" required) and the Opus review rejected it: a webinar, a localised build or any other call-window title would have read gone from the call's first reading, END24's failure in reverse, and the only real Zoom data (DET12) matched that token on 1 of 8 rows. So the start side widens too (the scorer still needs a corroborating signal, so a title alone admits nothing), and the old end-side tokens are gone. No mini or floating bar row was added, since its title is unknown.

**Remainder (owner captures, as VALOWN1 is for Teams):** Zoom's window titles in the meeting window, the main window, a webinar, and in particular during a screen share and a breakout room, where Zoom may hide or recreate its meeting window; under identity mode a hidden or recreated locked window reads gone for that stretch (the live-mic veto covers most of it).

Tests: 5 `ShareableContentSignalTests` (the meeting window locked beside the Workplace window, a webinar window locked when it is the only call window, its close reading gone while the Workplace window stays, a later window never reading present, minimise and restore), `LifecycleAdapterTests` (the config carries a rank; the recognizer accepts the meeting, webinar and localised shapes, rejects the Workplace, account, dialog and settings titles, and ranks the meeting window first), `WindowRecognizerFixtureTests.test_zoom_start_and_end_sides_agree_on_every_row` over 6 new seeded rows plus shapes on the existing ones; the Zoom corpus traces stay green.
