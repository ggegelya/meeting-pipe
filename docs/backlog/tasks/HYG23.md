---
id: HYG23
title: valid1_check's coldstart watchdog SIGKILLs a process group that does not contain the model server, leaving it resident in the low-memory case it exists for
category: Validation
status: partial
priority: P2
comment: Shipped 2026-11-17 (awaiting owner): valid1_check --coldstart supervises mp summarize (stdin pipe + MP_SUPERVISED=1), stops it SIGTERM-first through _stop_run (group poll, 20 s grace, then SIGKILL) on the low-memory abort, the timeout and Ctrl-C, reaps this run's model server from mlx-server.json (spawned after start, pid still a server), refuses on a pending candidate and removes the candidates it wrote. Remainder: the owner walkthrough (Ctrl-C mid cold run, then a full run). [Spec](./HYG23.md)
---

# HYG23: valid1_check's coldstart watchdog SIGKILLs a process group that does not contain the model server, leaving it resident in the low-memory case it exists for

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Source: [2026-11-12 independent audit](../../audits/2026-11-12-independent-audit.md) G022 ("valid1 --coldstart watchdog SIGKILLs the client's process group, which does not contain the model server", confirmed) and, folded in, G051 from the low findings table ("Interrupting valid1 --coldstart leaves the model run alive in its own session, and each run writes candidate summaries into the live library"). Re-verified at HEAD (`3a2da4fc`) on 2026-11-13.

**The watchdog (G022).** [`scripts/valid1_check.py`](../../../scripts/valid1_check.py)'s `_run_timed(argv, label)` starts `subprocess.Popen(["caffeinate", "-i", *argv], ..., start_new_session=True)`, so caffeinate, the `mp` it forks (and `uv` when `resolve_mp()` falls back to `uv run`) share one new process group. On free memory under `MIN_FREE_MEMORY_PCT = 10.0` the watchdog thread runs `os.killpg(proc.pid, signal.SIGKILL)`, and on `COLDSTART_TIMEOUT_SEC = 900.0` the timeout branch does the same. `run_coldstart` runs `mp summarize <transcript> --backend local --candidate`, and `LocalSummaryClient._spawn` in `summarize_local.py` starts `mlx_lm.server` with `preexec_fn=os.setsid`, then writes `~/Library/Logs/MeetingPipe/mlx-server.json` through `local_server.write_marker` (`pid`, `owner_pid`, `port`, `model`, `adapter_path`, `spawned_at`). The server is in its own session, so the SIGKILL never reaches it, and SIGKILL cannot be caught, so `mp`'s PIPE22 SIGTERM unwind and `LocalSummaryClient._terminate_proc` never run. Result on both paths: the model stays resident on `:8765` with a marker whose `owner_pid` is dead. On the low-memory path that is the opposite of what the guard is for (its comment: "the 14B has OOM-hung this Mac"); the machine keeps swapping until the daemon's LOCAL10 reaper kills it (`mp doctor` only reports the orphan), and neither runs from this script.

**Ctrl-C (G051, verified).** `_run_timed` blocks in `proc.wait(timeout=...)` with no `KeyboardInterrupt` handling. Because the child is in a new session, the terminal's SIGINT reaches only the script, which exits; caffeinate, `mp` and the server keep running unattended. (In the warm phase the `finally` in `run_coldstart` does SIGTERM the `mp serve-local` group, so only the summarize child is orphaned there.)

**Candidates in the live library (G051, verified, narrowed).** Both runs pass `--candidate`, so `summarize` writes `<stem>.summary.candidate.json` and `.md` beside the live summary in the recordings directory (`out_suffix="candidate"`, atomic, 0600); the live summary is not overwritten. Correction at filing: the app does not surface a leftover candidate on its own. `SummaryTab` loads it only after an in-app "Re-run locally (preview)", and `MeetingLibraryService` consumes it through `keepCandidate(stem:)` or deletes it in `discardCandidate(stem:)`, both reached only from that preview. So the effect is a stray copy of meeting content beside the live files that nothing removes, and an existing in-app preview for that meeting is silently overwritten by the measurement.

**The supervision contract already exists.** PIPE37 (`__main__._start_supervision`, `_watch_supervisor_stdin`) arms a stdin watcher when `MP_SUPERVISED=1` is in the environment: on EOF it SIGTERMs `mp`'s main thread, and PIPE22's handler unwinds every `finally`, including the server teardown. The kernel closes the write end however the parent ends, so a parent that spawns `mp` with a stdin pipe and that variable gets teardown on Ctrl-C, crash or SIGKILL for free. The variable is popped, so nothing `mp` spawns inherits it.

**Constraints.** The script is stdlib-only by design (its docstring: "Stdlib only, so it runs on a clean Mac without `uv`") and is loaded by path in `pipeline/tests/test_valid1_check.py`, which CI runs on Linux, where there is no `caffeinate`. It therefore cannot import `mp.local_server` and must re-implement its identity check (`is_server_pid`: `/bin/ps -o command= -p <pid>` contains `mlx_lm.server`).

