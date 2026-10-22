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
