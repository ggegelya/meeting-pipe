---
id: DET19
title: mp analyze-detection counts every lifecycle end as a detector success and ignores every event END9 to END17 added, so false ends, overruns and holds never show as minutes
category: Detection
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). The only detection reliability report labels a stop a detector success whenever any lifecycle.ended falls inside the session, with no truth source, so the 6 field false ends among 63 lifecycle-ended stops all read as successes, and pair_sessions reads five actions, none of the hold, veto, trim, rescue, resume or stand-down rows. Scope: rewrite the end dimension over the mic-holder ledger and OBS5's stop cause, judge each stop against an independent call span plus a post-end watch window, and report false ends, fragments, seconds lost, overrun minutes, hold accounting, trim error and stood-down backstops, keeping DET10's no_spans distinction, pinned by fixtures from redacted pack rows. [Spec](./DET19.md)
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
