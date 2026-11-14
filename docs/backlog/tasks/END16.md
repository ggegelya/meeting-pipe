---
id: END16
title: The call-teardown watcher stats Teams' log folder every second around the clock, and reports the folder unreadable thousands of times
category: Detection
status: new
priority: P2
comment: Filed 2026-10-23. A 60 s idle trace had the `CallTeardownWatcher` queue busy about 21% of the window, mostly `attributesOfItem` / `getxattr` on Teams' Group Container. `call_teardown_source_missing` transitions number about 21,700 since 2026-09-17, a median 68 s apart, so the END9 oracle is intermittently blind. Scope: find the flapping cause, cheap stat-only tailing, idle cadence, count blind confirms. Amended 2026-10-25 (performance review): since END17 an unreadable log is no evidence rather than a confirm, so the flapping now costs holds that wait out a dwell, not chopped calls; added legs for the per-tick `DispatchQueue` and timer, the regex and `DateFormatter` in the sort comparator, chunk parsing under the lock `snapshot()` takes, and a Teams-running cadence that keeps END10's warm tail. [Spec](./END16.md) Amended 2026-11-13 by the audit band: the oracle confirmed 0 of 59 Teams ends (4 of 4 era C ends waited the 60 s dwell), so log the teardown line's own time, keep the tail across a failed listing, rate-limit source_missing, gate the consult on Teams.
---

# END16: the call-teardown watcher stats Teams' log folder every second around the clock, and reports the folder unreadable thousands of times

Band origin: filed 2026-10-23, found while sampling the daemon for the owner's "the app feels slow" report and while investigating [END15](./END15.md). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## What was observed

1. **Constant work with no meeting.** In a 60 s `sample` taken 2026-10-23 with no call and no recording, the serial queue `MeetingPipeCore.CallTeardownWatcher` was on-CPU or in a syscall for 12,914 samples (about 21% of the window). That broke down as `CallTeardownWatcher.tick()` -> `SlimCoreMuteLog.tail(directory:family:current:offset:skipHistory:)` 12,688, of which `SlimCoreMuteLog.listing(in:family:)` -> `FileManager.attributesOfItem(atPath:)` 7,224, nearly all in `getxattr`. The watcher is started unconditionally (`Coordinator` calls `callTeardown.start()`) and polls at `CallTeardownWatcher.defaultPollInterval = 1.0`. `listing` already filters to the `MSTeamsNM_SlimCore_` family before stating (3 of 84 files in the folder on 2026-10-23), so the cost is per-stat, not per-file-count. The folder is `~/Library/Group Containers/UBF8T346G9.com.microsoft.teams/Library/Application Support/Logs` (269 MB). Reading another app's Group Container goes through macOS's app-data protection on every access, which is the likely reason each `getxattr` is slow. That is a hypothesis to verify.
2. **The folder flaps between readable and unreadable.** `call_teardown_source_missing` with `reason: "NSCocoaErrorDomain 256: The file “Logs” couldn’t be opened."` appears 6,201 times in `events.jsonl`, plus 1,953, 7,256 and 6,312 in generations `.1` to `.3`, the earliest on 2026-09-17. The median gap between rows is about 68 s. `CallTeardownWatcher` emits only when the failure cause changes (`if s.reportedFailure != cause`), so each row is a transition: the directory goes unreadable, recovers, and goes unreadable again, roughly every minute. Three rows landed in the two minutes before the [END15](./END15.md) incident on 2026-10-22.

Why it matters: [END9](./END9.md)'s hold relies on this watcher to see `UnregisterCall`. If the source is intermittently blind, `CallTeardownOracle.decide` receives `oracleAvailable: false` and confirms immediately (`oracleUnavailable`), so the protection END9 to END13 built is weaker than it looks, and nothing surfaces how often that happens. Separately, it is constant disk and CPU work on a laptop for a signal that only matters during a Teams call.

## Scope

1. Find the cause of the flapping before changing anything: owner-run, read-only, log the `contentsOfDirectory` error code and `errno` around a flip, and check System Settings for the app-data access permission for MeetingPipe. Record the answer in this spec.
2. Make the watcher cheap:
   - Stat only the generation it is tailing each tick, and re-list the folder only on a slower cadence or when the tailed file's size stops moving.
   - Read the modification date from `URLResourceValues` (`contentModificationDateKey`) rather than `attributesOfItem`, which also pulls every extended attribute.
   - Stand the watcher down to a slow cadence while no Teams meeting is engaged. The oracle only matters during a hold, and a hold opens only in a call.
3. Make the blindness visible: count `oracleUnavailable` confirms per day (or emit them with a `source_flapping` attribute), so a future regression reads from `events.jsonl`.

