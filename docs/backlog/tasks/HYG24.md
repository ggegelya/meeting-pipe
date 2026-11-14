---
id: HYG24
title: valid1_check's report_timings pairs each run_completed with the oldest unclosed run_started, so one skipped or failed run corrupts every later run total
category: Validation
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). report_timings keeps run starts in a FIFO popped only on run_completed, while orchestrate ends five skip paths with run_skipped and three failure paths with run_failed; one skip then a 40 s and a 30 s run prints 21640.00 s and 68430.00 s (G019, reproduced). check_ux4 passes on the mic-channel degraded row and DIAR1 passes on an empty range (G048). Pair runs on wav with latest start winning, close on skip and fail, grade UX4 on the SCStream row only, and fail DIAR1 on no data. [Spec](./HYG24.md)
---

# HYG24: valid1_check's report_timings pairs each run_completed with the oldest unclosed run_started, so one skipped or failed run corrupts every later run total

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Source: [2026-11-12 independent audit](../../audits/2026-11-12-independent-audit.md) G019 ("report_timings pairs run_completed with the oldest unclosed run_started, so one skipped or failed run corrupts every later run total", confirmed) and, folded in, G048 from the low findings table ("UX4 and DIAR1 acceptance checks can pass without the behaviour they grade"). Re-verified at HEAD (`3a2da4fc`) on 2026-11-13. [`scripts/valid1_check.py`](../../../scripts/valid1_check.py) is the VALID1 acceptance helper the [runbook](../../validation/valid1-acceptance-runbook.md) grades the A15, A16, DIAR1 and UX4 bars with (VALID1, A15, DIAR1 and UX4 are archived in [q6-final.md](../q6-final.md)); a wrong number here is a wrong verdict on a shipped bar.

**1. Run pairing (G019).** `report_timings(pipeline_events)` keeps `open_runs: list[datetime]`, appends on `pipeline.run_started` and does `start = open_runs.pop(0)` only on `pipeline.run_completed`. `orchestrate.py` emits `run_started` with `wav=str(wav)` for every run and ends it with one of: `run_completed` (one site), `run_skipped` (five: `reason="no_speech"`, `"suspect_transcript"`, `"byo"`, `"too_long"`, `"apple_pending"`) or `run_failed` (three: a transcription error, `error_type="MissingSidecar"`, and `stage="publish"`). A skipped or failed run's start stays at the head of the FIFO, and the next completion pairs with it. Reproduced on 2026-11-13 by loading the script and feeding `run_started`/`run_skipped` for `a.wav` at 09:00, a 40 s `b.wav` run at 15:00, and a 30 s `c.wav` run the next day at 10:00: it printed `21640.00 s total` and `68430.00 s total`. A run killed outright (the daemon's watchdog SIGKILL) emits no terminal event at all, so closing on skip and fail alone does not fix pairing; keying by `wav` does. `test_valid1_check.py` has no `report_timings` coverage.

**2. Stage pairing.** `open_stages` is keyed by stage name only, and `stage_started`/`stage_completed` carry no `wav` (`orchestrate.py`, `finalize.py`). A failed run's dangling stage is overwritten by the next run's start of the same stage, so it does not corrupt a later row the way runs do; two overlapping runs would collide, which needs an emitter change to fix.

**3. UX4 (G048, verified).** `check_ux4` passes when any `recording.degraded` row exists. Two sites emit it in `Coordinator.swift`: `recorder.onSystemAudioDegraded` (`attributes: ["reason": reason]`, the SCStream failure UX4 grades) and, since REC16 item 3, `recorder.onConfigurationChange`'s `.failed` case (`attributes: ["channel": "mic"]`, a failed mic device change). A log with only the mic row passes UX4 without the behaviour it grades. CONVENTIONS.md's event-log section still says `recording` "carries exactly the two mid-recording capture-health transitions ... emitted from `Coordinator.onSystemAudioDegraded`", which the mic rows made stale.

**4. DIAR1 (G048; the audit row names it without a scenario, derived from code at filing).** `report_diar` prints `SKIP  no paired transcription.engine_started/succeeded events in range.` and returns True when `build_diar_report` found no runs. In the default all-sections mode `main` folds every section into `ok`, so a range with no transcription at all grades DIAR1 as passed. `check_ux4` already returns False on no data; DIAR1 is the inconsistent one.

Related: [OBS4](./OBS4.md) (no run id across daemon and `mp`, the proper key for stages), [HYG23](./HYG23.md) (the same script's coldstart teardown).

## Scope

1. **A pure `build_timings(pipeline_events) -> list[dict]`** beside `report_timings`, matching the script's `build_*`/`report_*` split. Runs pair on the `wav` attribute: `open_runs: dict[str, datetime]`, a later `run_started` for the same `wav` replaces the earlier one (a killed run never completes), and `run_completed`, `run_skipped` and `run_failed` each close their run. Rows carry the outcome (`completed`, `skipped (<reason>)`, `failed (<stage or error_type>)`); only completed runs print a total. A terminal row with no `wav` or no matching start is counted and reported in one note line, never paired. Stage pairing stays as it is.
2. **UX4.** `check_ux4` grades only rows that are not `channel == "mic"` (historic SCStream rows carry `reason` and no `channel`, so excluding the mic rows is the backward-compatible filter), and its output says how many mic-channel rows it excluded. CONVENTIONS.md's sentence names both emit sites and says UX4 grades the system-audio one.
3. **DIAR1.** `report_diar` returns False on no paired runs, printing `FAIL  no paired ... events in range; DIAR1 is not graded on no data.`, the same contract as `check_ux4`'s empty case.

## Explicitly not

- Keying stages per run: stage events carry no `wav`, and adding a run id to every event is [OBS4](./OBS4.md).
- Failing DIAR1 on `engine_failed` rows: a failed run has no latency to grade, and the count is already printed.
- A `channel: "system"` attribute on the SCStream emitter: an event-schema change for a grading script's convenience.
- The coldstart teardown and candidate files: [HYG23](./HYG23.md).

## Acceptance

- `pipeline/tests/test_valid1_check.py`: `build_timings` on the G019 log (one skip, then 40 s and 30 s runs) gives totals 40.0 and 30.0 and one skipped row; a `run_failed` closes its run; interleaved starts for two wavs pair each with its own completion; a start with no terminal event followed by a fresh start for the same wav pairs the completion with the later start; a completion with no start is counted in the note, not paired. `check_ux4` on only a `channel: "mic"` degraded row returns False, and with a `reason` row returns True. `report_diar` on events with no paired runs returns False. The existing `test_diar_skips_the_empty_recording_that_succeeds_with_no_audio` pins `build_diar_report`'s `runs == 0`, not the verdict, and stays as it is. About 8 new tests.
- `cd pipeline && uv run --extra dev pytest -q` green; `uv run --extra dev ruff check src tests` green.
- CONVENTIONS.md's `recording` sentence updated in the same commit; `python3 scripts/truth_fences.py events` green.
