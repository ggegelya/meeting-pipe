# PIPE22: `mp` has no SIGTERM handler, so a user Cancel skips every `finally` and orphans a multi-GB `mlx_lm.server`, and the daemon only reaps on timeout

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([architecture review](../../audits/2026-10-24-architecture-review.md) M3). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Re-verified against `main` at `45b8c6a` on 2026-10-24.

**The signal.** A Cancel in the Library or the menu reaches `PipelineLauncher.cancelActiveRun()` (or `cancelAsk()` for `mp ask`), which calls `terminate(_:what:)`: `proc.terminate()` (SIGTERM), then SIGKILL after 10 s if the process is still alive. The pipeline watchdog in `runMP` does the same on overrun, with a 30 s grace.

**No handler.** `pipeline/src/mp/__main__.py`'s `main` catches `MissingSecretError`, `Exception` and `KeyboardInterrupt` (PIPE13's exit 130) and installs no signal handler; a grep of `pipeline/src` for `signal.signal` or a SIGTERM handler finds none. Python's default SIGTERM disposition kills the interpreter without unwinding, so no `finally`, no `__exit__`, and no `LocalSummaryClient.close()` runs.

**The orphan.** `LocalSummaryClient._spawn` starts `mlx_lm.server` with `preexec_fn=os.setsid`, so it is in its own session and SIGTERM to `mp` does not reach it. Only `_terminate_proc` kills it, from `close()`. After a Cancel during a local summary the server stays resident, holding the model's RAM (multi-GB for the 7B class), with only its LOCAL10 marker (`mlx-server.json`) left to name it.

**The reaper misses this path.** `LocalServerReaper.reapIfOrphaned()` runs from two places: the `runMP` termination handler, only when `timedOut.isSet`, and `Coordinator.reapStorage()`, which runs at launch and from `PipelineJobDispatcher`'s `onDone`. A cancelled job never reaches `onDone`: `PipelineJobDispatcher.route(job:result:)` returns early with `if PipelineLauncher.isCancellation(err) { return }`. So the orphan lives until the next successful job or the next launch. The reaper's own header comment says "The one path that does not is `PipelineLauncher`'s watchdog SIGKILLing a wedged `run-all`", which is no longer true, and the `reapStorage` doc comment repeats the watchdog-only story.

The daemon already classifies a cancel by its own flag, not the exit code (`PipelineLauncher.outcome(status:cancelled:...)` checks `cancelled` before anything else), so changing `mp`'s exit status on SIGTERM does not change what the Library shows.

## Scope