## Explicitly not

- Changing `CallTeardownOracle.decide`'s behaviour on an unavailable source. Degrading to the pre-END9 behaviour is deliberate.
- The mute-log reader (`LogMuteAdapter`), which tails the same family. If step 1 shows the same flapping hits it, note it here and file it separately.

## Acceptance

- A unit test on the listing seam: with a fake file system, a tick that is not re-listing performs one stat (the tailed file), not one per generation.
- A test that the idle cadence applies while no meeting is engaged and the 1 Hz cadence returns on engage.
- `cd daemon && swift build` and `swift test` green, new test count in the commit body. `scripts/truth_fences.py` clean if a new event action is added.
- Evidence after install (confirms, does not gate): a 60 s idle `sample` shows the `CallTeardownWatcher` queue under 2% of samples, and a day of `events.jsonl` shows the flapping explained or gone.

## Amended 2026-10-25 (performance review)

Two review findings land here: DETECTION-12 (confirmed, low) and MAINTHREAD-6 (confirmed, verified low), both re-verified at HEAD 01e904a on 2026-10-25 (eight subsystem finders, every finding adversarially re-verified). They confirm scope item 2's stat-only tailing and idle cadence, correct one premise, and add four legs this spec lacks.

**A correction to "Why it matters".** It says an unavailable source makes `CallTeardownOracle.decide` "confirm immediately (`oracleUnavailable`)". That stopped being true with END17 on 2026-10-24: the oracle is teardown-or-nothing, its `Reason` enum has one case (`teardownObserved`), and its doc comment says an unreadable log "is no evidence rather than a confirm". `CallTeardownWatcher.unavailableAfterFailures`' comment says the same ("a flap can no longer end a call"). So the flapping no longer chops recordings. What it costs now is a held end that Teams' teardown line cannot confirm, which waits out `PromotionEngine`'s dwell instead (60 s pair, 720 s lone), a longer recorded tail, plus the energy cost. Scope item 3 should therefore count consults made while `available` is false (holds the oracle could not help), not `oracleUnavailable` confirms, which no longer exist.

**Legs to add to scope item 2**, in [`CallTeardownWatcher.swift`](../../../daemon/Sources/MeetingPipeCore/Lifecycle/CallTeardownWatcher.swift) and [`SlimCoreMuteLog.swift`](../../../daemon/Sources/MeetingPipeCore/MicGate/SlimCoreMuteLog.swift):

- **A new queue and timer every tick.** `CallTeardownWatcher.defaultScheduler` builds `DispatchSource.makeTimerSource(queue: DispatchQueue(label: "MeetingPipeCore.CallTeardownWatcher.timer"))` with a one-shot `timer.schedule(deadline: .now() + delay)`, and `rearm(generation:)` calls it after every tick, so the process creates and releases one `DispatchQueue` and one timer source per second for its whole life. Churn, not a leak (the previous ones are released at the next rearm). Use one repeating `DispatchSourceTimer` on `readQueue` (or one long-lived timer queue) with leeway, keeping END10 item 2's reason for a dispatch timer: the tick runs on a GCD worker with no run loop.
- **Regex and `DateFormatter` inside the sort comparator.** `SlimCoreMuteLog.listing(in:family:)` returns `found.sorted(by: generationPrecedes)`, and `generationPrecedes` calls `nameTimestamp` (a `range(of:options: .regularExpression)` plus `nameFormatter.date(from:)`) on both names at every comparison. Compute each name's timestamp once per listing and sort on the stored value. `LogMuteAdapter` shares the function and gains too. Small at present (3 family files on 2026-10-23; 0 on the review Mac on 2026-10-25), but it grows with the generations Teams keeps.
- **Parsing under the lock `snapshot()` takes.** `tick()` runs `SlimCoreTeardownLog.newestTeardown(inChunk: tail.chunk, pending: s.pending)` inside `self.state.withLock`, and `snapshot()`, which the session's teardown-hold consult reads on main, takes the same `OSAllocatedUnfairLock`. Parse first against a copy of `pending`, then commit the result under the lock behind the existing generation check.
- **The idle cadence must keep END10's warm tail.** `Coordinator` starts the watcher at launch through `watchers.startAll()` for a stated reason: a lazy start "would still return `available: false` on that very first consult, because the resolve is async on `readQueue`". So the slow cadence must neither stop the tail nor let `available` lapse. Gate the 1 Hz cadence on Teams running (an `NSWorkspace` launch or terminate notification for a Teams bundle, or the lifecycle engaging), never lazily on `snapshot()`; while Teams is not running, a slow cadence (the pickup states it, 15 to 60 s) is enough. Teams' running state is a better idle signal than the folder: the Group Container directory persists without Teams (130 entries, 0 SlimCore generations and no Teams process on the review Mac on 2026-10-25), so at HEAD the watcher lists it every second on a Mac where Teams is not open.

