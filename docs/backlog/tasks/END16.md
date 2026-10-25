# END16: the call-teardown watcher stats Teams' log folder every second around the clock, and reports the folder unreadable thousands of times

Band origin: filed 2026-10-23, found while sampling the daemon for the owner's "the app feels slow" report and while investigating [END15](./END15.md). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

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
