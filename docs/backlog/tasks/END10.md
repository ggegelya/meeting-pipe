# END10: END9's teardown oracle is never started, so every provisional end still confirms on the walk that found nothing

Band origin: filed 2026-08-21 after the owner reported that recordings "often drop at the beginning for no obvious reason". Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## What is wrong

[END9](./END9.md) shipped on 2026-08-20 to stop an empty AX re-walk from ending a live call, and it does not run. Its oracle is consulted, reports that it has no opinion, and the code treats "no opinion" as "the call ended". The behaviour on `main` is therefore byte-for-byte the pre-END9 defect END9 was built to remove.

Two independent defects produce that, and both have to be fixed for the oracle to work at all.

**One: the watcher is never started.** `Coordinator` holds `callTeardown` as `CallTeardownWatcher.teams()`, carrying a doc comment that says it is "started once at session setup and never per meeting". Nothing calls `start()` on it. A repo-wide search for `callTeardown` under `daemon/Sources` returns exactly three sites: the `SessionHost` protocol requirement, the `Coordinator` property, and the `coordinator.callTeardown.snapshot()` consult in `MeetingSessionController.consultTeardownOracle`. The only `start()` call in the tree is in `CallTeardownHoldTests.makeController`. `Coordinator.start()` starts `discoveryWatcher` and `configRefresh` and skips this one. Commit 86269d3 added three lines to `Coordinator.swift`, the doc comment and the stored property, and never edited `Coordinator.start()`, so the comment is a claim the diff does not implement.

The consequence is deterministic rather than intermittent. `CallTeardownWatcher.State.available` is initialised `false`; its only writer is `s.available = tail.url != nil` inside the work closure of `tick()`; and `tick()` is reachable only from `start()` and from the scheduler closure that `rearm(generation:)` installs, which itself only runs at the end of a tick. With no `start()`, zero ticks ever execute and `snapshot().available` is `false` for the whole life of the process. `CallTeardownOracle.decide` opens with `guard input.oracleAvailable else { return .confirm(reason: .oracleUnavailable) }`, so every consult confirms on its first evaluation.

Because `MeetingSessionController.beginTeardownHold` stamps `startedAt` and then calls `consultTeardownOracle()` synchronously *before* it creates the 1 Hz timer, emits `lifecycle_end_held`, or calls `hud.setConfirmingEnd(true)`, the entire hold collapses into a direct call to `confirmProvisionalEnd()`. None of END9's machinery is reached on any path.

**Two: even once started, it would tick exactly once.** `CallTeardownWatcher.tick()` dispatches its work onto `readQueue` and calls `self.rearm(generation:)` from inside that closure, so `rearm` runs on a plain `DispatchQueue` worker thread. `defaultScheduler` is `Timer.scheduledTimer(withTimeInterval:repeats:false)`, which attaches to `RunLoop.current`. A GCD worker thread has no run loop being run, so the timer never fires and the tail stops after its first read. MIC16's `LogMuteAdapter`, the component END9's own doc comment says its threading mirrors, does not have this bug: its read closure ends with an explicit `DispatchQueue.main.async` hop into `consume(_:)`, whose `defer { rearm() }` therefore runs on main where the timer lands on a live run loop. END9's copy dropped the hop.

## Observed, not theorized

The installed binary at `~/Applications/MeetingPipe.app` has an mtime of 2026-08-21 13:06, and `main`/`app_rebuild` records the swap at 2026-08-21 12:57:15, so the field log from that point on is END9's code.

Exactly one `lifecycle_provisional_end_confirmed` row in the entire log carries END9's attributes, at 2026-08-21T10:36:48.985Z:

```
{"action":"lifecycle_provisional_end_confirmed","bundle_id":"com.microsoft.teams2","category":"coordinator","held_sec":7.0333480834960938e-06,"oracle":"oracle_unavailable","trimmed":false,"ts":"2026-08-21T10:36:48.985Z"}
```

That is END9's first and only firing in the field, and it chopped `20260821-133615.wav` at 31.6 s while the owner was still in the call. The 7 microsecond `held_sec` is the gap between the two `Date()` calls in `beginTeardownHold` and `consultTeardownOracle`, which is only reachable if the first consult confirmed. `trimmed: false` follows because `heldFor` is below the 1.0 s trim floor. The owner re-attached by hand at 13:38:00 and that recording ran 18 m 30 s, so the meeting was live throughout.