**Observed, still out of scope.** `LogMuteAdapter` tails the same family through `SlimCoreMuteLog.tail` at its own 1 Hz during every Teams recording, so a call lists the folder twice a second. Sharing one tailer is the review's suggestion; this spec already keeps `LogMuteAdapter` out, and the cached-name sort above helps both without merging them.

**Evidence note for the after-install check.** The 2026-10-25 idle numbers for the daemon on the review Mac (0.0% CPU, 18 MB footprint, no idle wakeups across a 10 s `top` sample) cannot be read against this task: that binary (`~/Applications/MeetingPipe.app`, modified 2026-09-11) contains none of `CallTeardownWatcher`'s queue labels or its `call_teardown_source_missing` action, so it predates END9 and runs no teardown watcher at all. Take the before-and-after `sample` from a build that contains the watcher.

**Added acceptance:**

- A test that many ticks are driven by one timer source rather than one per tick (a counting scheduler seam), pinned without a run loop the way END10's multi-tick fence is.
- A test that `listing(in:family:)` parses each family file's name once regardless of how many comparisons the sort makes (a counting parser).
- A test that `snapshot()` is not held up by a tick's parse (a slow fake parse on `readQueue`; `snapshot()` returns within a stated bound).
- A test that with Teams reported not running the watcher ticks at the slow interval and keeps `available` from its last resolve, and that a Teams launch returns it to 1 Hz before any consult.

## Amendment 2026-11-13 (audit band)