1. **Unwind on SIGTERM.** In `__main__.main`, before `_dispatch`, install `signal.signal(signal.SIGTERM, ...)` that raises `SystemExit(143)` (128 + 15, the shell convention, alongside PIPE13's 130). `SystemExit` is a `BaseException`, so the `except Exception` arms do not swallow it, every `finally` and context manager runs, and `LocalSummaryClient.close()` kills the server and clears its marker. Add `EXIT_TERMINATED = 143` beside `EXIT_INTERRUPTED` with the same "outside the daemon's exit vocabulary" comment.
2. **Keep `mp ask`'s interrupt contract.** `mp ask` checkpoints its embedding index (AI11), and the `KeyboardInterrupt` arm deliberately does no cleanup so the partial index survives. Check that unwinding on SIGTERM does not roll back or delete a partial index (the daemon SIGTERMs `mp ask` at 10 minutes); if any `finally` would, it is a bug this task fixes, not a reason to skip the handler.
3. **Reap on cancel too.** After a cancelled `runMP` completes, dispatch `LocalServerReaper.reapIfOrphaned()` off the termination queue, exactly as the timeout branch does. It is a no-op when the handler already cleaned up, and the backstop for a SIGKILL after the 10 s grace.
4. **Fix the two comments** (`LocalServerReaper`'s header and `Coordinator.reapStorage`'s doc) to name all three triggers: launch and job completion, watchdog timeout, user cancel.

## Explicitly not

- Making the daemon the only owner of `mlx_lm.server` (LOCAL21). That removes the orphan class at the root; this task is the cheap fix that stays useful after it, since every other `finally` in the pipeline also benefits.
- Changing the 10 s and 30 s SIGKILL graces. Measure first if the unwinding needs longer: a model server's SIGTERM-then-wait in `_terminate_proc` allows 10 s, which equals the cancel grace.
- Process-group signalling of `mp`'s own children from Swift. The handler is the Python-side owner's job.

## Acceptance

- `pipeline/tests/test_main_dispatch.py`: a subprocess test that starts `python -m mp` on a fake subcommand blocking inside a `try/finally`, sends SIGTERM, and asserts the `finally` ran (a sentinel file) and the exit status is 143. Fails on the current code (the sentinel is missing and the status is -15).
- A test, on the fake `mlx_lm.server` that `test_summarize_local.py` already uses, that SIGTERM during a local summarize leaves no live server pid and no `mlx-server.json` marker.
- `mp ask` interrupted by SIGTERM mid-index keeps the checkpointed rows (extend the AI11 resume test).
- `PipelineLauncherTests` or `LocalServerReaperTests`: a cancelled run triggers `reapIfOrphaned` (inject the reaper as a closure if the static call cannot be observed).
- `cd pipeline && uv run --extra dev pytest -q`, ruff and pyright green; `cd daemon && swift build` and `swift test` green; new test counts in the commit body.
- `CONVENTIONS.md`'s exit-code paragraph names 143 beside 130.

## Amended 2026-10-25 (observability audit band)

Added from the [2026-10-25 observability audit](../../audits/2026-10-25-observability-audit.md) (finder PY-12, low, latent). Re-verified against `main` at `01e904a` on 2026-10-25. This task's scope relies on `LocalSummaryClient.close()` killing the server and clearing its LOCAL10 marker; both kill paths clear the marker without checking the server died, so the reaper this task wires on cancel can be handed a clean slate while the server is still resident.

**`local_server.terminate_server`.** When `os.killpg(..., SIGTERM)` raises, the `except (OSError, ProcessLookupError)` arm logs `"SIGTERM to local model server %s failed: %s"` and falls through; when the 10 s wait expires, the SIGKILL attempt is `except (OSError, ProcessLookupError): pass`. Both paths then reach `clear_marker(home); return True` with no `is_server_pid(pid)` re-check after the ladder. The caller in `LocalSummaryClient`'s served-identity mismatch path treats the return as "gone" and respawns onto the same port.

**`LocalSummaryClient._terminate_proc`.** It calls `local_server.clear_marker()` before it signals anything (the comment says "drop its marker whether or not the kill below finds it already dead"), then SIGTERMs, waits 10 s and SIGKILLs, and an exception anywhere in that ladder is only `log.warning("error terminating mlx_lm.server: %s", e)`. No path confirms the process exited.

Either way a surviving multi-GB `mlx_lm.server` loses the only record that names it: `local_server.orphaned_server` (what `mp doctor` reports) and `LocalServerReaper` are both marker-based, so neither sees it. Signalling one's own setsid child rarely fails, which is why this is low, but a SIGKILL that does not land within the wait is exactly the wedged-server case this task's cancel path exists for.

**Added scope.**

5. **Clear the marker only on a confirmed exit.** After the kill ladder in both `terminate_server` and `_terminate_proc`, re-check (`is_server_pid(pid)` there, `proc.poll()` plus a short `proc.wait` after SIGKILL here) and clear the marker only when the server is gone. When it survives, keep the marker, return False from `terminate_server`, and emit `pipeline.local_server_survived_kill` with `pid` and which signal was last sent, so `mp doctor` and the daemon reaper still see it. `_terminate_proc` moves its `clear_marker()` after the confirmed exit; an already-dead process (`poll() is not None`) still clears it immediately.
6. **The respawn honours the result.** The served-identity mismatch path does not spawn onto the port when `terminate_server` returned False; it raises `LocalSummaryError` naming the surviving pid instead of colliding with it.

**Added acceptance.**

- A `test_local_server.py` case with `os.killpg` patched to raise `PermissionError` and `is_server_pid` stuck True: `terminate_server` returns False, the marker file is still present, and one `local_server_survived_kill` event is emitted.
- A `_terminate_proc` case on a fake process that ignores SIGTERM and SIGKILL (patched `wait` raising `TimeoutExpired` twice): the marker survives; the normal-exit case still clears it.
- `CONVENTIONS.md`'s LOCAL10 marker paragraph says the marker is cleared only on a confirmed exit.
