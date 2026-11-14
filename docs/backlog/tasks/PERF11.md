---
id: PERF11
title: A main-thread stall is invisible unless someone runs `sample` at the right moment, so app-or-OS cannot be answered from the logs
category: Performance
status: new
priority: P2
comment: Filed 2026-10-23: diagnosing the owner's lag took three live traces, two of them mistimed, and macOS writes no hang report for a 1-3 s stutter. Scope: a background watchdog that emits a rate-limited `main_thread_stall` event with its duration and context, the way `StopStallWatchdog` does for stops. [Spec](./PERF11.md) Amended 2026-11-13 by the audit band: a 3,078 ms capture-file create on main (stem 20261112-163040) went unlogged; log stalls at 100 ms, flag 250 ms as over budget, and carry OBS7's last ui_action seq.
---

# PERF11: a main-thread stall is invisible unless someone runs `sample` at the right moment, so "is it the app or the OS" cannot be answered from the logs

Band origin: filed 2026-10-23 from the investigation into the owner's "the app feels slow" report. Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

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

## Amendment 2026-11-13 (audit band)

Added from the [2026-11-13 responsiveness audit](../../audits/2026-11-13-responsiveness-audit.md) (its latency budget, its instrumentation section, and findings P003 and P045, both medium), class key responsiveness:perf11-threshold-and-action-context. Re-verified in code at HEAD (`3a2da4fc`) on 2026-11-13.

**Evidence: a 3 s main-thread block that nothing logged.** `MeetingRecorder.buildMicChain` is `@MainActor` and creates the capture file synchronously there (`micFile = try AVAudioFile(forWriting: micURL, settings: fileFormat.settings)`), then writes "mic file opened" to `recorder.log`. Measured from the field pack as `input_device_resolved` to that line, a span with no suspension point: median 10 ms over 74 starts, 200 ms or more in 6 of 74, and 2,274 ms and 2,600 ms (era A), 2,851 ms (era B) and 3,078 ms (era C, stem 20261112-163040, 2026-11-12), 4 of the 9 first recordings after a launch. Each froze the whole app (prompt stuck mid-fade, hotkeys dead) and no row says so: `daemon/Sources` has no stall watchdog, no `os_signpost`, `OSSignposter` or `CFRunLoopObserver`, and no `main_thread_stall` action (grep at HEAD). The audit's verdict on this task as specified: it "would have named every stall in this report".

**Why the threshold moves.** The audit's budget is "no single job over 50 ms; log a stall at 100 ms; treat 250 ms as a bug". This spec starts at 250 ms, which catches the four multi-second creates but misses most of the 6 of 74 starts over 200 ms and the shorter stop stalls the audit measured (30 to 342 ms).

**Scope additions.**

1. Log a stall at 100 ms, and carry `over_budget: true` on any stall of 250 ms or more, so a report counts budget violations without re-deriving them. Document both numbers beside the constants. The rate limit and `suppressed` count stay as specified; at 100 ms the limit matters more, so its window is part of the `StallDetector.decide` tests.
2. Tie each stall to the click before it: `main_thread_stall` carries `last_ui_seq`, the `seq` of the most recent `ui_action` from [OBS7](./OBS7.md)'s `UILatency` helper, and `since_ui_action_ms` on the same monotonic clock (`ProcessInfo.processInfo.systemUptime`). The watchdog reads the sequence without hopping to main (an atomic or a lock), since main is what is blocked. If OBS7 has not landed, ship without the two attributes and let OBS7 add them; do not build a second sequence counter here.
3. Keep the `perf` category and the `main_thread_stall` name. The audit calls the same probe `main_stall` and suggests a run-loop observer instead of the timer ping; either mechanism meets the bar, and one name keeps CONVENTIONS and the truth fences single.

**Explicitly not (added).** Moving the capture-file create off main: that is [PERF28](./PERF28.md). This task is the instrument that shows PERF28 worked: no `main_thread_stall` row during record start after it lands.

**Acceptance additions.**

- `StallDetector.decide` tests at the new thresholds: a 99 ms wait emits nothing, 100 ms emits a row without `over_budget`, 250 ms emits one with `over_budget: true`; the rate-limit window and `suppressed` count at 100 ms.
- With OBS7 present, a test that records a `ui_action`, blocks main for 400 ms, and sees one `main_thread_stall` whose `last_ui_seq` equals that action's `seq`.
- Owner check after install (confirms, does not gate): before PERF28 lands, the first Record after a relaunch on the work laptop yields a `main_thread_stall` row whose `last_ui_seq` is that Record click.
