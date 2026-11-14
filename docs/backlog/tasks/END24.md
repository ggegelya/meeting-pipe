---
id: END24
title: The end-side Teams window matcher has rejected every Teams call window since 2026-10-08 while the start side accepts the same titles, so window-gone is a false reading on almost every call
category: Detection
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). Since 2026-10-08T14:31:18Z `MeetingTitlePatterns.teams` rejects the titles `MeetingSourceScanner.isActiveMeetingWindow` accepts (1,264 shareable_content_no_match rows, 4 chops in era A, 136 end_vetoed since END14), so a false window-gone spends one of the two evidence classes an end needs and wins whenever the first-reading race goes wrong. Scope: stop treating a title substring as proof the call window exists (window identity, one shared recognizer, or no Teams window-gone end vote), pinned by captured title shapes in the recognizer fixture. P2 while END14's veto absorbs it; promote if a Teams chop recurs.
---

# END24: The end-side Teams window matcher has rejected every Teams call window since 2026-10-08 while the start side accepts the same titles, so window-gone is a false reading on almost every call

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Source findings: D095, D099 and D092 in the [recording reliability audit](../../audits/2026-11-13-recording-reliability-audit.md), with D095 and D099's mechanism, field counts and verifier notes in the [reliability evidence](../../audits/2026-11-13-recording-reliability-evidence.md); the [field evidence](../../audits/2026-11-13-field-evidence.md) finding "The window signal has read gone on Teams calls since 2026-10-08, so the era-3 pair rule rests on process audio alone".

**Two recognizers for one window** (re-read at HEAD 2026-11-13).

- Start side, `MeetingSourceScanner.isActiveMeetingWindow` (MeetingPipe target): the native Teams branch rejects an exact chrome word (`"chat"`, `"calendar"`, `"microsoft teams"` and so on) and a bare `| microsoft teams` suffix, then accepts everything else, ending in `return !lowered.isEmpty`.
- End side, `NativeLifecycleConfig.teams` passes `titleMatch: MeetingTitlePatterns.teams` into `ShareableContentSignal.start(context:titleMatch:)`. `MeetingTitlePatterns.teams` accepts a title only if it contains one of `teamsTokens` (a localised "meeting" stem or `"microsoft teams"`), unchanged since END5 on 2026-07-12. `ShareableContentSignal.evaluate` sets `present` to `summary.bundleIdentifier == context.bundleID && titleMatch(summary.title)` over every on-screen window, so a call window the start side accepted reads gone.
- `ShareableWindowSummary` carries only `bundleIdentifier` and `title`; `defaultFetch` drops the `SCWindow`'s window id and owning pid, so the signal cannot ask whether the window it saw at engage still exists.

**Field record, work laptop.**

