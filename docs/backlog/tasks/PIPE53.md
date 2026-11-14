---
id: PIPE53
title: The pipeline stall watchdog is armed at spawn on a 30 s threshold, so a slow launch shows Stalled on a healthy run while a request hung for 124 s raised nothing
category: Pipeline
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). Both pipeline_stalled rows in 45 days are launch-time false alarms (20261021-120034 at 30.08 s on a healthy 56.8 s run, 20261022-103101 at 30.12 s), and the latter's summarize request hung 124.4 s while the timer-thread heartbeat beat 24 times, so no stall was raised; one false flag also spends the watchdog for the rest of the run. Start the stall clock at the first heartbeat under its own launch budget, and make the beat carry how long the current stage has gone without progress so a beating-but-stuck request is flagged.
---

# PIPE53: The pipeline stall watchdog is armed at spawn on a 30 s threshold, so a slow launch shows Stalled on a healthy run while a request hung for 124 s raised nothing

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Source: the field-evidence finding "The stall watchdog flagged two healthy runs and missed the one request that hung" in [2026-11-13-field-evidence.md](../../audits/2026-11-13-field-evidence.md) (section Pipeline and publishing, finding 2), over the daemon log window 2026-09-29 to 2026-11-13. Re-verified in code at HEAD `3a2da4fc` on 2026-11-13.

**What the field shows.** Both `coordinator` `pipeline_stalled` rows in the window are launch-time false alarms, both in era B on slow-episode days. `20261021-120034`: flagged 30.08 s after `engine_succeeded`, `run_started` 2.90 s later, first heartbeat 7.99 s after the flag, run completed in 56.8 s and published. `20261022-103101`: flagged at 30.12 s, `run_started` 5.83 s later, first heartbeat 11.04 s after the flag. Engine_succeeded to first heartbeat exceeded 30 s in 2 of 71 runs with heartbeats and 20 s in 4; the mp launch latency (engine_succeeded to `run_started`) is median 1.5 s, p90 6.5 s, max 35.9 s. In that same `20261022-103101` run, the summarize request hung from `stage_started` at 07:47:46.9Z on 2026-10-22 until `run_failed` with `error_type` `APITimeoutError` 124.4 s later, and the heartbeat thread emitted 24 `summarize` beats across it, so no stall was raised for the one real hang. Heartbeats otherwise arrive every 5.1 s (968 gaps, 1 over 10 s, 0 over 30 s). Healthy stage durations over 110 completed runs: `diarize_cleanup` median 12.1 s, p90 34.3 s, max 54.2 s; `summarize` median 34.6 s, p90 53.0 s, max 77.4 s (largest transcript, 70,332 chars).

**Why the timer fires on launch.** `SinkDispatcher.invokePipeline` calls `startStallTracking(stem:)` before `launcher.runAll`, and `startStallTracking` sets `lastProgressAt = Date()`, so the clock starts at spawn. `stallThresholdSec` is a `private static let` of 30, documented as "The pipeline beats every 5 s, so 30 s is six missed beats". The pipeline's first beat comes 5 s after `orchestrate.run_all` starts `_ProgressHeartbeat().start()`, which is after the interpreter start, imports, `entry.prepare` and the `run_started` emit. Any launch over about 25 s therefore trips the 5 s repeating timer.

**Why the hang beats.** `orchestrate._ProgressHeartbeat._run` is a daemon thread that loops on `self._stop.wait(self._interval)` and calls `events.emit_progress(stage, elapsed_s=elapsed, beat=beat)`, with `elapsed` measured from the heartbeat's own start. `set_stage` is only called at stage boundaries by `_run_all_inner`, so nothing on a beat advances with real progress: a request blocked inside `summarize` produces beats identical in shape to a healthy one. The daemon's `PipelineLauncher.parseProgress` reads `stage`, `elapsed_s` and the optional `stems_done` / `stems_total`, and ignores other keys, so a new key is additive on the wire.

**Correction at filing (two details the finding did not state).** First, the red pill is short-lived but the watchdog is spent: `Coordinator`'s `onProgress` rebuilds `ActiveProcessing` with `stalled: false` on the next beat, so the false Stalled pill showed for about 8 s and 11 s, but `SinkDispatcher.stalledFired` stays true until `stopStallTracking`, so after a launch false alarm a genuine heartbeat lapse later in the same run can never fire `pipeline_stalled`. Second, the comment above that `onProgress` closure says it will "Preserve a prior stalled flag if a late beat arrives after stalling", which the code beside it does not do.

**The 124 s hang itself** ended at the 120 s Anthropic read timeout with no retry by design and no fallback; that is owned by [PIPE24](./PIPE24.md) (client timeout and retry policy). This task is only about the daemon telling the truth while it happens.

Related: [PIPE36](./PIPE36.md) (done) made the Apple Intelligence phase beat `onProgress` once per call through the same timer, which this task must keep working; [UX69](./UX69.md) owns the row's phases before the first heartbeat (`spawnedStage` "starting"); [OBS10](./OBS10.md) (filed in the same band) owns the slow post-stop episodes that produced these long launches; the independent audit's F079 is the analogous gap inside `summarize_local`.

