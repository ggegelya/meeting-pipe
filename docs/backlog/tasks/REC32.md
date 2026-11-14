---
id: REC32
title: The orphan sweep runs only after a successful non-retranscribe job or at launch, so a stop with no final file waits for an unrelated success, and stale orphans are re-reported after every job but never resolved or shown
category: Recording
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). D074: the no-final banner promises automatic recovery but reapStorage(orphanSweep: .afterJob) runs only from onDone, which route() calls for a successful non-retranscribe job; field: three 2026-06-12 stems logged "skipping stale orphaned recording" 415 times each, 12.8% of daemon.log, never resolved. Request the sweep from the stop funnel and from onJobSettled, report a stale orphan once per process as an event, and give the owner recover or quarantine.
---

# REC32: The orphan sweep runs only after a successful non-retranscribe job or at launch, so a stop with no final file waits for an unrelated success, and stale orphans are re-reported after every job but never resolved or shown

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Source findings: D074 in [2026-11-13-recording-reliability-audit.md](../../audits/2026-11-13-recording-reliability-audit.md) (low, code derived, not seen in the field), and the field findings "Stale orphan intermediates are re-reported after every job and never resolved" and "Event log has torn lines and the orphan sweep re-logs three June stems forever" in [2026-11-13-field-evidence.md](../../audits/2026-11-13-field-evidence.md). Both sit on one seam, `OrphanRecordingRecovery`'s sweep and what requests it. Re-verified at HEAD `3a2da4fc` on 2026-11-13.

**Half one: the promise is wider than the trigger (D074).** When a stop produces no usable final, `MeetingSessionController`'s stop path keeps the intermediates, writes the sidecar, and posts "Could not finalize ... The raw recording was kept and will be recovered automatically.", with a comment that "the sweep runs after every job completion, not only at the next launch". The sweep has two requesters: `Coordinator` at launch (`reapStorage(orphanSweep: .launch)`) and the `onDone` closure handed to `PipelineJobDispatcher` (`self.reapStorage(orphanSweep: .afterJob)`). `PipelineJobDispatcher.route` returns early for a re-transcribe (`guard job.kind != .retranscribe else { return }`) and calls `onDone` only on `case .success`; a failure, a cancel, a library re-run's failure and every re-transcribe never reach it. So the stem is recovered only when some later, unrelated meeting finishes successfully, or at the next launch, and with no queued work at all it waits for a relaunch (a launchd daemon runs for days; the field log has 12 launches in 45.9 days). The dispatcher already has the right hook: `SinkDispatcher.completeActiveJob` calls `onJobCompleted?(job, result)` on every completion path, and `PipelineJobDispatcher` forwards it as `onJobSettled`, today wired only to `statusBar.refreshFailedMeetingCount()` (PERF24). [HYG10](./HYG10.md) lists the comment as false (its RECORDING-6 row, "at launch and after every job completion" in `Coordinator.reapStorage`) and would only reword it; this task makes the comment and the banner true instead, so HYG10's row closes here.

**Half two: a stale orphan is reported forever and resolved never (field).** `OrphanRecordingRecovery.scanOrphanStems` drops a candidate with no `.recovery.json` or `.recordfail.json` marker whose intermediates are older than `maxOrphanAge` (24 h), and writes `Log.writeLine("daemon", "skipping stale orphaned recording \(stem) (no recovery marker, intermediates older than ...h)")` on every sweep. On the work laptop three stems recorded within 15 s of each other on 2026-06-12 (`20260612-121546`, `20260612-121559`, `20260612-121601`) were logged 415 times each from 2026-06-16 to 2026-11-13, 12.8% of `daemon.log`, last at 2026-11-13T07:44:02Z in the newest build. Nothing removes them, no event carries them, and the Diagnostics viewer (`DiagnosticsView`, a read-only view over the JSONL event logs) never shows them because `writeLine` is not an event.

**Correction at filing: the torn event lines are not this task's.** The same field finding reported 13 torn event lines; they predate PERF13's single locked O_APPEND writer (commit `e04c07b0`), which no installed build carries. They are left to the next field pack to confirm, not scoped here.

