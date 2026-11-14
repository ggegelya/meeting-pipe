---
id: PIPE46
title: After PIPE36 and PIPE37: an abandoned transcription pass keeps its runner, models and audio resident, and quit signals supervised runs once with no backstop while other spawns go unsignalled
category: Pipeline
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). Code-derived, never seen in the field. An abandoned FluidAudio pass keeps its runner, its models and the meeting's whole sample array resident indefinitely if it never returns, and nothing records whether it does. In mp, `_on_sigterm` says "The daemon's SIGKILL after its grace stays the backstop", which is false once the daemon has quit. So a wedged unwind, or an unsupervised digest, actions, roster, backup or restore spawn, has no bound once the app is gone. Fix: a late-return event plus an outstanding-pass count, a hard exit after the supervisor EOF grace, and an mp-side deadline taken from runMP's timeout. The relaunch check stays rejected, as PIPE37 decided.
---

# PIPE46: After PIPE36 and PIPE37: an abandoned transcription pass keeps its runner, models and audio resident, and quit signals supervised runs once with no backstop while other spawns go unsignalled

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Sources: G044 (performance) and G045 (architecture) in [2026-11-12-independent-audit.md](../../audits/2026-11-12-independent-audit.md). Both appear there only as table rows, with no claim text. Everything below was re-read at HEAD `3a2da4fc` on 2026-11-13, against the specs of [PIPE36](./PIPE36.md) (done, `4949c9c0`) and [PIPE37](./PIPE37.md) (done, `3bd0249a`). Much of what the two rows say was a decision recorded in those specs. This task files only what goes past those decisions.

**1. Abandoned transcription pass (G044).**

What happens at HEAD: on a transcribe-phase expiry, `SinkDispatcher.deadlineExpired` does three things:

- calls `transcriptionRunner.abandonInFlightPass()`;
- replaces the runner (`transcriptionRunner = makeTranscriptionRunner()`);
- cancels `transcriptionTask`.

`FluidAudioRunner.abandonInFlightPass` only finishes the REC20 memory row, marked `abandoned`. It frees nothing. The stuck pass's frame still holds:

- the runner itself;
- its `AsrManager` and `DiarizerManager` with their loaded models;
- `samples`, the whole meeting as a mono `[Float]` from `readMonoFloat32`. That is about 422 MB for a 110-minute meeting and about 690 MB for 3 hours, at 16 kHz times 4 bytes.

If the pass is wedged in the synchronous `diarizer.performCompleteDiarization`, it also holds a cooperative-pool thread.

Correction at filing: PIPE36 item 4 accepted that "Model memory is briefly doubled while the old call is stuck (461 MB plus 13 MB of models on disk, measured 2026-10-25)", and PIPE36's Explicitly not rules out killing a stuck CoreML call. What goes beyond that accepted cost:

- **The sample array.** It was not counted, and on a long meeting it is larger than the models.
- **"Briefly" is unknown.** A pass that never returns keeps all of it until the app restarts.
- **Nothing tells a pass that came back from one that never will.** A late return reaches `logLateReturn`, which writes only a file-log line with no event. The `transcription_memory` idle reading that `TranscriptionMemoryProbe.finish` schedules after the abandon is cancelled by the next job's own probe (`pendingIdle`'s `cancel()`), and the next job starts at once.
- **Repeated abandons stack.** A second transcribe-phase expiry builds a third runner with no count anywhere.

The "releases its runner" acceptance the audit implies cannot be met for a wedged pass. The bar here is observability plus a regression pin for the pass that does return.

**2. Quit and the unsupervised spawns (G045).**

What happens at HEAD:

- `PipelineLauncher.terminateSupervised` sends `terminate()` (SIGTERM) once to each live supervised spawn and returns.
- `runMP`'s watchdog, which sends SIGTERM and then SIGKILL 30 s later, is a timer inside the app, so it dies with it.
- `PipelineLauncher.isSupervised` leaves out backup, restore, digest, actions and roster spawns. They get no stdin pipe and no signal.
- On relaunch, `reconcileStrandedJobs` labels a meeting interrupted without checking that the old `mp` is gone.

Correction at filing: three of those four points were PIPE37's own decisions.

- SIGTERM only, because the 9 s termination ceiling cannot afford a grace period.
- The excluded spawns, because "a restore stopped midway is worse than one that completes unsupervised".
- The relaunch check: PIPE37's Explicitly not rejects a pidfile, because `ps` identity probing is the class [LOCAL21](./LOCAL21.md) is deleting. It names the Retry-inside-the-unwind residual and leaves it unfixed.

None of these are refiled here.

What is new:

- **The backstop does not exist.** `_on_sigterm` in `pipeline/src/mp/__main__.py` is one-shot (`signal.signal(signal.SIGTERM, _ignore_repeat_sigterm)`, so a later SIGTERM does nothing) and its docstring says "The daemon's SIGKILL after its grace stays the backstop". On the quit path, and on the supervisor-EOF path (`_watch_supervisor_stdin`, which `signal.pthread_kill`s the main thread once), there is no daemon left to send that SIGKILL. A `finally` that blocks, or a main thread inside a long native call that never returns to the eval loop, therefore runs with no bound. That makes PIPE37's named residual (a Retry landing inside the unwind) unbounded rather than "bounded by the local server's 10 s close".
- **The excluded spawns lose their ceiling.** Each one has a `runMP` timeout while the app lives: `storageJobTimeout` for backup and restore, 10 minutes for digest, 2 minutes for actions, 30 s for roster forget and rename. Once the app is gone they have none. A digest or restore hung on a network or iCloud read then runs as an orphan forever.