## Scope

1. **Two clocks in `SinkDispatcher`, both injectable.** Replace the single `stallThresholdSec` with a launch budget and a beat-gap threshold, injected through `SinkDispatcher.init` with production defaults, the same way PIPE36 injected `transcriptionDeadline` (`deadlineFor`), plus an injectable clock (or tick interval) so tests do not wait 30 s. From spawn until the first `onProgress` beat, the stall check compares against the launch budget; from the first beat on, against the existing 30 s gap. The launch budget must sit well above the worst observed launch (first heartbeat at about 38.1 s and 41.2 s after `engine_succeeded` on the two flagged runs); the pickup session sets the number and records it, with its reason, beside the constant. A launch that never beats within the budget is still flagged, so a wedged interpreter start stays visible.
2. **Re-arm after recovery.** A beat that arrives after a stall clears `stalledFired`, so the watchdog can fire again later in the same run, and `pipeline_stalled` carries a `phase` attribute (`launch`, `beat_gap` or `no_progress`, see item 3) so the two field shapes are tellable apart in `events.jsonl`. Fix or delete the misleading comment in `Coordinator`'s `onProgress` to match what the code does.
3. **A beat that says how long the current stage has gone without progress.** In `orchestrate._ProgressHeartbeat`, record a monotonic timestamp in `set_stage` and add a `mark_progress()` that moves it; emit `stage_elapsed_s` (seconds since that timestamp) on every beat through `events.emit_progress`'s `**extra`. Call `mark_progress()` from the points that already know a unit of work finished: each completed cleanup window and each completed summarize call (map, reduce and repair calls included), through the `heartbeat` handle `_run_all_inner` already holds. `PipelineProgress` gains an optional `stageElapsedSec`, parsed in `PipelineLauncher.parseProgress`. `SinkDispatcher` flags `no_progress` when a beat's `stageElapsedSec` passes a no-progress budget that sits above the healthy maxima above (cleanup 54.2 s, summarize 77.4 s per stage); the pickup derives the number from the field durations and records it.
4. **The row says how long the request has waited.** While stalled on `no_progress`, `ProcessingPresentation.label` renders the stage and `stageElapsedSec` (for example "Summarizing, no reply for 1:40") instead of the whole-run elapsed, so the owner can tell a slow request from a dead one. Copy follows `docs/GUIDE.md`'s register and is added there in the same commit.

## Explicitly not

- Retrying or failing over the hung request: [PIPE24](./PIPE24.md). Killing the run on a stall: the stall flag stays advisory, as UX5 built it; Cancel already exists for a running job.
- Making the launch itself faster or explaining the slow era-B launches: [OBS10](./OBS10.md).
- Heartbeats for `mp summarize` and `mp publish` Library re-runs, which have none and carry their own label (UX28).
- A per-request event row in `events.jsonl`. `stage_elapsed_s` on the existing `pipeline` `stage_progress` beat is enough for the row and for postmortems; a request-level event is OBS4's run-id territory if it is ever wanted.
- Changing the 5 s beat interval or the 30 s gap threshold once beats are flowing; the field shows 0 gaps over 30 s in 968.

## Acceptance

- `SinkDispatcherTests` with injected budgets and clock: a run whose first beat arrives after 35 s (scaled) emits no `pipeline_stalled` and never sets the row stalled; a run that never beats past the launch budget emits `pipeline_stalled` with `phase` `launch`.
- The same suite: after a beat-gap stall, a beat clears it and a second gap fires `pipeline_stalled` again in the same run (fails on `main`, where `stalledFired` latches).
- The same suite: beats that keep arriving every tick with `stageElapsedSec` growing past the no-progress budget emit `pipeline_stalled` with `phase` `no_progress` and mark the row stalled, and a beat whose `stageElapsedSec` drops back (progress marked) clears it.
- A PIPE36 regression guard: the Apple Intelligence phase's per-call `onProgress` beats keep a healthy Apple run unflagged.
- `PipelineLauncherTests`: `parseProgress` reads `stage_elapsed_s` into `stageElapsedSec`, and a beat without it parses as before.
- `pytest`: `_ProgressHeartbeat` emits `stage_elapsed_s` that resets on `set_stage` and on `mark_progress`, and keeps growing while neither is called; a run-all test with a stub summarize call that blocks shows `stage_elapsed_s` growing across beats.
- `ProcessingPresentation` test for the no-progress label.
- `pipeline_stalled`'s `phase` attribute is documented in `CONVENTIONS.md`'s event table, and `python3 scripts/truth_fences.py events` is green; `docs/GUIDE.md` section 10 says what the Stalled pill means, in the same commit.
- `cd daemon && swift test` green, `cd pipeline && uv run --extra dev pytest -q`, ruff and pyright green, with the number of new tests in the commit body; `bash scripts/ci-local.sh` green.
