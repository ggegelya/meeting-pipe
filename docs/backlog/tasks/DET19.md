---
id: DET19
title: mp analyze-detection counts every lifecycle end as a detector success and ignores every event END9 to END17 added, so false ends, overruns and holds never show as minutes
category: Detection
status: partial
priority: P2
comment: Shipped 2026-11-16: the end dimension judges every automatic stop against the recording bundle's process_audio_is_running_input rows plus a same-app re-sighting inside --watch-window-sec, reporting false ends with seconds lost, foreign ends, late ends and overrun minutes, trim error, fragments, holds by route and stood-down backstops per app and per week, with mic_in_use_stop and recording_ended_during_start as their own stop kinds; 8 new tests. Remainder: switch the span to DET23's ledger and the stop kind to OBS5's cause, and add the per-era split, once those land; owner approval to close. Amended 2026-11-17 by the post-audit fix review: an ignored foreign end is classified as the stop.
---

# DET19: mp analyze-detection counts every lifecycle end as a detector success and ignores every event END9 to END17 added, so false ends, overruns and holds never show as minutes

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Sources: D079 ("The only reliability report counts a false end as a detector success") and D091 ("The report cannot measure a late end, an overrun or a hold, and ignores every event END9 to END17 added"), both medium and demonstrated in log, in [2026-11-13-recording-reliability-audit.md](../../audits/2026-11-13-recording-reliability-audit.md); the harness description ("Shadow mode and metrics today") in [2026-11-13-recording-reliability-evidence.md](../../audits/2026-11-13-recording-reliability-evidence.md); and the audit plan's REPORT line, which rewrites `mp analyze-detection` over the microphone-holder rows and the stop cause. Neither finding had a skeptic pass ("not checked"), so every claim below was re-verified in code at HEAD `3a2da4fc` on 2026-11-13.

**How it classifies today.** `pipeline/src/mp/analyze_detection.py`'s `pair_sessions` walks events in time order and acts on exactly five actions: `coordinator/recording_started`, `lifecycle/ended` (stored as `detector_ended_ts`, "the last one is what actually drove the stop"), `coordinator/auto_stop_silence`, `coordinator/force_stop` and `coordinator/recording_stopped`. `classify_session` then sets `STOP_DETECTOR` whenever `session.detector_ended_ts is not None`, and its only timing figure, `delta_sec`, is `stopped_ts - detector_ended_ts`, which is flush latency. Nothing asks whether the call was still up. A `lifecycle/ended` from any bundle counts, so the Chrome engage that stopped the source-less `20261111-155951` mid-conversation on 2026-11-11 would read as a detector success. The tests pin this: `test_pair_sessions_classifies_detector_triggered_stop` and `test_pair_sessions_picks_latest_detector_ended_when_debounce_flutters`.

