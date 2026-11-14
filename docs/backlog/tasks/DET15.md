---
id: DET15
title: End-of-call signals are calibrated to English-UI Teams: the Leave and toolbar matchers are English-only, Teams title stems miss accented spellings, and every native app's hold reads Teams' log
category: Detection
status: new
priority: P3
comment: Filed 2026-10-24 (audit band, go-live PD-2): Leave labels and toolbar needles are English-only, Teams title stems miss accented spellings and Ukrainian, and Zoom, Webex and Slack holds read Teams' teardown log. Scope: a leave-label catalogue beside MuteLabels.toml, diacritic-folded title matching, a per-app oracle. P3 until a non-English UI or non-Teams end is recorded. [Spec](./DET15.md) Amended 2026-11-13 by the audit band: non-Teams ends are now recorded (3 Zoom), so the promotion trigger has fired and the owner may promote; Webex and Slack can only confirm on the 720 s lone dwell and Zoom on the 60 s pair (D045), the Teams oracle confirms any native hold by time alone (D031), and the mute pick has no control-level anchor (F042).
---

# DET15: end-of-call signals are calibrated to English-UI Teams: the Leave and toolbar matchers are English-only, Teams title stems miss accented spellings, and every native app's hold reads Teams' log

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([go-live assessment](../../audits/2026-10-21-go-live-assessment.md) PD-2). Filed P3: nothing has failed in the field yet, because the owner records English-UI Teams. Promote on the first recorded meeting in a non-English client UI, or the first false or missed end on Zoom, Webex or Slack. Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Verified in code on 2026-10-24. The go-live review could not see a live non-English client, so the locale gaps below are read from the matchers, not observed.

1. **Leave buttons are English-only.** `MeetingAXHandleBuilder.matchesLeave` matches lowered substrings per bundle: Zoom `"leave"` or `"end meeting"`; Webex `"leave meeting"`, `"end meeting"`, `"end"` or `"leave"`; Slack `"leave huddle"`, `"leave call"`, `"end huddle"`. Teams goes through `isTeamsCallLeaveLabel`, an exact match against `"leave"`, `"leave call"`, `"leave meeting"`, `"leave the call"`, `"leave the meeting"`, or a `"hang up"` substring. Its doc comment says the set matches "what the daemon already shipped against". The mute side, by contrast, has a locale catalogue (`MeetingPipeCore/MicGate/Resources/MuteLabels.toml`, en, de, es, fr, ja, pt, ru, uk) with a validator. A Ukrainian-UI Teams call would never arm a Leave button, so `AXLeaveButtonSignal` would never lead or corroborate an end.
2. **Toolbar needles are English-only.** `callingControlsToolbarNeedles(bundleID:)` returns `["calling controls"]` for Teams and `"meeting controls"`, `"call controls"`, `"huddle controls"` for the others.
3. **Title stems are accent-sensitive.** `MeetingTitlePatterns.teams` lowercases the title and looks for any of `teamsTokens`: `"meeting"`, `"besprechung"`, `"reunion"`, `"reuniao"`, `"encuentro"`, `"встреча"`, `"kokous"`, `"spotkanie"`, `"moot"`, `"microsoft teams"`. `lowercased()` keeps diacritics, so French "réunion" and Portuguese "reunião" do not contain `"reunion"` or `"reuniao"`, and Spanish "reunión" does not either. There is a Russian stem and no Ukrainian one. Since 2026-10-08 Teams no longer appends ` | Microsoft Teams` ([END14](./END14.md)), so the localized stem is the only thing a call window can match on.
4. **The teardown oracle is Teams-only, but every native app consults it.** `Coordinator` holds one `CallTeardownWatcher.teams()`, which tails Teams' `MSTeamsNM_SlimCore_` log. `MeetingSessionController.rescueProvisionalEnd` is gated only on `context.kind == .native`, and when its walk finds no Leave button it calls `beginTeardownHold`, whose `consultTeardownOracle` reads `coordinator.callTeardown.snapshot()` with no bundle check. A Zoom, Webex or Slack hold therefore waits on Teams' log: with Teams not installed it confirms at once (`oracleUnavailable`); with Teams installed it holds until the 150 s cap, a live-signal veto, or a Teams teardown line from an unrelated Teams call after this recording started. Process audio is wired for Teams and Zoom only (`NativeLifecycleConfig.usesProcessAudio`), and DET8 measured the input release on Teams only.
5. **Calibration data.** The detection corpus holds 22 Teams traces against 1 Zoom, 1 Webex and 2 Google Meet, and no Slack.

## Scope