**Correction at filing: Diagnostics cannot offer an action.** The field recommendation was to list a stale orphan in Diagnostics and offer recover or discard there. `DiagnosticsView` is read-only by design (UX20: "No mutation, no follow"), so the listing is an event row it already renders, and the action needs its own surface (owner decision below).

## Scope

1. **Request the sweep where the promise is made.** Move the `.afterJob` request from `onDone` to `onJobSettled`, so a failed, cancelled, library-run or re-transcribe completion requests it too; `reapStorage`'s other work (originals, retention) moves with it, which is cheap and already detached. From the stop funnel, when the stop produced no usable final, request one `.afterJob` sweep after the recorder has handed the stem back (REC23's step 11, `ownedStems` no longer holding it), so a stop with an empty queue recovers without a relaunch. [REC24](./REC24.md)'s single-flight runner coalesces the two requests, and its attempt cap (`maxAfterJobAttempts`, 3, the stop-time failure counting as 1) bounds the extra retry; the pickup confirms a deterministic merge failure still reaches `orphan_recovery_gave_up` and stops.
2. **Banner copy matches the route.** Keep "will be recovered automatically" only if item 1 lands; correct the `Coordinator.reapStorage` comment in the same commit.
3. **Report a stale orphan once per process, as an event.** In `scanOrphanStems`, emit `coordinator`/`orphan_stale_found` (stem, age in days, which intermediates exist, their bytes) the first time a stem is skipped as stale in this process, and drop the per-sweep `writeLine` for stems already reported. A per-process set, not a persisted one, so each launch reports it once.
4. **Let the owner resolve it.** Recover runs the existing `OrphanRecordingRecovery.recover` path for that stem with the age cutoff waived; Discard moves the intermediates to a quarantine folder beside the library, never a delete. The surface is the owner's call (below); the pickup asks before building it.

## Owner decision (ask at pickup)

Where Recover and Discard live: (a) a once-per-launch notification naming how many stale recordings were found, with both actions; (b) the menu's failed-meetings row, which PERF24 already recounts on every settled job; or (c) neither, the event only, with the three June stems resolved by hand. (c) is the smallest and fits one owner with three stems; (a) and (b) need `docs/GUIDE.md` and the design kit to follow.

## Explicitly not

- Changing `maxOrphanAge` or the marker exemption: REC6's design, unchanged.
- Recovery that fails closed on missing or unreadable privacy markers: [REC21](./REC21.md) (amended in this band).
- The torn event lines: PERF13 at `e04c07b0`, pending field confirmation.
- Log retention and the noise that sets it: OBS9, filed in this band.
- [CONC5](./CONC5.md)'s ffmpeg ceilings and [REC14](./REC14.md)'s merge length fallback.

## Acceptance

- Controller or coordinator tests with injected sweep requests: a stop with no final followed by a failed job requests an `.afterJob` sweep and recovers the orphan; a stop with no final and no job at all requests one from the stop funnel and recovers it; a cancelled job and a re-transcribe each request one; a successful job requests exactly one (no double request), and REC24's coalescing still yields one run.
- A test that a deterministic merge failure on the recovered stem still stops at `maxAfterJobAttempts` and emits `orphan_recovery_gave_up` once.
- `scanOrphanStems` tests: a stale stem emits `orphan_stale_found` once per process across three sweeps and writes no further `skipping stale` line; a stem with a `.recordfail.json` marker is never reported as stale.
- If the owner picks (a) or (b): Recover on a stale stem produces a final through the normal path, Discard moves both intermediates into the quarantine folder and the next sweep reports nothing; `docs/GUIDE.md` names the control in the same commit.
- A source check that the banner copy and the `reapStorage` comment no longer claim a route that does not exist.
- `orphan_stale_found` documented in `CONVENTIONS.md`'s event-log section; `python3 scripts/truth_fences.py events` green. `cd daemon && swift build` and `swift test` green, with the number of new tests in the commit body; `bash scripts/ci-local.sh` green.

## Owner walkthrough

1. [owner] Answer the owner decision above before the pickup builds item 4.
2. [owner] On the work laptop, after a build with this change: confirm `orphan_stale_found` lists the three 2026-06-12 stems once in Diagnostics after launch, then recover or discard them (or move them by hand under (c)). Pass: the next day's `daemon.log` has no `skipping stale orphaned recording` line for them.