**What it cannot see.** `grep` over the module finds no reference to `lifecycle_end_held`, `lifecycle_end_hold_released`, `end_vetoed`, `held_end_trimmed`, `auto_stop_silence_skipped`, `mic_in_use_stop`, `recording_ended_during_start`, `lifecycle_provisional_end_rescued` or `recording_resumed_after_end`, all of which the daemon emits at HEAD. The two automatic stops in that list, `mic_in_use_stop` (DET1's stop on mic release, `MeetingSessionController` emits it then calls `stopRecording`) and `recording_ended_during_start`, carry no `lifecycle/ended`, `auto_stop_silence` or `force_stop` inside the session window, so they are counted as manual misses.

**What it gets wrong on real logs.** On the work-laptop pack (2026-09-29 to 2026-11-13) recordings ended by a lifecycle verdict 63 times, by hand 10 times and by the silence backstop once ([2026-11-13-field-evidence.md](../../audits/2026-11-13-field-evidence.md), Sessions, prompts and end decisions). Of 16 ends followed by a same-app call within 15 minutes, 6 were false ends (the 4 era-1 storm chops at 7 to 86 s, a mic-switch end on 2026-10-22 that the owner repaired by hand after 23 s, and the 2026-11-11 Chrome stop); every one of them sits in the analyzer's detector-success column. Run over the owner's personal Mac log, the evidence file reports it pairs 3 sessions and prints the 17 s Zoom recording that the installed build ended while the call was live as Zoom's one detector success, with percentages on n = 3. It has no notion of a false end, fragmentation, a late end or an overrun, so era 3's 60 s tail on every Teams end and the 380 s overrun of `20261112-174606` are invisible to it.

Correction at filing: the batch summary cited "Teams reads 60 of 66 sessions as detector stops while 15 of 63 are followed within 10 minutes by a same-bundle prompt or re-recording". Neither figure appears in the audit reports, so this spec uses the field-evidence counts above (63 lifecycle-ended stops; 6 confirmed false ends among 16 same-app re-sightings within 15 minutes) instead.

## Scope

Rewrite the end dimension of `pipeline/src/mp/analyze_detection.py` (the start dimension and DET10's `no_spans` rendering stay):

1. **An independent call span per stop.** Build the truth span from rows the end decider does not produce: the microphone-holder ledger from DET23 (the always-on 1 Hz record of which process holds input) when present, else the per-process `signal/process_audio_is_running_input` rows and the scanner's `detector/discovery_shadow_pick` and `candidate_dropped` sightings for the same bundle. Read the stop's cause from [OBS5](./OBS5.md)'s stop cause on `recording_stopped` (with its 2026-11-13 amendment), falling back to today's inference for older logs.
2. **Judge each stop with a post-end watch window.** A stop is a false end when the same bundle's call span is still up at the stop or a same-bundle prompt, `recording_resumed_after_end` or recording follows within the watch window (default 10 minutes, a flag); a late end when the span ended more than N s before the stop. Score every lifecycle end against the recording's own bundle only.
3. **Report minutes, not just counts.** Per app, per week and per build era (the launch row once OBS5's amendment lands): false ends and fragments (one call, several stems), seconds lost to false ends, overrun minutes after the span ended, hold accounting by route (`lifecycle_end_held` opened, released, confirmed by pair, lone dwell or teardown, vetoed via `end_vetoed`), trim error (`held_end_trimmed` point against the span end), and stood-down backstops (`auto_stop_silence_skipped`). `mic_in_use_stop` and `recording_ended_during_start` become their own stop kinds, never manual misses.
4. **Keep it a pure pipeline.** `pair_sessions`, the classifier and `render_report` stay side-effect-free so fixtures drive them; `--json` carries every new figure.

Depends on DET23 (the ledger) and OBS5's stop cause; until DET23 lands, item 1's fallback rows are what the report uses, and it says which source it used.

## Explicitly not

- Scheduling the report or wiring it into CI. It stays an owner-run tool; [PIPE20](./PIPE20.md) owns moving it behind `mp dev`, and [HYG16](./HYG16.md) owns its duplicated `_parse_since` and import-time `DEFAULT_EVENTS_PATH`. Whichever lands second keeps both.
- The start dimension's dead mic-busy input: [DET10](./DET10.md).
- A run id across the daemon and `mp`: [OBS4](./OBS4.md).
- `scripts/extract_detection_trace.py --inventory`, which only knows sessions that close on `lifecycle.ended`: noted by the evidence file, not filed here.

## Acceptance

- `pipeline/tests/test_analyze_detection.py`, fixtures built from redacted pack rows (stems and event names only, no titles): (a) a Teams `lifecycle/ended` followed within the watch window by a same-bundle `prompt_shown` and recording scores as a false end with its seconds lost, not a detector success (the shape of the 2026-10-22 mic-switch end); (b) a `lifecycle/ended` from a Chrome engage inside a source-less session scores as a foreign end (the 2026-11-11 shape); (c) a held end confirmed 60 s after the mic release reports 60 s of overrun and the `held_end_trimmed` trim error; (d) `mic_in_use_stop` and `recording_ended_during_start` sessions are not manual misses; (e) a reverted hold (`lifecycle_end_hold_released`) is counted per route; (f) a window with no mic-busy spans still renders DET10's not-audited line.
- `test_pair_sessions_classifies_detector_triggered_stop` is rewritten to the new contract rather than deleted, and the docstring at the top of the module states the new rule.
- `cd pipeline && uv run --extra dev ruff check src tests`, `uv run --extra dev --extra mcp pyright` and `uv run --extra dev pytest -q` green, N new tests named in the commit body; `bash scripts/ci-local.sh pipeline` green.
- README's `mp analyze-detection` section and `ARCHITECTURE.md`'s `analyze_detection.py` row describe the new end judgement in the same commit.

**Progress (2026-11-16): shipped on the fallback rows, as the spec allows until DET23 and OBS5 land.**

- The call span is the recording bundle's `signal/process_audio_is_running_input` rows (the last reading at or before the end decides; a `false` reading is the span's end), and the report and `--json` name that source. The scanner sightings the spec lists as a second fallback were not used for the span: a `discovery_shadow_pick` or `candidate_dropped` says an app was seen, not that a call was up, so they would read an idle Teams as a live call; a same-app `prompt_shown`, `recording_started` or `recording_resumed_after_end` inside the watch window is used instead, as the spec's item 2 asks.
- `recording_stopped`'s OBS5 stop cause is read when present (`cause` or `stop_cause`) and carried into `--json`, but it does not override the inferred stop kind until OBS5 fixes its vocabulary.
- Per build era is not reported (it needs OBS5's launch row); per week is.
- A `lifecycle.ended` with no `bundle_id` (older rows) is still taken as the recording's own end. `pair_sessions` now sorts on the parsed instant, since a string sort put a `...36.500Z` stop ahead of a `...36Z` end.
- Remainder for a later session: replace the span source with DET23's ledger and the inferred stop kind with OBS5's cause once each exists, and add the era split.

## Amendment 2026-11-17 (post-audit fix review)

Found by the [post-audit fix review](../../audits/2026-11-17-post-audit-fix-review.md) (session report, M7). In `pipeline/src/mp/analyze_detection.py`, `pair_sessions` sets `open_session.foreign_ended_ts` on any foreign `lifecycle/ended` inside a session and `classify_session` gives `STOP_FOREIGN_END` precedence over force-stop and manual. Since END19 an ignored end (`meeting_end_ignored_sourceless`, and END11's `meeting_end_ignored_other_app`) leaves the recording running, so a later hand stop is reported as an automatic foreign-end stop. END19's and END21's owner walkthroughs read this report, so the misclassification hides what they look for. Scope addition: read the `meeting_end_ignored_*` rows, or require the foreign end to fall within about 2 s of `recording_stopped`. One new test with the 2026-11-11 shape.