1. **A leave-label catalogue.** Move the Leave labels and toolbar needles into a localized catalogue beside `MuteLabels.toml`, loaded and validated the same way, seeded with today's English sets so English behaviour is unchanged. Add locales only from a live AX scrape of a real client (`scripts/dump_window_titles.swift` or an AX dump), never from translation guesses. Ukrainian labels are verified with the owner, as the backlog's locale rule requires.
2. **Diacritic-insensitive title matching.** Compare titles and tokens folded with `.diacriticInsensitive` and `.caseInsensitive`, and store tokens unaccented. Add a Ukrainian meeting stem confirmed by the owner from a real Teams window title.
3. **A per-app oracle.** Make the oracle a per-bundle lookup: Teams bundles get the SlimCore watcher, and any other bundle gets an explicit "no oracle for this app" answer, logged once per hold with the bundle, instead of Teams' snapshot. What a hold does with no oracle follows END17's evidence tiers; until END17 lands it keeps today's `oracleUnavailable` behaviour, now visible in the log.

## Explicitly not / out of scope

- Detecting browser meetings other than Meet: [DET6](./DET6.md).
- The end-of-call policy itself: END17. This task only stops the signals and the oracle from being silently English-Teams-shaped.
- Mute-label coverage, which already has its catalogue.
- Measuring whether Zoom releases process audio at leave; worth a probe the first time a Zoom meeting is recorded, listed so it is not lost.

## Acceptance

- Tests: every pre-existing English Leave label and toolbar needle still matches (a table over the old sets); the catalogue validator rejects a malformed entry; `MeetingTitlePatterns.teams` matches "Réunion d'équipe", "Reunião semanal" and "Reunión diaria" and still rejects a chat window title of the `Chat | <name>` shape END14 recorded; a non-Teams native hold logs the no-oracle event and does not read the Teams watcher (a fake watcher records zero snapshot calls).
- Any new locale entry names its scrape source in the catalogue comment.
- `cd daemon && swift build` and `swift test` green, with the new test count in the commit body; `python3 scripts/truth_fences.py` clean if a new event action is added (`CONVENTIONS.md` table in the same commit).

## Owner walkthrough

1. [owner] When promoting: join one Teams call with the Teams UI language set to Ukrainian, and send the session the Leave button's AX label and the call window's title (the session supplies the one-line dump command). Pass: the labels are added and a test pins them. Cost: one short test call.

## Amendment 2026-11-13 (audit band)

Sources: D045 and D031 in the [2026-11-13 recording reliability audit](../../audits/2026-11-13-recording-reliability-audit.md) (its stop-edge and end-detection cross-checks carry the field reading), and F042 in the [2026-11-12 independent audit](../../audits/2026-11-12-independent-audit.md). Re-verified in code at HEAD on 2026-11-14.

**This task's promotion trigger has fired.** The provenance line says promote on "the first false or missed end on Zoom, Webex or Slack", and the header says P3 until a non-Teams end is recorded. The work-laptop pack (2026-09-29 to 2026-11-13) holds 3 Zoom recordings (20260930-180324, 20261013-170136, 20261112-170131), and their ends are late by design (below). The band leaves it at P3; the owner may promote it.

**Outside Teams no native app has a definitive end (D045).** `PrimarySignalKind.isDefinitive` is `self == .workspaceAppTerminated`; the only other definitive route is the host's `confirmProvisionalEnd(evidence: PromotionEngine.teardownEvidence)`, which only Teams' log can feed. Every other end opens a hold that `PromotionEngine.tick` confirms after `defaultConfirmDwell` (60 s) when two evidence classes have both ended, or after `defaultLoneDwell` (720 s). `NativeLifecycleConfig.zoom` sets `usesProcessAudio: true`, so a Zoom leave pairs `.processAudio` with `.callWindowOrControl` and confirms at 60 s. `NativeLifecycleConfig.webex` and `.slack` set it false, and their two remaining signals, `axLeaveButton` and `shareableContentWindow`, share the `.callWindowOrControl` class ("ax-leave + window-gone share a class"), so a Webex or Slack leave can confirm only on the 720 s lone dwell, an app quit or a hand stop. Field: Zoom's process audio went false at the leave in 3 of 3 Zoom recordings (2026-09-30T15:37:31Z, 2026-10-13T14:37:09Z, 2026-11-12T15:19:49.322Z, the last one in stem 20261112-170131 followed by window-gone at 15:19:50.967Z). The audit's cross-check also found Teams no faster in build C: 4 of 4 real Teams ends waited the 60 s pair dwell and none was confirmed by the teardown line.