Sources: D103 and D109 in the [recording reliability audit](../../audits/2026-11-13-recording-reliability-audit.md) (detail in its [evidence file](../../audits/2026-11-13-recording-reliability-evidence.md)), F160 in the [independent audit](../../audits/2026-11-12-independent-audit.md), and the field findings "Teams' teardown line confirmed no end in six weeks" (sessions-and-lifecycle #2) and "call_teardown_source_missing logged 16,861 times, once per flap" (daemon-health-and-audit-crosscheck #1) in the [field evidence](../../audits/2026-11-13-field-evidence.md). Low findings G053, D044, D089 and mic-mute-and-capture #14 folded in. All re-verified at HEAD 3a2da4fc on 2026-11-14.

**The oracle confirms nothing in the field.** 0 of 59 Teams lifecycle ends in the work laptop's pack (2026-09-29 to 2026-11-13) were confirmed by the teardown line. The only two `lifecycle_provisional_end_confirmed` rows (2026-11-09T16:02:09Z and 2026-11-12T07:39:32Z, `oracle=teardown_observed`, `held_sec` 0) were logged 0.22 s and 0.34 s after the lifecycle `ended` row they would have caused. Since the 2026-11-12 build (era C), all 4 Teams holds that ended had `oracle_available` true and `live_signal=call_is_down`, got no confirm, and ended 60.01 to 60.08 s after the mic release on the pair dwell (holds at 2026-11-12T14:32:36Z, 14:53:37Z, 15:44:27Z and 2026-11-13T07:42:25Z), each followed by `held_end_trimmed` mode `suggested`; `log_written_sec_ago` when they opened was 129, 1,390, 286 and 603 s, and none of the final holds in the pack opened with the generation written in the last 15 s. So `UnregisterCall` was not on disk, or was not read, within the dwell, and which of the two is not established: the code reads a line within about 1 s once it is on disk, but F160 below is a way to miss one. The cost is a 60 s later stop and pipeline start on every Teams end, not lost audio. `MeetingSessionController.beginTeardownHold`'s comment ("on a real end the answer is already on disk when this runs and the first consult confirms with no added latency") and ADR 0017's no-added-latency sentence do not hold on this laptop.

**A failed listing discards the tail position (F160, D044).** In `CallTeardownWatcher.tick`, a failed resolve stores `s.current = tail.url` (nil, since `SlimCoreMuteLog.tail` returns `url: nil, offset: 0` when the listing fails), so the next tick computes `firstResolve` as `$0.current == nil` and passes `skipHistory: true`, and `tail` then sets `start = skipHistory ? size : 0`, i.e. end of file. Bytes Teams wrote across even one failed listing are never read. No folder failures occurred after 2026-10-30, so this cannot be era C's cause, but it was live through the 16,861-failure period and comes back with the flapping.

**The flapping is logged once per flap, not once per outage (field #1).** `call_teardown_source_missing` logged 16,861 rows (14.7 percent of all event rows, 20.1 percent of bytes; 16,860 with `NSCocoaErrorDomain 256`, 1 with 257), median gap 68 s, in every hour of the day, 8,719 before 2026-10-12 and 8,142 after, the last at 2026-10-30T21:44:37Z inside an ordinary relaunch with no rebuild, none since. The code promises "One row per distinct cause per outage", but the success branch sets `s.reportedFailure = nil` on every good tick, so each flap logs again. Why a 1 Hz listing failed about once a minute for 26 days, and why it stopped, is not in the pack.

**The oracle's input is never logged (D089).** No daemon event carries a parsed teardown line's own timestamp. `scripts/extract_detection_trace.py` therefore builds each `teardown_snapshot` from the confirm row's own time (`"teardown_at": t` when `oracle == "teardown_observed"`), so a raw trace can only replay the decision that was logged, never test whether a different rule would have confirmed sooner.

**Any native hold can be confirmed by Teams' line (G053).** `TeardownHoldPolicy.consult` returns `nil` only `guard let hold, hold.context.kind == .native`, so a Zoom, Webex or Slack hold consults the Teams watcher and an unrelated Teams `UnregisterCall` after the recording started confirms it. `TeardownHoldPolicyTests` covers only the browser exclusion. [DET15](./DET15.md) item 4 names the same seam (P3); the guard is one line and belongs with this measurement work, so whichever task lands first closes it in the other.

**The mute-log reader shares the folder (field mic-mute-and-capture #14).** `LogMuteAdapter` lists the same SlimCore family and logged `log_mute_source_missing` 649 times in 42 recordings, also once per flap (`reportedMissing = false` on success). Correction at filing: the field slice said both counts are 0 "after 2026-11-12"; the last `log_mute_source_missing` row is 2026-10-23T15:34:49Z and the last `call_teardown_source_missing` is 2026-10-30T21:44:37Z, so the zero predates the era C rebuild and is environmental, not a fix.

**Scope additions.**

1. Measure before deciding. In `lifecycle_end_held`, and in a new per-consult row while a hold is open (rate-limited to edges: first consult, a changed newest stamp, conclusion), log the watcher's newest teardown stamp, `lastTeardownAt`'s age, `log_written_at`, the tail's current offset and file size. Log every parsed `UnregisterCall` (and registration) line with its own timestamp and a hashed call id, from `CallTeardownWatcher.tick` after `SlimCoreTeardownLog.newestTeardown`, so a field pack shows when the line reached disk relative to the mic release.
2. Keep the tail across a failed listing: on a failed resolve, keep `current` and `offset` in `State` and do not treat the next success as a first resolve. Only a real rotation (a different newest generation) resets the offset, as today.
3. Rate-limit `call_teardown_source_missing` (and `log_mute_source_missing`) per cause per hour, with a failure count in the row, and emit a recovered row with the outage's length when the listing succeeds after a reported failure.
4. Gate `TeardownHoldPolicy.consult` on the Teams bundle family, not only `.native`.
5. Change `extract_detection_trace.py` to build `teardown_snapshot` from the new line rows, falling back to today's confirm-time stamp only for packs that predate them, and say so in its report.

The fix decision itself (confirm a Teams end on evidence available within seconds, or make the Leave control rather than the window stamp the pair's second class) waits on scope item 1's numbers, [END15](./END15.md)'s owed dwell measurement, and the reducer gate in [END26](./END26.md). Not in scope here: [END24](./END24.md) (the window matcher), [END12](./END12.md)'s buffering finding, [OBS9](./OBS9.md) (retention).

**Acceptance additions.**

- `CallTeardownWatcherTests`: a tick whose listing fails between two successful ticks still delivers a teardown line appended during the failure (fails at HEAD); a rotation still starts the new generation at 0; three flaps inside an hour emit one `call_teardown_source_missing` row with a count and one recovered row.
- `TeardownHoldPolicyTests`: a native Zoom hold with a fresh Teams teardown stamp returns `nil` (fails at HEAD); a Teams hold still confirms.
- A controller or watcher test that a parsed teardown line emits one row carrying its own timestamp and a hashed id, never the raw id.
- A case in `pipeline/tests/test_detection_trace_scripts.py` that a pack with line rows builds the snapshot from the line's time, not the confirm's.
- New event actions documented in `CONVENTIONS.md`; `python3 scripts/truth_fences.py both` and `bash scripts/ci-local.sh` green, new test counts in the commit body.
- Field read after one working week on the build (counts and timestamps only): the delay from mic release to the teardown line's own stamp and to its read, per Teams end, written into this file.
