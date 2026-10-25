# PIPE37: Quitting or restarting the daemon leaves its in-flight mp jobs running with no watchdog, and the relaunch marks their meetings interrupted while they still write, so a Retry runs a second pipeline on the same stem

Band origin: filed 2026-10-25 from the performance review (eight subsystem finders over HEAD 01e904a, every finding adversarially re-verified). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Re-verified against HEAD `01e904a` on 2026-10-25 by code reading. Review finding SUBPROCESS-7 (confirmed, medium).

**The exit path never reaches the launcher.** `AppDelegate.flushAndExit` arms the 9 s termination ceiling, calls `localModelPreloader.stop()` and `coordinator?.shutdown()`, then `exit(relaunch ? EXIT_FAILURE : EXIT_SUCCESS)`. `Coordinator.shutdown` stops the discovery watcher, the hotkey, the session consumers, the mic gate and the lifecycle coordinator, and flushes a live recorder; it touches neither `jobDispatcher` nor `PipelineLauncher`. The `runMP` watchdog that caps a run-all at 90 min is a `DispatchSource.makeTimerSource(queue: .global(qos: .utility))` inside the process that is exiting.

**The child outlives it.** The review's verifier probed it on 2026-10-25: an NSTask child is placed in its own process group (its PGID equals its own pid), so launchd's process-group kill when the job exits (the plist sets no `AbandonProcessGroup`) does not reach `mp`. Python ignores SIGPIPE by default and the progress heartbeat is best-effort, so `mp` keeps running with no 90-minute cap. That cap exists because of the incident `PipelineLauncher.defaultMaxRuntime`'s doc records: in May 2026 a 3 h file pinned 4 cores for 13 h before a manual kill.

**It is reachable from ordinary use.** [UX82](./UX82.md) records that the menu's plain Quit (Cmd+Q) exits 1 by default so launchd relaunches the app, and `scripts/rebuild.sh` boots the agent out and back in. Either, during a run-all, an ask or a Library re-run, is enough, and so is a crash or the termination ceiling's `exit`.

**The relaunch then invites a second run.** At launch `Coordinator.reconcileStrandedJobs` lists the library and, for every stem `StrandedJobRecovery.detect(fileNames:)` returns (a final `.wav` with no terminal sidecar), writes `.interrupted` with "MeetingPipe restarted before this meeting finished processing. Retry to resume." That includes a stem the orphan is still processing. A Retry enqueues a `.full` job, which re-transcribes and spawns a second run-all on the same stem while the first may still write it: the overlap PIPE11 serialized the lane to stop (its 2026-07-23 case, where the surviving summary was decided by whichever subprocess exited last). [PIPE18](./PIPE18.md)'s coalescing only sees this process's queue. If the orphan was summarizing locally, its `mlx_lm.server` also survives the launch reaper, because the marker's owner, the orphan, is alive.

## Scope

1. **Signal supervised spawns on exit.** `PipelineLauncher` keeps a lock-guarded set of its live supervised spawns: every `runMP` that names a `meeting` (run-all, the Library re-runs, merge, finalize, paste publish, the Apple-phase publish) plus the `.ask` slot. A new `PipelineLauncher.terminateSupervised()` sends each SIGTERM and returns at once, with no SIGKILL follow-up, because the 9 s ceiling cannot afford `terminate(_:what:)`'s 10 s grace. `Coordinator.shutdown` calls it through `jobDispatcher`. Backup, restore, digest, roster and actions spawns (no `meeting`) are left to finish as today: no relaunch reconciles them, and a restore stopped midway is worse than one that completes unsupervised.
2. **A supervised `mp` exits when the daemon is gone, however it went.** Item 1 runs only on an orderly exit. For a crash, a SIGKILL or the ceiling's `exit`, `runMP` gives supervised spawns `p.standardInput = Pipe()`, holds the write end, and exports `MP_SUPERVISED=1`. `mp`'s `__main__.main`, when that is set, starts a daemon thread that reads stdin to EOF and then sends its own process SIGTERM. EOF arrives when the kernel closes the daemon's last write end, which happens on every way the daemon can end. Stdin rather than `os.getppid()`, because the dev layout runs `mp` through `uv run`, so the Python process's parent is `uv` and not the daemon. This lands after [PIPE22](./PIPE22.md), whose SIGTERM handler turns the self-signal into an unwind that runs every `finally` and closes the local server.
3. **The write end must not leak to siblings.** If a second supervised spawn inherited the first one's write end, neither would see EOF while the other lives. The pickup confirms Foundation's `Process` does not pass it on (the test below), and sets `FD_CLOEXEC` on the write end if it does.

## Explicitly not

- A pidfile checked at the next launch, which the review suggested. Item 2 ends the orphan within seconds of the daemon's death whatever caused it, which a check at the next launch cannot, and the `ps` identity probing a pidfile needs is the class [LOCAL21](./LOCAL21.md) is deleting.
- Changing `reconcileStrandedJobs`. With items 1 and 2 the orphan is gone or unwinding when it runs. The residual is a Retry clicked inside that unwind (bounded by the local server's 10 s close), named here and not fixed.
- Waiting for the children in `shutdown`, for the ceiling reason in item 1.
- UX82's exit status and crash-loop breaker, [OBS5](./OBS5.md)'s termination-reason row in `flushAndExit`, and [OBS4](./OBS4.md)'s `MP_RUN_ID` in the same environment. Whichever lands second keeps the others.
- `ModelDownloadSupervisor`'s prefetch, `DoctorRunner`'s `mp doctor`, and `LocalModelPreloader`, which `flushAndExit` already stops.
- Who owns `mlx_lm.server`: LOCAL21.

## Acceptance

- `PipelineLauncherTests` with an injected invocation running `/bin/sh -c 'trap "exit 0" TERM; sleep 60 & wait'`: `terminateSupervised()` returns without waiting and the supervised child is gone within a second, while a spawn with no `meeting` (a backup) is still running.
- A test that `Coordinator.shutdown` calls `terminateSupervised` (a counting fake launcher or dispatcher).
- `pipeline/tests/test_main_dispatch.py`: `python -m mp` with `MP_SUPERVISED=1` on a fake subcommand blocking inside `try/finally` runs the `finally` (a sentinel file) and exits 143 within a few seconds of the test closing its stdin write end; without `MP_SUPERVISED`, closing stdin leaves it running.
- A Swift test with two concurrent supervised spawns of `/bin/sh -c 'cat >/dev/null'`: closing the first spawn's write end ends the first child while the second keeps running, which pins that siblings do not hold each other's write end.
- `CONVENTIONS.md` documents `MP_SUPERVISED` beside `MP_FAILURE_PATH`, and `docs/GUIDE.md`'s "Processing interrupted" sentence says quitting stops a run in progress and Retry resumes it, in the same commit.
- `cd daemon && swift build` and `swift test`, `cd pipeline && uv run --extra dev pytest -q`, ruff and pyright green, N new tests in the commit body; `bash scripts/ci-local.sh` green.
