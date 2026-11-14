---
id: OBS10
title: Slow post-stop episodes (finalize up to 53 s, ASR at 3x to 19x real time instead of 70x to 100x, mp launch up to 36 s) leave nothing in the logs to attribute them
category: Observability
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). 13 of 74 work-laptop recordings on 8 dates had a slow episode after the stop (finalize up to 53.0 s, ASR 3.3x to 18.9x real time against a normal 70x to 100x, engine_succeeded to mp run_started up to 35.9 s; worst 20261021-120034), spanning the merge and the Python start and overlapping no other work, and no row carries CPU time, thermal state, power mode, memory pressure or a spawn time; in 5 recordings the recorder's stop began 5 to 24 s after the decision with the mic still capturing. Scope: per-job CPU-versus-wall and machine-state rows for merge and ASR, a daemon row at mp spawn, a recorder stop_began row with its delay, and a re-check on the next field pack.
---

# OBS10: Slow post-stop episodes (finalize up to 53 s, ASR at 3x to 19x real time instead of 70x to 100x, mp launch up to 36 s) leave nothing in the logs to attribute them

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Sources: three field findings in [2026-11-13-field-evidence.md](../../audits/2026-11-13-field-evidence.md): "Era 2 stop and prompt paths stalled for seconds" (Sessions, finding 8), "Bursts of machine-wide slowness after a recording stops, concentrated on 7 dates in era B, with nothing in the logs to explain them" (Pipeline and publishing, finding 3), and, folded in, "In the two older builds the recorder's stop began 5 to 24 s after the app decided to stop, with the mic still capturing" (Mic, mute and capture, finding 6). None is in the [independent audit](../../audits/2026-11-12-independent-audit.md). Code re-read at HEAD `3a2da4fc` on 2026-11-13.

**The episodes.** 13 of 74 recordings between 2026-09-29 and 2026-11-13 had a slow stretch after the stop, on 8 dates: 2026-10-09 (1), 2026-10-15 (4), 2026-10-21 (1), 2026-10-22 (1), 2026-10-23 (1), 2026-11-04 (1), 2026-11-05 (1), 2026-11-06 (3). In them the stop decision to `recording_stopped` took up to 53.0 s (median over all 74 is 3.4 s; 12 took over 10 s, 11 of them in era B), transcription ran at 3.3x to 18.9x real time against a normal 70x to 100x, and `engine_succeeded` to Python's `run_started` took up to 35.9 s (median 1.5 s). Worst case `20261021-120034`: 52.0 s to finalize, 374.7 s of ASR for 1,221 s of audio, 33.0 s to launch `mp`, 465 s to publish. The slowness spans the ffmpeg merge before ASR and the Python start after it, so it is not the ASR pass alone. None overlapped another recording, and none had MCP, `ask` or digest activity within 2 minutes. By era: A 1 of 24, B 12 of 44 (27 percent), C 0 of 6 (stop 1.2 to 2.3 s, prompt 45 to 357 ms). The pattern clusters by day, not by build, and era C is too small to call clean.

**Nothing to attribute them with.** A grep of `daemon/Sources` and `pipeline/src` at HEAD finds no `thermalState`, `isLowPowerModeEnabled`, `getrusage`, memory-pressure source or compute-unit read. `engine_succeeded` (in `SinkDispatcher.runDaemonTranscription`) carries `file`, `engine`, `segments`, `audio_seconds` and `kind`, no wall or CPU time; the merge in `RecordingPostProcessor` logs only failures (`merge_timed_out`, `merge_too_short`); `PipelineLauncher.runMP` writes no event at spawn, so `engine_succeeded` to `run_started` cannot be split into the daemon's delay and Python's import time. The daemon passes no `computeUnits` to FluidAudio, so what the models were configured with is FluidAudio's default and what they actually ran on is unknown.

**The late recorder stop (folded in, low).** In 5 of 74 recordings `state_change` to stopping until `recorder`/`idle_sleep_assertion_released` (the first row inside the recorder's stop) took over 5 s: `20261009-173127` 24.5 s, `20261015-144207` 20.2 s, `20261021-120034` 8.9 s, `20261022-103101` 8.0 s, `20261021-103054` 5.4 s, median over all 74 0.34 s. In all five the mic file is as long as the span to that point, so 5 to 24 s of room audio after the decision is in the recording. In `20261009-173127` the wait held 9,684 halbus and re-resolve rows ([DET21](./DET21.md)'s storm); in three others a held-end row lands at the end of the wait. Era C: 0 of 6, max 0.40 s. At HEAD the synchronous main-thread stretch between `stateMachine.setStopping` and the Task that awaits `recorder.stop` in `MeetingSessionController.stopRecording` is `lifecycleCoord.disengage()`, `micGate.stop()` and `axWindowWatcher?.stop()`, with PERF15 and PERF24 already off it. Correction at filing: the delay is the main thread's, not the recorder's, and the newest build shows none; what is missing is a row that would show it, so the cut-at-decision fix is conditional below.