**Field.** Not observed. The field pack lists G009, PIPE36 code, as newer than any installed build, so no field build has run the deadline these legs follow ([2026-11-13-field-evidence.md](../../audits/2026-11-13-field-evidence.md), "Not seen" list).

Related:

- [PIPE45](./PIPE45.md) shares `logLateReturn`'s redaction-phase call site. The event in item 1 is how a late redaction becomes visible there.
- [CONC5](./CONC5.md): the per-process runner.
- [UX82](./UX82.md): exit status and the termination ceiling.
- [LOCAL21](./LOCAL21.md): mlx server ownership.

## Scope

1. **A late return becomes an event (G044).** `abandonedJobs` records when each job was abandoned, and with which phase. `SinkDispatcher.logLateReturn` emits `transcription_late_return` (category `transcription`) with `file`, `phase` and `seconds_after_deadline`, alongside its existing file-log line. This covers every call site, including PIPE45's redaction path.
2. **Count the passes still out (G044).** `transcription_timed_out` gains `abandoned_outstanding`: the number of transcribe-phase passes that were abandoned and have not yet returned when this one expires. The count goes down on item 1's event. No cap and no refusal: the row's reason already tells the owner to quit and reopen if it repeats.
3. **Correct the accepted cost (G044).** The comment in `deadlineExpired` on replacing the runner, and the `abandonInFlightPass` doc in `TranscriptionRunner`, name what a stuck pass keeps (models plus the sample array plus, for a synchronous wedge, a pool thread) and that it lasts until the pass returns or the app exits.
4. **A hard exit owned by mp (G045).** In `pipeline/src/mp/__main__.py`, once `_watch_supervisor_stdin` reads EOF, it starts a timer before sending its SIGTERM. When the timer ends, it calls `os._exit(EXIT_TERMINATED)`.
   - The grace is a named constant, set to the 30 s that `runMP`'s watchdog allows.
   - An orderly quit also ends in EOF (the kernel closes the write end at `exit`), so this one path covers quit, crash, SIGKILL and the ceiling.
   - `_on_sigterm`'s docstring says which backstop applies in each case.
5. **An mp-side ceiling for every spawn (G045).** `PipelineLauncher.runMP` exports its `timeout` to every spawn, supervised or not, through a new environment key (the pickup names it, next to `MP_SUPERVISED`).
   - `mp`'s `main` pops that key and arms a timer for timeout plus 60 s. When the timer fires, mp SIGTERMs its own main thread, and item 4's hard exit follows after the grace.
   - The extra 60 s means the daemon's own watchdog always fires first while the app lives. So the only new behaviour is that a spawn that outlives the app keeps the ceiling it already had.
   - Backup and restore therefore keep PIPE37's "left to finish" posture and gain only that ceiling.
   - Manual CLI runs set no key and are unchanged.
   - `mp serve-local`'s server is a grandchild and is out of this key's reach, as it is out of `MP_SUPERVISED`'s.

## Explicitly not

- A relaunch check that the old `mp` is gone (pidfile or `ps` probe). PIPE37 rejected it, and LOCAL21 is removing that class of probe. With items 4 and 5, the residual is bounded by the grace.
- Signalling backup or restore at quit. PIPE37's reason stands.
- Killing a wedged CoreML or diarizer call, or capping how many runners may exist: PIPE36 rules out the first, and there is no field evidence that any abandon has ever happened.
- A SIGKILL from the daemon after quit. The 9 s ceiling is UX82's.

## Acceptance

- `SinkDispatcherTests`:
  - A `StuckRunner` past a short deadline, then its gate opened while the next job runs: `transcription_late_return` is emitted once, with `phase` `transcribe` and a positive `seconds_after_deadline`, and nothing else changes (still no `<stem>.json` and no spawn).
  - The same with a gated redactor: `phase` `redact`.
  - Two stuck runners in a row: the second `transcription_timed_out` carries `abandoned_outstanding` 1. After the first gate opens, a third expiry carries 1, not 2.
  - A regression pin: after the stuck pass returns, a weak reference to the replaced runner is nil.
- pytest in `pipeline/tests/`:
  - A subprocess started with `MP_SUPERVISED=1`, a short injected grace, and a main thread blocked in a `finally` that sleeps far past the grace. Close its stdin, and it exits with 143 within the grace plus a small margin.
  - A subprocess given the new deadline key with a 1 s timeout and a short grace, running a command that sleeps, exits on its own.
  - Without the key, no timer is armed.
- `PipelineLauncherTests`: `runMP` exports the deadline key, equal to its `timeout`, for a supervised spawn (run-all) and for an unsupervised one (backup, digest), and still gives the unsupervised one no stdin pipe.
- `transcription_late_return` and the new `abandoned_outstanding` attribute are documented in `CONVENTIONS.md`'s event table; `python3 scripts/truth_fences.py events` green.
- `cd daemon && swift build` and `swift test` green; `cd pipeline && uv run --extra dev pytest -q`, ruff and pyright green. N new tests named in the commit body. `bash scripts/ci-local.sh` green.
