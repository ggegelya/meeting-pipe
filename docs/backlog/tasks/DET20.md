---
id: DET20
title: A browser meeting's only end signal is the active tab title of an on-screen window, so tab switches, Spaces and back-to-back calls end, extend or fuse browser recordings
category: Detection
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). A plain browser's presence and end come only from ShareableContentSignal's on-screen active-tab title, with no process-audio read and no teardown route, so at HEAD a leave confirms only on the 720 s lone dwell, staying off the tab past it ends a live call, and any matching title reverts a hold so back-to-back Meet calls fuse; the one sourced Chrome recording (20261005-180843) ended 120.0 s late on build A's floor and no browser has a mic row in any era. Scope: plan stage 9, gated on DET24's bar B1, DET25 and DET16's verdict: make the session reducer the browser authority on the browser's audio helper holding input, name by title or URL, bind offers to the session, and drop the room-code start gate and readsProcessAudio's browser exclusion; revisits END17 owner decisions 1 and 2. [Spec](./DET20.md)
---

# DET20: A browser meeting's only end signal is the active tab title of an on-screen window, so tab switches, Spaces and back-to-back calls end, extend or fuse browser recordings

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Sources: D030 (high, demonstrated), D036, D039 and D051 (medium, demonstrated), D038 and D080 (medium, code derived) in [2026-11-13-recording-reliability-audit.md](../../audits/2026-11-13-recording-reliability-audit.md), with mechanism, field counts and verifier reasoning in [2026-11-13-recording-reliability-evidence.md](../../audits/2026-11-13-recording-reliability-evidence.md); stage 9 ("Browsers on the reducer, only for the bars that passed") and the probe bars B1 to B3 of that audit's plan. The lows D004, D012 and D040 are folded in below. Re-verified in code at HEAD `3a2da4fc` on 2026-11-13.

**One end signal.** `BrowserMeetingLifecycleAdapter.start` maps `ShareableContentSignal`'s presence to `PrimarySignalEvent(kind: .browserTabTitle, state: present ? .live : .ended, ...)`. `ShareableContentSignal.defaultFetch` asks ScreenCaptureKit for windows with `onScreenWindowsOnly: true`, and `evaluate` counts a window present only when `summary.bundleIdentifier == context.bundleID && titleMatch(summary.title)`, so a window on another Space, minimised, behind a full-screen app, or showing another tab reads ended. The adapter's other signals are `workspaceAppTerminated` (a quit, definitive) and an AX window-title signal that exists only for a PWA's `handle.meetingWindow`.

**Nothing can say the call is alive.** `MeetingSourceScanner.readsProcessAudio` is `kind == .native && NativeLifecycleConfig.usesProcessAudio(bundleID:)`, and its doc comment says browsers answer false on purpose because a browser on the mic names the browser, never the tab. `TeardownHoldPolicy.consult` opens with `guard let hold, hold.context.kind == .native else { return nil }`. `EndEvidenceClass` gives `browserTabTitle` a class of its own, so `PromotionEngine.tick`'s 60 s pair (`defaultConfirmDwell`) can never be reached for a plain tab and the hold confirms only on `defaultLoneDwell`, 720 s, with the HUD reading "Confirming end" throughout (D036, D080). Staying off the meeting tab past 720 s ends a live call, and the held-end trim then cuts at the hold's first stamp, inside live audio (D038, building on F032, filed as END21 by this band). D080 adds that `DetectionCorpusTests` pins the wait as correct.

**Back-to-back calls fuse (D039).** In `.endingProvisional`, a `.live` whose `event.kind.evidenceClass == leading.evidenceClass` reverts the hold to `.inMeeting`. For a browser that is any window of the same bundle whose title matches any matcher; the context is bundle plus pid and the Meet code is discarded, and `handleDiscovery` returns early while recording, so leaving one Meet call and joining the next within 12 minutes yields one recording under the first call's title and workflow, with no prompt.

**No microphone evidence (D051).** On the work-laptop pack (114,553 events, 2026-09-29 to 2026-11-13) all 9 Chrome `discovery_shadow_pick` rows have `winner_score` 2 with every control and `process_audio_is_running_input` false, and `signal/process_audio_*` rows exist only for `com.microsoft.teams2` and `us.zoom.xos`. The device-level DET1 tier would cover a browser in code, but it never produced a span in any era ([DET10](./DET10.md)).

**Field.** The one sourced browser recording, `20261005-180843` (Chrome, era 1), went `ending_provisional` on `browser_tab_title_left_meet_pattern` at 2026-10-05T15:20:08.575Z and `ended` with `confirmed_by` empty at 15:22:08.604Z, 120.0 s later, with 121.5 s of tail after the last segment: build A's 120 s floor. HEAD's 720 s path has never run on the work laptop (no browser recording in eras 2 or 3).

