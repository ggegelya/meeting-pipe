# PERF16: smaller costs in the mute plumbing: `LogMuteAdapter` re-copies its buffer once per line on the main thread, and `RealAXBackend` keeps an `AXObserver` on the main run loop after a failed first registration

Band origin: filed 2026-10-25 from the performance review (eight subsystem finders over HEAD 01e904a, every finding adversarially re-verified). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Two small defects in the mute-reading plumbing, re-read at HEAD 01e904a on 2026-10-25. One task because each is a few lines.

**1. `LogMuteAdapter` splits each chunk quadratically, on main.** The MIC8 log reader tails Teams' SlimCore log at 1 Hz. The read runs on `readQueue`, but `tick()` hops the result to main (`DispatchQueue.main.async { guard let self = self, gen == self.generation else { return }; self.consume(tail) }`), and `consume` appends the chunk to `pending` and calls `completeLines()`, which is `while let newline = pending.firstIndex(of: 0x0A) { lines.append(...); pending = Data(pending[pending.index(after: newline)...]) }`: one copy of the remaining buffer per line, O(lines x bytes). `maxPendingBytes` (256 KiB) is applied only after the loop, and only the last transition in the batch is used (the code's own comment: "Only the LAST transition in the batch matters"). Magnitude: SlimCore writes only on events (mute toggles, call registration and teardown, ECS refreshes, an hourly heartbeat, per [END12](./END12.md)), so a normal chunk is tens of KB and a few hundred lines, milliseconds of copying. The large chunks come from `SlimCoreMuteLog.tail` reading from offset 0, on a rotation after the first resolution (`start = skipHistory ? size : 0`) and on a truncation (`if size < start { start = 0 }`); there a 1 MiB generation of 5,000 lines costs on the order of 2.5 GB of copying on main. Both are rare, since the family rolls when Teams restarts. Generation sizes are unmeasured: Teams is not installed on the Mac sampled on 2026-10-25.

**2. `RealAXBackend` leaks an observer when a PID's first registration fails.** `RealAXBackend.register` calls `obtainObserver(for: pid)`, which creates the `AXObserver`, adds its run-loop source with `CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)` and caches it in `observersByPID` with `handlerCount` 0, all before `AXObserverAddNotification` runs. When the add fails (an element invalidated by a Teams re-render, `kAXErrorCannotComplete` from a busy client), `register` releases only the handler box (`guard addErr == .success else { Unmanaged<HandlerBox>.fromOpaque(userInfo).release(); throw ... }`) and never calls `releaseObserver`, so the entry and its main-run-loop source stay until a later register and unregister cycle for the same PID succeeds. Cost: one small observer per affected client PID, and PIDs change on every client restart over weeks of uptime. A dead PID's observer is inert; a reused PID is handed a stale observer whose registrations then fail, which loses notifications while the polls still cover. Callers are `AXMuteButtonProbe.start` (value and title notifications) and `AXLeaveButtonSignal._start` and its self-arm.

Review provenance: DETECTION-13 (finder medium, verified low, verdict plausible) and DETECTION-14 (verified low).

## Scope

1. **[`LogMuteAdapter`](../../../daemon/Sources/MeetingPipeCore/MicGate/Adapters/LogMuteAdapter.swift)`.completeLines`**: split in one forward pass (track a start index, slice each line once, keep only the trailing partial), and apply `maxPendingBytes` before splitting. Optionally move the split and `SlimCoreMuteLog.parse` onto `readQueue` so only the final `Reading` hops to main; if so, `pending` moves with them and stays single-owned. If a large delta is capped to its last N KiB, do it in `LogMuteAdapter`, not in `SlimCoreMuteLog.tail`, because `CallTeardownWatcher` reads through the same `tail` and its teardown lookback must still see a teardown line.
2. **[`RealAXBackend`](../../../daemon/Sources/MeetingPipeCore/Infra/RealAXBackend.swift)`.register`**: on an add failure, under `lock`, remove the entry and its run-loop source when `handlerCount` is 0 (one `discardIfUnused(pid:)` shared with `releaseObserver`). In `obtainObserver`, replace a cached entry whose PID is no longer alive (`kill(pid, 0)` failing with `ESRCH`) instead of reusing it.

## Explicitly not

- `LogMuteAdapter`'s cadence and the SlimCore flush delay END12 measured: the reader's semantics are MIC8's and unchanged here. `CallTeardownWatcher`'s 1 Hz directory stat: [END16](./END16.md).
- `RealAXBackend` pinning its sources to the main run loop, which is why every AX notification arrives on main: [PERF10](./PERF10.md)'s 2026-10-25 amendment hops the probe's handlers off main instead of moving the source.
- `ModelDownloadSupervisor.consumeStdout` has the same per-line `removeSubrange` shape over short download-progress lines; observed, not worth a change.

## Acceptance

- `LogMuteAdapterTests`, written before the change and green after it: a chunk of 5,000 lines with a transition near the end and a trailing partial line yields the same reading and carries the same partial; a newline-free chunk over the cap is dropped without being split; a line split across two ticks still parses. If the parse moves to `readQueue`, a test with an injected queue shows the reading is produced off main.
- `RealAXBackend` gains a seam for its AX and run-loop calls (create, add notification, add and remove source), defaulting to the real functions, so a test can force `AXObserverAddNotification` to fail and assert that no cached observer and no added source remain for that PID; a later successful register for the PID creates a fresh observer; a cached entry for a dead PID is replaced.
- `cd daemon && swift build` and `swift test` green with N new tests stated in the commit body, `bash scripts/ci-local.sh` green.
