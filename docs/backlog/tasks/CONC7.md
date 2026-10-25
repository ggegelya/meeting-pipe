# CONC7: PipelineLauncher.runMP and DoctorRunner drop the last stderr chunk on exit and share an unlocked stderr buffer across threads

Band origin: filed 2026-10-25 from the 2026-10-25 code-quality audit band ([code-quality audit](../../audits/2026-10-25-code-quality-audit.md) SW1, SW12). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Re-read in code on 2026-10-25 (base `01e904a`). The two long-lived `mp` spawns that stream output end their streams the same wrong way.

**`PipelineLauncher.runMP`** is the single `mp <args>` spawn primitive behind `runAll`, `summarize`, `publish` and `ask`. It collects stderr in a captured local, `var stderrTail = Data()`, appended by `errPipe.fileHandleForReading.readabilityHandler` (`stderrTail.append(d)`, then trimmed to `stderrLimit = 4096`). The `terminationHandler` then does `outPipe.fileHandleForReading.readabilityHandler = nil` and `errPipe.fileHandleForReading.readabilityHandler = nil` first, and builds the result from `String(decoding: stderrTail, as: UTF8.self)`. Two defects follow:

1. **No final drain.** `terminationHandler` fires when the child is reaped, which is independent of whether the readability source has delivered the bytes still sitting in the pipe. Clearing the handler there discards them. The last stderr chunk is exactly what the user sees: `LaunchError.nonZeroExit(status, stderrTail)` feeds `PipelineLauncher.failureCaption(stderr:)` and the Details text, and Python's last line before exit is usually the traceback or the error. `FailureProcessTests` already asserts the tail contains `"diagnostic-end"`, the last line its script writes, so it is exposed to this race (it skips without the pipeline venv).
2. **A data race on the tail.** The readability handler runs on Foundation's pipe queue and the termination handler on another; both touch `stderrTail` with no lock. A clean `-strict-concurrency=complete` build on 2026-10-25 reports five diagnostics on it ("mutation of captured var 'stderrTail' in concurrently-executing code", "reference to captured var 'stderrTail' ..."). The targeted mode this target builds under does not, which is why CI9's warning gate will not catch it either.

`runMP` is 130 lines from signature to closing brace, braces nested six deep (measured with the audit's brace-matching script), with environment, failure file, log handle, both handlers, watchdog and outcome in one closure-heavy body, which is how the drain order went unnoticed.

**`DoctorRunner.spawnMPDoctor`** has the same shape: both handlers feed one `appender` that posts `Task { @MainActor in self?.output.append(chunk) }`, and `terminationHandler` clears both handlers and posts a second `Task` that sets `state = .finished(exitCode:)`. So the doctor sheet can lose its last lines, and because the chunk tasks and the finish task are created on different threads, nothing orders a delivered last chunk before the exit badge either.

**The closest correct shape in the tree** is `ModelDownloadSupervisor.handleTermination`, which reads the remaining `h.availableData` before setting `h.readabilityHandler = nil`. It is not copied verbatim: a blocking read after exit is safe only while no grandchild holds the pipe. `mp` leaks none today (`summarize_local` starts `mlx_lm.server` with `stdout=server_log or subprocess.DEVNULL`), but a drain that can block the termination path forever is the REC11 shape.

CONC5 builds a run-to-completion `ProcessRunner` and says explicitly that "the long-lived streaming spawns (`PipelineLauncher`, `ModelDownloadSupervisor`, `DoctorRunner`, `LocalModelPreloader`) keep their own handlers", so nothing filed covers these two.

## Scope

1. **One streaming drain, `ProcessOutputDrain`**, in a new `daemon/Sources/MeetingPipe/ProcessOutputDrain.swift`. It attaches to a process's stdout and stderr pipes, delivers each chunk to an `onChunk(stream, data)` callback on one private serial queue (so chunk order across both streams is preserved), keeps a bounded stderr tail behind an `OSAllocatedUnfairLock<Data>` (no new `@unchecked Sendable`, per `daemon/CLAUDE.md`), and calls `onFinished(status, stderrTail)` exactly once, after the process has terminated **and** both pipes have reached EOF (an empty `availableData`). If EOF has not arrived within a post-exit ceiling (a named constant, 2 s, with a one-line reason: a grandchild holding the pipe), it finishes with what it holds and logs once. The handler-nil happens inside the drain after EOF, never in a `terminationHandler`.
2. **`runMP` uses it and is split** into named steps: building the environment and failure path (`makeProcess`), the drain wiring with the progress-sentinel scan as the stdout `onChunk`, and the termination step that releases the slot, routes the timeout and cancel cases and calls `Self.outcome(...)`. The watchdog and its `OneWayFlag` stay as they are. `outcome` and every `LaunchError` case are unchanged.
3. **`DoctorRunner` uses it.** Chunks hop to main through `DispatchQueue.main.async` from the drain's one serial queue (FIFO), and `state = .finished` is set only from `onFinished`, so the last line is in `output` before the badge changes. Add an `invocation: () -> PipelineLauncher.MPInvocation?` init parameter defaulting to `PipelineLauncher.findMP`, mirroring `PipelineLauncher.init`, so a test can hand it `/bin/sh`.

## Explicitly not / out of scope

- `ModelDownloadSupervisor` and `LocalModelPreloader`: correct enough today, and migrating them is a free follow-up once the drain exists, not part of this fix.
- CONC5's run-to-completion `ProcessRunner` and the raw-`Process()` allowlist (HYG10). If CONC5 lands second, its runner may reuse this drain for its concurrent reads; if first, this drain may reuse its tail buffer. Either way the two do not merge into one type.
- The `try?` around the failure-file read and the log writes inside `runMP`: handed to the observability and error-handling audit by the 2026-10-25 report.
- `runMP`'s inline timeouts at its call sites (HYG17's literal sweep) and what `mp` does on `SIGTERM` (PIPE22).
- Complete concurrency checking as a mode: CONC6. This task only removes the five diagnostics it owns.

## Acceptance

- New `ProcessOutputDrainTests` driving `/bin/sh -c` children: `sh -c 'echo x >&2; exit 1'` run 200 times in a loop finishes every time with status 1 and a tail of exactly `"x\n"`; a child writing 64 KiB to stderr and then a marker line returns a tail of exactly 4096 bytes ending in the marker; a child that backgrounds a grandchild holding stderr (`sh -c '(sleep 5) & echo x >&2; exit 1'`) still finishes within the post-exit ceiling with `"x\n"`; `onFinished` fires once.
- A `PipelineLauncher` test with `invocation: { .init(shell: "/bin/sh", args: ["-c", "printf 'diag-end\\n' >&2; exit 1", "sh"]) }`: 50 sequential `summarize(transcriptMD:)` runs each fail with `PipelineLauncher.diagnostics(for:)` ending in `diag-end`. Record in the commit body how many of the 50 dropped it on `main` before the fix (the audit read the race from code and did not reproduce it at runtime).
- A `DoctorRunner` test with an injected `/bin/sh` invocation: when `state` first reads `.finished(exitCode: 1)`, `output` already ends with the child's last line.
- `runMP` is under 60 lines with brace depth at most 4 by the same brace count; a scratch `-strict-concurrency=complete` build shows no diagnostic naming `stderrTail` (reported in the commit body, flag reverted).
- `cd daemon && swift build` and `swift test` green, about 6 new tests with the count in the commit body; `bash scripts/ci-local.sh daemon` green.
