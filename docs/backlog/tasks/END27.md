---
id: END27
title: A resumed recording can start with the lifecycle already in its terminal ended state, so nothing ever ends it
category: Detection
status: new
priority: P1
comment: Filed 2026-11-12. `20261112-174606` (END17 item 5's first field resume) recorded on with no end detection: Teams' initial window-gone reading reached `.starting` 2 ms before process audio's first reading, so no END14 veto applied and the engine went terminal `.ended`; the session dropped that end (start still in flight) and `engageLifecycleIfNeeded` then skipped as `already_engaged`, so the real leave at 15:50:34Z never opened a hold and the owner stopped it by hand 6 min later. Broken promise: a detected recording ends when the call ends. Scope: no window-gone end in `.starting` before process audio has reported, and re-engage a terminal engine at record start. P1; owner may re-band. [Spec](./END27.md)
---

# END27: a resumed recording can start with the lifecycle already in its terminal ended state, so nothing ever ends it

Band origin: filed 2026-11-12 from the owner's report that the last meeting "didnt even try to stop (no end confirmation running, currently active)", traced in-session the same day. A shipped-behaviour defect in [END17](./END17.md) item 5 (the resume path), not a regression of an earlier fix. Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## What happened

All times UTC from `~/Library/Logs/MeetingPipe/events.jsonl` (the owner is UTC+2, so 15:46Z is the owner's 17:46).

- 15:45:27.963 `lifecycle`/`ended` closes the previous recording, `20261112-172307` (see [END28](./END28.md) for what was wrong inside it), and `coordinator`/`stopped_candidate_retained` keeps the Teams candidate.
- 15:46:06.489 discovery picks Teams again (score 14, Leave, Mute and process audio all live).
- 15:46:06.598 `lifecycle`/`starting`.
- 15:46:06.606 `coordinator`/`recording_resumed_after_end` with `resumed_from: 20261112-172307`, `since_end_sec: 38.6`. This is END17 item 5: inside `ResumeAfterEnd.windowSec` (120 s) of an end, `MeetingSessionController.handleMeetingStarted` starts recording with no prompt.
- 15:46:06.613 `signal`/`shareable_content_no_match` with `reason: initial` (the call window title has not matched since the 2026-10-08 Teams title change, so this reading is `.ended` on every Teams call; [END14](./END14.md)).
- 15:46:06.614 `lifecycle`/`ended` with `leading_signal: shareable_content_window_gone`, `confirmed_by: []`. The engine is now terminal.
- 15:46:06.616 onward: process audio's first reading arrives, the recorder resolves the input, and 15:46:06.743 `coordinator`/`recording_started` writes `20261112-174606.wav`.
- 15:46:06.813 `coordinator`/`lifecycle_engage_skipped` with `reason: already_engaged`.
- 15:50:34.737 `signal`/`process_audio_is_running_input` goes false and 15:50:34.823 `ax_leave_button_state` goes `invalid`: the owner had left the call. No `ending_provisional`, no `lifecycle_end_held`, no `in_meeting` row at all for this recording (zero rows of either between 15:46 and 15:57).
- 15:56:54 the recording stops with no end-detection row before it (the owner's Stop after this session told them to press it): 648 s recorded, of which 266 s transcribed. Pipeline output: `2026-11-12 security-findings-triage-release-verification-sync.md`.

## Why each layer behaved as it did

1. **`PromotionEngine.handleStarting`** ends `.starting` directly on a reliable `.ended` unless `veto(for:in:)` finds a live process-audio reading in `states` (END14). At 15:46:06.614 process audio had not reported yet, so `states` held nothing to veto with and `shareable_content_window_gone` led alone. At 15:46:06 the initial readings landed Leave (.597, healthy), window (.614, `value: false`), process audio (.616, `value: true`): the veto was 2 ms short. On the healthy 15:23 start, process audio's initial reading (15:23:03.543, `true`) came first, the window's initial reading (.554) was `true`, and when the window poll went false at 15:23:07.581 the 15:23:07.585 `end_vetoed` row shows the veto doing its job. The initial readings race, and nothing orders them.
2. **`.ended` is terminal.** `ingest` returns nil for every later signal in `case .ended`, so the real leave at 15:50:34 had nowhere to go.
3. **The session dropped the verdict.** `MeetingSessionController.handleMeetingEnded` acts on `.recording` and on `.prompting`/`.suppressed` (REC7's `recordingStartInFlight` latch). At 15:46:06.614 the state was still `idle` with the resume's start in flight (the `idle` to `recording` transition is at .677), so the verdict fell to `default: break`. Acting on it would have been wrong too: it would have stopped the resumed recording on the false window-gone reading.
4. **The re-engage was skipped.** `MeetingSessionController.engageLifecycleIfNeeded` guards on `coordinator.lifecycleCoord.isEngaged` (an adapter exists), and the adapter discovery engaged was still attached to the terminal engine. The guard exists for a real reason (its doc comment: `engage` opens with `disengage()`, so an unguarded call would reset a live meeting to `.idle`), but it reads "engaged" as "working", and a terminal engine is engaged and not working.
5. **The idle backstop would not have saved it quickly.** The micgate verdict was `hot` (`rms_above_open_threshold`) from 15:49 to 15:53 from room noise, which resets `IdleStopBackstop`'s streak, so the 15-minute auto-stop would have fired around 16:08Z at the earliest.

The resume path makes the race likelier than the prompted path does: it calls `beginRecording` in the same turn discovery engages, so the engine's first milliseconds and the start overlap. On the prompted path the same race would end `.starting` while the prompt is up, and REC7's latch then dismisses the prompt; that variant was not observed and is named below rather than scoped.

This was the first resume in the logs (`grep -c recording_resumed_after_end` over `events*.jsonl` returned 1 on 2026-11-12), so the PERF commits landed the same day are not implicated.

## Scope

Two changes, both needed; either alone leaves a path to the wedge.

1. **Core: `.starting` does not end on window-gone before process audio has reported.** In `PromotionEngine.handleStarting`, when the lead is `shareableContentWindowGone` and `states` has no process-audio reading yet for this context, hold the end exactly as END14's veto holds it (`pendingVeto`), so process audio's first reading either lifts it (`.ended`, a hang-up before the start finished) or vetoes it (`.live`). The seam is the `veto(for:in:)` check; the smallest form is treating "process audio not yet reported" as a veto for the reliable signals END14 already vetoes, scoped to adapters that publish process audio at all (the browser tab-title path publishes none and must keep ending as today).
2. **App: a record start never inherits a terminal engine.** In `engageLifecycleIfNeeded`, when `isEngaged` is true but the engine's phase is `.ended`, re-engage (disengage, then engage with the start's handles) instead of logging `already_engaged`. Emit `coordinator`/`lifecycle_reengaged` with `bundle_id` and `reason: terminal_at_start` so the next occurrence is readable from `events.jsonl` alone. `MeetingLifecycleCoordinator` needs a read of the phase (or an `isTerminal`) for this; keep the guard's existing protection for every non-terminal phase.

## Explicitly not

- **Not extending REC7's in-flight latch to the resume path.** The verdict it would act on is the false window-gone reading, so it would stop the resumed recording within milliseconds.
- **Not revisiting END17 item 5's no-prompt resume.** [DET13](./DET13.md) recorded "any policy here returns prompt, never record"; END17 overrode that with the owner's decision on 2026-10-24. Whether that decision still stands after [END28](./END28.md) is END28's question, not this task's.
- **Not the window-title match itself.** The `" | Microsoft Teams"` suffix loss that makes window-gone fire on every Teams call is END14's.
- **Observed, not filed:** the prompted-path variant above (window-gone before process audio while the prompt is up dismisses the prompt). Change 1 closes it too if it lands in `handleStarting`, which is the reason to put it there rather than in the resume path; the pickup session should confirm that with a test and say so in the landing note.

## Acceptance

- `PromotionEngineTests`, failing first: (a) in `.starting`, window-gone `.ended` then process audio `.live` leaves the engine non-terminal and a later `confirmRecording()` reaches `.inMeeting`; (b) window-gone `.ended` then process audio `.ended` ends (the hang-up before the start finished, END14's case, still works); (c) the browser tab-title adapter with no process-audio signal still ends on its own lead.
- A `MeetingSessionController` test (in `MeetingSessionControllerTests` or `MeetingSessionControllerBranchTests`, whichever holds the resume tests): a resume whose engine is terminal at start re-engages, emits `lifecycle_reengaged`, and a later leave opens a hold; a start against a live engine still logs `already_engaged` and does not reset it.
- A lifecycle replay of the 2026-11-12 15:46:06 window extracted with `scripts/extract_detection_trace.py --raw` into `DetectionCorpusTests`, ending with a hold opened at the 15:50:34 leave.
- `cd daemon && swift test` green with the new tests (count left to the implementing session); `bash scripts/ci-local.sh` green.
- Field check, after the build is installed (not a precondition): the next `recording_resumed_after_end` row is followed by an `in_meeting` row, and its call's end produces `lifecycle_end_held`. Zero `lifecycle_engage_skipped` rows with `reason: already_engaged` directly after a `lifecycle`/`ended` for the same bundle.