**Instance two, 2026-08-21 at 16:31:38 local, four hours after instance one and unprompted.** `20260821-163018.wav` started at 16:30:19.827 and was confirmed ended at 16:31:38.379 carrying `{"held_sec": 0.010572075843811035, "oracle": "oracle_unavailable", "trimmed": false}`, chopping a live meeting at 78.7 s. The owner re-attached by hand 26 seconds later and the call continued. This is the second END9-instrumented confirm to exist and the second false positive, so the oracle is two for two, and the `held_sec` moving from 7 microseconds to 10 milliseconds while `oracle` stays `oracle_unavailable` is the signature of the same first-consult confirm rather than of anything intermittent. A build was installed at 15:23:33 between the two instances (`main`/`app_rebuild`, cdhash `1ff2798e` to `4b004aeb`), which changes nothing here: the defect is a missing call, not a stale binary.

`lifecycle_end_held` and `lifecycle_end_hold_released` have **zero** occurrences across `events.jsonl` and `events.1.jsonl`, and `daemon.log` carries zero "holding a provisional end" lines. The hold has never been entered on any recording.

The cost, measured over 2026-07-13 to 2026-08-21 (111 recordings): 78 of 96 `ending_provisional` rows are led by `ax_leave_button_invalid` and 76 of those confirm via `ax_leave_rewalk`; **16 meetings were chopped and then restarted by hand within 10 minutes**; 14 short fragments were published into the vault as their own notes; and 10 more produced no note at all. On 2026-08-17 the end was confirmed at 16:43:02 and `detector`/`discovery_shadow_pick` still reported `leave_button: true, calling_controls_toolbar: true` for the same Teams pid at 16:43:27 and 16:43:35, which is the direct proof that the confirmed end was false.

## The oracle is also not trustworthy once it is started

Folded in here rather than filed separately, because starting the watcher without these is a fix that appears to work and then chops recordings at a lower rate, which is harder to diagnose than the present total failure.

**Availability is presence-only and recomputed every tick with no hysteresis.** `s.available = tail.url != nil` flips on a single directory listing. The shared SlimCore resolver demonstrably flaps: `micgate`/`log_mute_source_missing` fires **292 times across 45 watch sessions** (0 to 18 per session, and 8 during the 13:38 recording on 2026-08-21) against family `MSTeamsNM_SlimCore_` while the generation is sitting on disk. `LogMuteAdapter` resets its `reportedMissing` latch whenever a url does resolve, so each of those 292 rows is a real resolved-to-missing transition rather than a repeat. Any provisional end landing in a flap second confirms immediately.

**The reason for the flapping cannot be read from the log.** `SlimCoreMuteLog.generations` opens with `guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return [] }`, so a permission failure, a transient I/O error and an genuinely absent family are the same value at that seam.

**There is no freshness check.** `MSTeamsNM_SlimCore_2026-08-13_18-06-05.23.log` was last written at 2026-08-21 13:36:15 local and was still frozen at 14:06 with Teams pid 635 running, while the owner's call ran until 13:56. A dead generation reads as a healthy oracle, so every genuine end would hold the full `defaultHoldCapSec` of 150 s before confirming.

**`lastTeardownAt` is session-monotonic and never scoped to the current recording.** A previous call's `UnregisterCall` landing inside `defaultLookbackSec` of a later provisional confirms it as `teardownObserved`. The last teardown before the 2026-08-21 chop was at 13:36:02, fifteen seconds before that recording even started.

**`generations(in:family:)` ranks by mtime rather than by the generation's own name**, sorting on `($0.modified, $0.url.lastPathComponent)`. The family's names already encode creation order and are the stable key; mtime is the field that moves.

## Why no test caught it

`CallTeardownHoldTests.makeController` builds its own `CallTeardownWatcher` over a temp directory and calls `start()` on it, and `FakeSessionHost.callTeardown` is initialised pointing at `/nonexistent/meetingpipe-tests` so `available` stays false by construction. The suite therefore pins `decide()` and the hold state machine, both of which are correct, while hard-coding the exact production state that is broken. END9's ship note records "+28 tests" and "neutering decide to an unconditional confirm turns 9 red", and both statements are true and neither could ever have failed on the missing `start()`.

## Scope

The smallest change that fixes the class, in `MeetingPipeCore/Lifecycle/` and `MeetingPipe/Coordinator.swift`.