**Correction at filing to Context item 4.** It describes the oracle before END17: "with Teams not installed it confirms at once (`oracleUnavailable`); with Teams installed it holds until the 150 s cap". END17 (2026-10-24) retired `oracle_unavailable`, `hold_cap_reached` and `live_signal_ceiling_reached`; `CallTeardownOracle.Reason` now has one case, `teardownObserved`, and an unreadable log is no evidence, so the hold runs to the engine's dwells. What remains of item 4 is the next paragraph.

**The teardown oracle is matched by time alone and consulted for every native app (D031, low, not seen in the field).** `SlimCoreTeardownLog.parse` reads the id after `UnregisterCall ` only to reject a malformed line ("it is not returned"); `CallTeardownWatcher` keeps only `lastTeardownAt`, the newest; `TeardownHoldPolicy.consult` gates on `hold.context.kind == .native` and nothing else; `MeetingSessionController.consultTeardownOracle` hands it `coordinator.callTeardown.snapshot()`, the one `CallTeardownWatcher.teams()`, for any hold; and `CallTeardownOracle.decide` confirms on any teardown at or after `max(provisionalStartedAt - 15 s, recordingStartedAt)`. So any Teams call ending inside a Zoom, Webex or Slack hold, or a second Teams call ending inside a Teams hold, confirms it at once and trims the recording from the hold's start. A Webex or Slack hold can run 720 s, which makes that window wide. The field pack shows the oracle confirming only 2 ends in total (2026-11-09 and 2026-11-12, both Teams), so it has not fired wrongly yet.

**The mute control has no control-level anchor (F042).** `MeetingAXHandleBuilder.meetingWindowControl` takes the first button or checkbox in a window's DFS (`findButton`) that `matchesMute` accepts, and `matchesMute` accepts any element whose title, help or description contains, as a word (`MuteLabels.containsAsWord`), any `actionMute`, `actionUnmute`, `statusMuted` or `statusUnmuted` label from any locale of that app's catalogue entry. The en entries are a bare "Mute" and "Unmute" for Teams, Slack and Webex (Zoom adds "Mute my microphone"), so a "Mute all" or per-participant "Mute" button earlier in the walk would qualify. `findMeetingWindowMuteButtons` anchors at window level (`scopeToLiveControl`, preferring the window that also has Leave) but not at control level. Correction at filing: the label set is the app's own entries across its locales, not every app's. It needs a vendor layout that puts such a button ahead of the in-call mute, which nothing shows today, so it fits this task's P3. The 2026-11-12 audit proposed it as a separate DET15 amendment; it is folded in here.

### Scope additions

4. **Scope the oracle consult to Teams now (D031).** Return nil from the consult unless `hold.context.bundleID` is one of `NativeLifecycleConfig.teams.bundleIDs`. It needs no gate, can land ahead of item 3, and is its first slice; item 3's per-bundle lookup then replaces it. The full fix binds the teardown to this call's id, which needs a call-start line from the same SlimCore log that the parser does not read today; check a real log for one before designing it.
5. **Mic release as the primary end lead where it is measured (D045).** A per-app leg in which a native whose process-audio release at leave has been measured confirms on that release with a shorter dwell (about 30 s, taken from the measurement, not from this note), with Leave and window-gone as corroborators. Gated per app: Zoom after [DET24](./DET24.md)'s bar Z1; Webex only after one measured call shows a release despite the ultrasound mic hold that is why `usesProcessAudio` is false for it; Slack after one measured call. The dwell must stay above END15's in-call device switch (re-acquired inside 22 s on 2026-10-22), the false-end shape a short release dwell reopens. The tier policy itself stays [END17](./END17.md)'s, and the revert-on-level rules are [END18](./END18.md)'s.
6. **Anchor the mute pick (F042).** When item 1's catalogue lands, search for the mute control inside the calling-controls subtree (item 1's toolbar needles) or on a stable `AXIdentifier`, prefer the most specific label over a bare "Mute", and pin each app with a captured AX dump.

### Acceptance additions

- D031: with a fake watcher reporting a teardown inside the window, an open Zoom hold and an open Webex hold are not confirmed and the watcher records zero snapshot calls for them; a Teams hold with the same teardown confirms as today.
- D045: a replayed Zoom leave (Leave invalid, process audio false within 5 s, window gone) confirms at the new dwell; a replayed END15 device switch (release re-acquired within 22 s) does not end the recording; Webex and Slack keep today's tiers until their own call is measured. Before and after end latency for the 3 Zoom recordings named above in the commit body.
- F042: a fixture window with a "Mute all" button ahead of the call toolbar's mute resolves to the toolbar's control.
- `cd daemon && swift build` and `swift test` green with the number of tests added in the commit body; `python3 scripts/truth_fences.py events` green if a new event action is added.