**Related.** Scheduling standing (no `ProcessType`, App Nap, the main thread measured at priority 20) is [PERF14](./PERF14.md), amended by this band, and is the leading hypothesis this task's rows would confirm or rule out. Neural Engine access for the agent on macOS 27 is [ASR8](./ASR8.md)'s spike. A false `pipeline_stalled` during a slow launch is [PIPE53](./PIPE53.md). A run id and stem on every row is [OBS4](./OBS4.md). The prompt-bracket half of the Sessions finding (state prompting to `prompt_shown` over 1 s in 8 of 357 era-1 and 6 of 55 era-2 prompts, max 8.1 s) is in PERF14's amendment.

## Scope

1. **Per-job resource rows.** For the merge (`RecordingPostProcessor`'s ffmpeg run) and the ASR pass (`SinkDispatcher.runDaemonTranscription` around `transcriptionRunner.transcribe`), record wall time and CPU time: the merge child's from `getrusage(RUSAGE_CHILDREN)` deltas around its wait (or the runner's `wait4` rusage once [CONC5](./CONC5.md)'s `ProcessRunner` exists), the ASR pass's from `getrusage(RUSAGE_SELF)` deltas. Add them to the existing completion rows (`engine_succeeded` gains `wall_ms`, `cpu_ms`, `rtf`; a new `recorder`/`merge_completed` carries `wall_ms`, `cpu_ms`, `audio_seconds`) together with a machine-state snapshot taken at the start and the end of each: `ProcessInfo.thermalState`, `isLowPowerModeEnabled`, the latest memory-pressure level from a `DispatchSource.makeMemoryPressureSource` the daemon keeps, and the configured compute units. A pure `ResourceSample` struct with a `cpuShare` computation keeps the arithmetic testable.
2. **A row at `mp` spawn.** `PipelineLauncher.runMP` emits `coordinator`/`pipeline_spawned` with the subcommand, the same machine snapshot, and `ms_since_engine` when it follows a transcription, so `engine_succeeded` to `run_started` splits into daemon delay and Python start.
3. **A row when the recorder's stop begins.** The first line of `MeetingRecorder.stop` emits `recorder`/`stop_began` with `delay_ms` since the controller's stop decision (a `systemUptime` stamp taken where `stopRecording` calls `setStopping`, passed in).
4. **Conditional cut.** If the next field pack shows `stop_began.delay_ms` over 2,000 ms on the landed build, trim the mic and system tracks at the decision time in the post-processor (the same trim seam END21 uses for held ends), with a `stop_trimmed` row; if it does not, record the numbers here and drop this item.
5. **Re-check and close.** On the next field pack, re-derive the three latencies (stop decision to `recording_stopped`, `engine_succeeded` to `run_started`, ASR real-time factor) per day; if era C's figures hold across at least 20 recordings, close the stall half of this task and keep only the rows.

Every new attribute is a number, an enum or a fixed string; no title or path beyond the existing `file` key.

## Explicitly not

- Changing the launchd `ProcessType` or taking an activity assertion: [PERF14](./PERF14.md), which these rows inform.
- Measuring Neural Engine dispatch per op (`MLComputePlan`): [ASR8](./ASR8.md). This task logs the configured units only.
- The stall watchdog's launch budget: [PIPE53](./PIPE53.md).
- A main-thread stall probe: [PERF11](./PERF11.md), which would show a blocked main during item 3's delay directly.
- Sampling machine state on a timer while idle. The snapshots ride the job rows, so an idle daemon writes nothing new.

## Acceptance

- `ResourceSampleTests`: `cpuShare` and `rtf` from fixed CPU, wall and audio figures, including a zero wall time and a CPU time larger than wall (multi-threaded ASR reads above 1.0, not clamped).
- `SinkDispatcherTests` with a fake runner: `engine_succeeded` carries `wall_ms`, `cpu_ms`, `rtf`, `thermal_state`, `low_power` and `memory_pressure`, from injected providers.
- A `RecordingPostProcessor` test: a successful merge emits `merge_completed` with `wall_ms`, `cpu_ms` and `audio_seconds`.
- `PipelineLauncherTests`: a run-all spawn after a transcription emits `pipeline_spawned` with `ms_since_engine`; a library re-run spawn emits it without.
- A `MeetingSessionControllerTests` case: `stop_began.delay_ms` reflects an injected delay between the decision stamp and the recorder's stop.
- The new actions and attributes in `CONVENTIONS.md`'s event table; `python3 scripts/truth_fences.py events` green.
- `cd daemon && swift build` and `swift test` green, N new tests named in the commit body; `bash scripts/ci-local.sh` green.

## Owner walkthrough

1. [session] Install the landing build on the work laptop (`./scripts/rebuild.sh`).
2. [owner] Use the app normally for two weeks; nothing to do differently. Cost: none.
3. [session] Pull the event log and, for each recording, tabulate merge and ASR `cpu_ms / wall_ms`, `rtf`, thermal state, low power and memory pressure, `pipeline_spawned` to `run_started`, and `stop_began.delay_ms`. Report slow episodes against their machine state here, decide Scope item 4, and propose closing or keeping the stall half per item 5.