1. **Start the watcher.** Call `callTeardown.start()` in `Coordinator.start()` beside `discoveryWatcher.start()`. Consider instead making it unavoidable by starting the tail lazily on the first `snapshot()`, which fails toward a hold rather than a chop and is what the watcher's own doc comment already argues for; pick one and say why in the commit.
2. **Re-arm on a live run loop.** Hop out of `readQueue` before `rearm`, matching `LogMuteAdapter`'s explicit `DispatchQueue.main.async` into `consume(_:)`. A `DispatchSourceTimer` on the read queue is the alternative and avoids the hop entirely; either is acceptable, a `Timer` scheduled from a GCD worker is not.
3. **Give `available` hysteresis.** Require N consecutive failed resolves before dropping it, so a one-tick flap cannot fail the oracle open mid-hold. N is a measurement, not a guess: the per-session flap counts above are the corpus.
4. **Make the resolver's failure legible.** Replace the `try?` in `generations(in:family:)` with a caught and logged error, carrying the errno or `NSError` domain. This is what says whether the 292 rows are a TCC refusal, an I/O error, or a real absence, and it serves MIC8 as much as END9.
5. **Decide what a stale generation means** before the 150 s cap is load-bearing. A generation whose mtime is older than the recording's start is evidence the log is not being written, not evidence that no call ended.
6. **Scope `lastTeardownAt` to the current recording** so a previous call's teardown cannot confirm this one's provisional.
7. **Order `generations` by the name's encoded timestamp**, falling back to mtime only when the name does not parse.
8. **Fence the wiring, not the unit.** A test that builds the real `Coordinator`, runs `start()`, and asserts the watcher is live against a temp directory. Without it this exact regression returns silently.

## Explicitly not in scope

**Not the `endDebounceFloor` for `.axLeaveButton`**, still open from END9's own graft list and still the right shape for the sub-2 s flicker class the oracle structurally cannot reach.

**Not the empty-vs-failed AX walk result type.** `listWindows` still collapses every non-`.success` AXError into `[]`. Orthogonal to the oracle, worth having on its own, and named in END9's open list already.

**Not the manual and attached end-detection gap.** That is END11, filed the same day from the same investigation, and it is a different seam: the lifecycle adapter is never engaged, so there is nothing for any oracle to decide about.

**Not `confirmProvisionalEnd`'s bypass of `requiresCorroboration` and the debounce.** Verified 2026-08-21 as deliberate: `tick()` refuses a lone `requiresCorroboration` lead forever and `handleEndingProvisional` needs a cross-class second signal native Teams does not emit, so that primitive is the sole path by which any ax-leave-led Teams end can promote. END9 correctly moved the decision to its single call site rather than changing the primitive. Do not re-litigate this.

**Not the AX invalidation itself.** Checked and refuted 2026-08-21: `AXLeaveButtonSignal.defaultProbe` maps only `kAXErrorInvalidUIElement` to `.invalid` and transient errors stay `.healthy`, so these are genuine invalidations rather than folded-in messaging timeouts. Also refuted: the 5 s `lastWalkAt` throttle does not make END8's revert unreachable, because `rescueProvisionalEnd` runs its own unthrottled walk and has reverted 35 provisional ends, 11 of them in the five weeks to 2026-08-21.

## Acceptance

- `callTeardown.start()` (or the lazy equivalent) is reached on the ordinary launch path, pinned by a test that exercises the real `Coordinator` wiring rather than a hand-started watcher.
- A test proves the tail ticks more than once, which fails against a `Timer` scheduled from `readQueue`.
- A test proves a single failed resolve inside an open hold does not confirm the end.
- `swift build` and `swift build -c release` clean with no new warnings; `swift test` green; `python3 scripts/truth_fences.py both` green.
- New tests added for each of the scope items above, each measured red against the current `main` before it is fixed, in the way END9's own ship note measured its nine.
- Field bar, checkable by the owner after a working day of Teams calls: `lifecycle_end_held` appears in `events.jsonl` at least once, and no `lifecycle_provisional_end_confirmed` row carries `oracle: "oracle_unavailable"`. Both are greppable in one line, and the first is the direct proof the hold is finally reachable.

## Owner walkthrough

1. **[owner] After the fix installs, use the app normally for a day of Teams calls.** Then grep `events.jsonl` for `lifecycle_end_held` and for `oracle_unavailable`. Expected: the first present, the second absent. This confirms afterwards; it does not gate building.
2. **[owner] If any `hold_cap_reached` rows appear**, the SlimCore teardown line has moved or the log is not being written, and scope item 5 needs re-measuring rather than the constants nudging. END9's `decide()` doc comment already names this as the drift detector.

## Field result 2026-09-02

Item 5 shipped as an instant confirm (`log_stale`) and fired on 11 of the 12 oracle consults between 2026-08-22 and 2026-09-02, 8 of them false ends the owner put back on record by hand. The SlimCore generation's mtime is a flush clock that sits at the previous call boundary for the whole of a quiet call (the mute reader on the same file measured lines landing up to 17 m 59 s after their own stamp), so "not written since the recording began" is the normal state of a live call rather than the signature of a dead log. The correction is [END12](./END12.md); this spec's item 5 and its two pinning tests are superseded by that task, and the field bar under Acceptance above passes while the chop continues (9 `lifecycle_end_held` rows, 8 of them opened on ends corroboration had already confirmed), so read END12's bar instead.