- From 2026-10-08T14:31:18.668Z: 1,264 `signal`/`shareable_content_no_match` rows for `com.microsoft.teams2` with a non-empty `candidate_titles` list and no token; the scanner predicate, reimplemented, accepts at least one candidate in 1,262 of them. 843 of those rows fall inside recordings (859 by the verifier's boundary). Of 2,511 candidate titles, none contains a token. Before that moment every no_match row had an empty list, so Teams changed its window titles on that date.
- Era A (to the 2026-10-12 rebuild): 317 `lifecycle`/`ended` rows led by `shareable_content_window_gone` with `confirmed_by: []`, and 4 chopped recordings (ends at 2026-10-08T14:38:39Z, 2026-10-09T09:17:30Z, 09:18:51Z and 14:31:34Z), plus the prompt flapping every few seconds.
- Eras B and C (END14 builds): 136 `lifecycle`/`end_vetoed` rows (B 129, C 7), all `leading_signal: shareable_content_window_gone`, `vetoed_by: process_audio_is_running_input_false`. 48 of 49 Teams recordings after the change logged a non-empty no_match row or `window_present: false` while recording.
- Era C: all four Teams ends listed `shareable_content_window_gone` in `confirmed_by`, from a `window_present: false` reading 184, 1,091, 345 and 658 s old. The false reading is now half of every confirmed pair ([END14](./END14.md)'s amendment covers the stale-stamp pairing in `PromotionEngine.tick`).

**Why the veto is not enough.** [END14](./END14.md) (filed 2026-10-12) recorded this exact title change and chose not to widen the match ("It can be filed separately if the owner wants"), because a live `process_audio_is_running_input` veto absorbs the lone window-gone. That holds only when the mic reading lands first. Since CONC9 and PERF15 (2026-10-26) both first readings are queued independently, and in era C the window reading led once in five engagements and lost one start ([END20](./END20.md), stem 20261112-174606). It also holds only while process audio resolves: `process_audio_object_unresolved` has 7,643 rows in the pack.

**The fixture cannot catch it (D092).** `daemon/Tests/MeetingPipeTests/Fixtures/window_titles.json` holds 21 rows, all `seeded: true`, 0 captured. `WindowRecognizerFixtureTests.test_recognizer_matches_fixture` hard-codes `kind: .native` and drives only `MeetingSourceScanner.isActiveMeetingWindow`, never `MeetingTitlePatterns.teams`, so the two sides are not pinned against each other; `test_fixture_is_backed_by_real_captures` throws `XCTSkip` below `capturedRowFloor = 1`. The capture that would fill it is [VALOWN1](./VALOWN1.md) (P4), whose emitted rows carry literal titles.

Correction at filing: "every Teams call window" in the title and in D095 is slightly too strong. 48 of 49 Teams recordings after the change logged a non-matching or window-absent reading, not 49 of 49 (D095's per-recording window-true percentages were not verified), and whether each rejected candidate is the call window rests on shape counts, since the verifiers deliberately read no title. The defect is that it reads gone on almost every call.

## Scope

Pick one at pickup, in this order of preference, and record why in the commit body:

1. **Identity, not vocabulary.** Extend `ShareableWindowSummary` with the window id and owning pid from `SCWindow`, capture the identity of the Teams window that is present when the lifecycle engages (or when it first reads present), and have `ShareableContentSignal.evaluate` report gone only when that window is no longer in the list. A title is then used once, to pick the window at engage, through the same predicate the scanner uses.
2. **One recognizer.** If identity proves unworkable (for example the call window is recreated mid-call), route both sides through one Teams predicate in `MeetingTitlePatterns` that `MeetingSourceScanner.isActiveMeetingWindow` calls too, the way the Webex branch already shares its vendor matcher, so the two cannot drift again.
3. **No vote.** If neither holds, stop wiring `ShareableContentSignal` as a Teams end voter in `NativeLifecycleConfig.teams` and keep its reading log-only. [END26](./END26.md) may make this moot by retiring it as a Teams end voter under the reducer.

In every option, add the fixture half: a `kind` column in `window_titles.json` (and drop the hard-coded `.native`), a second assertion that runs every Teams row through the end-side predicate as well and fails when the two sides disagree, and committed rows that hold a title shape class (for example `bare_single_segment`, `chat_pipe_segment`, `pipe_microsoft_teams_suffix`), never a captured title. Once VALOWN1's capture lands as shape classes, `test_fixture_is_backed_by_real_captures` stops skipping and asserts.

[PERF6](./PERF6.md) also touches the start-side Teams recognizer (the permissive title reopens its AX walk gate); whichever of the two lands second reconciles the predicate.

## Explicitly not

- Widening `teamsTokens` with the shapes seen since 2026-10-08: it is the same localised-label scraping that broke, and END14 already rejected it.
- Removing END14's live-mic veto or changing `PromotionEngine`'s evidence classes: the stale-stamp pairing in `tick` is END14's amendment, the first-reading order is [END20](./END20.md).
- Off-screen windows: `defaultFetch` passes `onScreenWindowsOnly: true`, so a minimised or other-Space call window also reads gone. In era A that happened 7 times and each healed in 1.0 to 1.1 s; option 1 should keep that behaviour visible in a test, not fix it.
- Logging titles: `shareable_content_no_match` writes literal `candidate_titles` to the event log on every mismatch. Reducing that row to shape classes is an observed adjacency, not filed here.
- [DET16](./DET16.md) may delete the seeded fixture and its skipped test; if it lands first, this task adds the captured-shape fixture fresh rather than amending the seeded one.

## Acceptance

- `MeetingPipeCoreTests` (`ShareableContentSignalTests`): a Teams window whose title has no token but which was present at engage reads present on later polls (the 2026-10-08 shape); the same window removed from the list reads gone; a different Teams window appearing (a chat window) does not read present for the call. For option 2, the shared predicate accepts the bare-segment shape and rejects every chrome word on both sides.
- `MeetingPipeTests` (`WindowRecognizerFixtureTests`): the new cross-side assertion fails against today's `MeetingTitlePatterns.teams` on a bare-segment row and passes after the change; the `kind` column is read, and a row with an unknown `kind` fails as malformed.
- A replay through `PromotionEngine` of the era A order (window gone first, process audio live) yields no end without relying on the veto.
- `cd daemon && swift test` green with the number of tests added in the commit body; `bash scripts/ci-local.sh` green.
- Field: over the next two weeks of Teams calls on the landing build, `end_vetoed` rows led by `shareable_content_window_gone` fall from 7 in era C's 6 recordings to 0, and no Teams `confirmed_by` lists `shareable_content_window_gone` while a call window was on screen.
