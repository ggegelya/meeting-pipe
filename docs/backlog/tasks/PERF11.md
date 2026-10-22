# PERF11: a main-thread stall is invisible unless someone runs `sample` at the right moment, so "is it the app or the OS" cannot be answered from the logs

Band origin: filed 2026-10-23 from the investigation into the owner's "the app feels slow" report. Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## What prompted it

The owner could not tell whether the lag came from macOS load or from MeetingPipe. Answering took three live `sample` runs on 2026-10-23, two of which missed the scrolling entirely because the timing depended on the owner reading a chat message at the right moment. macOS wrote no hang report for MeetingPipe (only `.diag` disk-write reports from recordings, and `.hang` files for Chrome and Music on 2026-10-22), because a 1 to 3 s stutter is below the hang reporter's threshold.

The repo already has the pattern for a different stall: `StopStallWatchdog` emits `stop_exceeded_ceiling` so a stuck stop is readable from `events.jsonl` (REC13). Nothing does that for the main thread in general, and the next freeze report ([PERF10](./PERF10.md) is a live suspect) would need the same manual chase.

## Scope

A main-thread responsiveness watchdog, on from launch:

- A background `DispatchSourceTimer` (about 4 Hz) posts a no-op to the main queue and measures how long it waits to run. A wait over a threshold (start at 250 ms; document the choice) is a stall.
- One `Log.event(category: "perf", action: "main_thread_stall", ...)` per stall, emitted when the stall ends, carrying `duration_ms`, and, captured off main while the stall is in progress, the frontmost app, whether a recording is live, and which Library or other window is key. Rate-limit it (for example at most one row per 10 s with a `suppressed` count), so a pathological minute cannot flood the rotating log.
- Optionally, behind `verboseLogging`, capture the main thread's stack once per stall from the watchdog thread so the row says *what* blocked. Only if that can be done without new dependencies.
- A new event category, so `CONVENTIONS.md`'s event table and `scripts/truth_fences.py` change in the same commit.

## Explicitly not

- Fixing any particular stall. This is the instrument; [PERF9](./PERF9.md), [PERF10](./PERF10.md), [PERF12](./PERF12.md) and [PERF13](./PERF13.md) are the fixes.
- Telemetry or any upload. The row stays in the local `events.jsonl` (selling machinery stays out of scope).
- Logging from the watchdog thread with a blocking write per tick. It emits only on a stall, and `Log` is already safe off main.

## Acceptance

- A pure `StallDetector.decide(...)` (explicit inputs: post time, run time, threshold, last-emit time) unit-tested for the threshold, the rate limit and the suppressed count, per the pure-logic rule.
- An integration test that blocks the main queue for 400 ms in a test host and sees exactly one `main_thread_stall` row with `duration_ms >= 400`.
- `python3 scripts/truth_fences.py` clean with the new category documented. `cd daemon && swift build` and `swift test` green, new test count in the commit body.
- Owner check after install (confirms, does not gate): scroll the Library before [PERF9](./PERF9.md) lands, and `mp logs` shows `main_thread_stall` rows for it.