**Lows folded in, same seam.** D004 (demonstrated): start needs the Meet tab selected in an on-screen window at two separate reads (the discovery scan and the lifecycle's SCK probe); once discovery engages, the 1 Hz SCK poll can raise `.starting` by itself. D012: admission enumerates `MeetingAppRegistry.shared.browserBundles` (ten in `defaultBrowserBundleIDs`) plus the three `pwaBundleIDPrefixes`, and the mic tier's plausible set is built from the same list. D040: when the probe returns nil (no Screen Recording grant, SCK timeout, gate busy) `evaluate` calls `noteUnavailable` and keeps the last value, so a browser recording last read `.live` has no title end at all and rests on a quit or the idle backstop; the pack holds 1,656 `shareable_content_unavailable` rows (era 1 288, era 2 1,368, era 3 0).

Correction at filing: the batch summary says a browser leave confirms "only on the 120 s floor or the 720 s lone dwell". At HEAD the 120 s `endDebounceFloor` is gone (END17 retired it on 2026-10-24); it is build A's behaviour, and HEAD has only the 720 s lone dwell. D030's one demonstrated mid-call chop (`20261111-155951`, 2026-11-11) came through the unguarded `.starting` direct end on a source-less recording, not the hold; that path is END19, filed by this band. D012's "ten registry bundles" is the default list; a user overlay browser extends it (DET4). D051's "plays no part" is overstated in code (the DET1 tier covers browsers) and true in the field.

## Scope

Plan stage 9, for browser families only. Gated: it starts only when DET24 (the owner-run probe spike) records bar B1 as passed and DET25 (the session reducer in shadow) exists, and [DET16](./DET16.md)'s verdict comes first, because a PASS there deletes browser detection and this task with it.

1. **The reducer becomes the browser's authority.** For browser families the DET25 reducer, not `PromotionEngine` with `BrowserMeetingLifecycleAdapter`, opens and ends the session: the session opens on the browser family's audio helper holding input (bundle id plus dotted-prefix helpers, attributed by PID ancestry through the HAL process-object resolver the native path already uses), after 5 s when any window identifies a meeting page and after 20 s when none does (the offer then reads "Call in <browser>?" and never records automatically).
2. **A namer, not an end voter.** The tab title, or the tab address where the owner allows it, only names the session. Switching tabs, windows or Spaces never ends or marks it.
3. **Session-bound offers.** The prompt and any skip bind to that session (sharing DET18's span-bound skip), so back-to-back calls are two sessions with two offers.
4. **The end branch the bars select.** B2 and B3 pass: the Teams rule, the session ends on the helper's input release. B2 fails: the ambiguous rule. B3 fails or another tab keeps the microphone: the recording runs on, the HUD offers Finish once the identified page has been gone 60 s, and the ceilings bound it.
5. **Remove the start gate and the exclusion.** The room-code requirement in `MeetingTitlePatterns.googleMeet` stops gating a start (it may still name), and `MeetingSourceScanner.readsProcessAudio` stops returning false for every browser. An unreadable SCK probe is unknown, not live (D040). Safari attribution and reading tab addresses happen only with the owner's explicit yes.
6. **Docs in the same commit.** `docs/GUIDE.md`'s browser-meeting recipe, `README.md`, and ADR 0017's "Negative, accepted" note for browsers are updated; a new ADR records the browser authority if the owner accepts the revisit below.

If B1 failed, this task closes as moot and browsers stay on the title-dependent opener.

## Explicitly not

- Teams and Zoom on the reducer: gated separately (END26, filed by this band).
- The title-only start for a meeting-named Meet tab: DET17, filed by this band.
- The source-less recording stopped by a foreign browser engage from `.starting`: END19.
- The trim point inside live audio after a long hold: END21.
- Browser mute: [MIC7](./MIC7.md). Non-Meet browser meetings: [DET6](./DET6.md).
- Recording before consent, or per-tab audio capture: rejected by the audit's design synthesis against ADR 0016.

## Acceptance

- Core tests on the DET25 reducer with a fake HAL backend: (a) a Chrome helper holding input for 5 s with a Meet-titled window opens a session and an offer; with no identifying window it opens after 20 s as "Call in Chrome?"; (b) switching the active tab, minimising and a Space change while the helper holds input neither end nor mark the session; (c) the helper's input release ends it under the branch B2 and B3 selected; (d) leaving one Meet call and joining another yields two sessions and two offers, not a reverted hold; (e) an unreadable probe never keeps a session live on its own.
- `PromotionEngineTests` and `DetectionCorpusTests` that pin the browser lone dwell as correct are rewritten or retired with a sentence in the commit body naming each.
- `cd daemon && swift build` and `swift test` green, N new tests named in the commit body; `bash scripts/ci-local.sh` green.

## Owner walkthrough

1. [owner] Before pickup: decide whether this revisits END17 owner decisions 1 (accept the inversion, record long and trim) and 2 (the 12 minute `lone_dwell`) for browsers, and whether Safari attribution or tab addresses may be read.
2. [session] Confirm DET24's B1, B2 and B3 results and DET16's verdict are recorded, then land.
3. [owner] Use Meet in the browser normally for the next 10 Meet calls, then hand over the event log.
4. [session] From that log: each of the 10 calls has a session and an offer within 10 s of joining; none is ended or marked by a tab or window change; at most 2 non-meeting browser microphone sessions of 20 s or more per week before unidentified-page offers default on. Record the result here.