Related: [LOCAL21](./LOCAL21.md) (the setsid server's two owners, the general case), [PIPE22](./PIPE22.md) (done: SIGTERM unwind), LOCAL10 (done, in [q6-final.md](../q6-final.md): the marker and reaper).

## Scope

1. **Supervise the child.** `_run_timed` spawns with `stdin=subprocess.PIPE` and `env={**os.environ, "MP_SUPERVISED": "1"}`. Any exit of the script then closes the pipe and `mp` unwinds itself, server included. CONVENTIONS.md's "Supervised spawns (PIPE37)" section, which describes the contract only from `PipelineLauncher`'s side, gets one sentence naming this script as the second supervisor.
2. **Stop SIGTERM-first.** A `_stop_run(pgid, started_at, ...)` helper with injectable `killpg`, `pid_command`, `marker_path`, `sleep` and clock, called on the low-memory abort, the timeout and `KeyboardInterrupt`: close the stdin pipe and SIGTERM the run's group; poll the group (`os.killpg(pgid, 0)`), not `proc.wait()`, since caffeinate exits on SIGTERM before `mp` finishes unwinding, calling `proc.poll()` on each tick so an exited but unreaped caffeinate does not keep the group looking alive, for up to a `STOP_GRACE_SEC` above `local_server.terminate_server`'s ~10 s ladder (about 20 s); then SIGKILL any survivor in the group.
3. **Reap this run's server.** After that, read `mlx-server.json` by path; if its `pid` is still an `mlx_lm.server` by the `ps` check and its `spawned_at` (written with `time.time()`) is not earlier than a wall-clock `time.time()` start captured at spawn (not `_run_timed`'s `time.monotonic()` `started`, which is on another clock), SIGTERM its group, wait, then SIGKILL. A marker from before the run, or a pid that is no longer a server, is left alone (a recycled pid is never signalled). `_run_timed` re-raises the `KeyboardInterrupt` after `_stop_run`, so Ctrl-C still ends the script.
4. **Candidates.** `run_coldstart` refuses to start when `<stem>.summary.candidate.json` already exists for the picked transcript (a pending in-app preview), naming it; otherwise it removes the candidate `.json` and `.md` it produced once both runs are done, on every exit path.

## Explicitly not

- Making the daemon the only owner of `mlx_lm.server`: [LOCAL21](./LOCAL21.md). This task only stops one script leaking it.
- Summarizing a temp copy of the transcript instead of `--candidate`: copying meeting content to a temp directory is a worse privacy trade than deleting the candidate afterwards.
- The `mp serve-local` teardown in the warm phase, which already SIGTERMs its group.
- valid1_check's grading bugs (`report_timings`, `check_ux4`, DIAR1): [HYG24](./HYG24.md).

## Acceptance

- `pipeline/tests/test_valid1_check.py`, with fakes for the injected seams, Linux-safe: (a) a group that exits within the grace gets SIGTERM and no SIGKILL; (b) a group that survives the grace gets SIGKILL; (c) a marker naming a live `mlx_lm.server` spawned after the run started gets SIGTERM on its own group; (d) a marker spawned before the run, or whose pid's command is not `mlx_lm.server`, is not signalled; (e) `_run_timed` with a fake `Popen` passes `stdin=PIPE` and `MP_SUPERVISED=1`, and a `KeyboardInterrupt` raised from the wait calls `_stop_run` and propagates; (f) `run_coldstart` refuses on an existing candidate and removes the candidates it wrote when the fake runs return. About 7 new tests.
- `cd pipeline && uv run --extra dev pytest -q` green; `ruff check src tests` green; the script still imports only the standard library (the existing CI load of the script is the check).

## Owner walkthrough

1. [owner] With nothing serving on `:8765`, run `scripts/valid1_check.py --coldstart` and press Ctrl-C a few seconds into the cold run. Within about 20 s `pgrep -f mlx_lm.server` prints nothing and `mp doctor` reports no orphan server.
2. [owner] Run it to completion; afterwards no `<stem>.summary.candidate.json` remains beside the picked transcript.

**Progress (2026-11-17):** Scope 1 to 4 shipped with the acceptance tests (11 new in `test_valid1_check.py`, Linux-safe through injected `killpg`, `pid_command`, `marker_path`, `sleep` and clock). One correction to the spec: since SEC27 the server runs as `python -m mp.local_model_server`, so the script's identity check accepts both that and `mlx_lm.server`, mirroring `local_server._SERVER_COMMAND_MARKS` (a check on `mlx_lm.server` alone would never have matched a current server). The watchdog and the main thread can both reach the stop; the second waits for the first rather than returning while the run is still alive. The candidate check refuses on either the `.json` or the `.md`, and the removal runs in a `finally` around both timed runs. Found in review and fixed: the low-memory abort now waits for its own stop (the watchdog is a daemon thread, and the wait returned as soon as caffeinate died on the SIGTERM, before the SIGKILL fallback and the reap); the reap also requires the marker's owner to have been in this run's group when the stop began, falling back to the time window only when the owner is already gone; candidate names come from the resolved path's `stem`, as `mp summarize` builds them; a second Ctrl-C during the grace skips the SIGKILL and the reap, which is documented, since the stdin EOF has already told `mp` to unwind. The owner walkthrough above is what remains; it needs the local model and a real run, so no harness covers it.
