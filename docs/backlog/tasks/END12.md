# END12: END10's stale-log rule confirms every mid-call provisional end, because Teams' SlimCore log is buffered and event-driven and its mtime never moves during a live call

Band origin: filed 2026-09-02 after the owner reported that a detected recording stops when they move across other windows, frequently on 2026-09-01 and once on 2026-09-02. Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## What is wrong

[END9](./END9.md) built a hold: a provisional end led by a dead Leave button is not confirmed until Teams logs its own call teardown (`SlimCoreModule::WindowContentProtectionProvider: UnregisterCall`), or until a 150 s cap. [END10](./END10.md) shipped on 2026-08-21, started the watcher that END9 had left unstarted, and added its item 5, a freshness rule in `CallTeardownOracle.decide`:

```swift
if let recordingStartedAt = input.recordingStartedAt,
   let writtenAt = input.logLastWrittenAt,
   writtenAt < recordingStartedAt {
    return .confirm(reason: .logStale)
}
```

It runs before the teardown lookback and before the cap, on the synchronous first consult that `MeetingSessionController.beginTeardownHold` makes before it creates the 1 Hz timer, emits `lifecycle_end_held`, or calls `hud.setConfirmingEnd(true)`. A `.confirm` there collapses the whole hold into `confirmProvisionalEnd()` with `held_sec` in microseconds. That is byte-for-byte the pre-END9 shape END10's own spec describes, under a new reason string.

The rule's premise, from `Reason.logStale`'s doc comment, is that a generation "not written since this recording started" is "dead rather than quiet". For this log the premise is false in two independent ways.

**It is event-driven.** SlimCore writes `MSTeamsNM_SlimCore_*.log` only on events: mute toggles (`AirPodsService: Input mute event received`), `SetWindowContentProtection` at call registration and `UnregisterCall` at teardown, screen-share service probes (`GetService host_services::IScreenCaptureService_1`), ECS config refreshes, and one heartbeat pair per hour. A steady call writes nothing. The join burst lands 2 to 4 s *before* `recording_started`, because detection, the prompt, and the owner's accept sit between the two, so the generation reads as stale from the first second of nearly every recording.

**It is buffered.** The lines that do occur mid-call reach the file late. MIC16's `LogMuteAdapter` tails the same file at 1 Hz and stamps each `micgate`/`log_mute_event` with both the line's own `line_ts` and the daemon's read time, so the gap between the two is the flush delay, measured on every such event since 2026-08-22:

| `line_ts` (UTC) | read at (UTC) | delay |
|---|---|---|
| 2026-08-25 07:40:21 | 07:40:22 | 0.7 s |
| 2026-08-27 07:30:39 | 07:31:30 | 50.5 s |
| 2026-08-27 08:30:27 | 08:30:38 | 10.9 s |
| 2026-08-27 11:20:45 | 11:36:28 | 15 m 43 s |
| 2026-08-28 13:30:15 | 13:30:19 | 4.1 s |
| 2026-08-31 10:43:55 | 10:54:21 | 10 m 26 s |
| 2026-08-31 12:45:47 | 12:45:47 | 0.2 s |
| 2026-08-31 13:53:44 | 13:53:44 | 0.8 s |
| 2026-09-01 12:19:25 | 12:19:30 | 5.3 s |
| 2026-09-02 09:09:58 | 09:27:57 | 17 m 59 s |

The last row is the decisive one: the line was read one tick after that call's `UnregisterCall` at 09:27:56 flushed the buffer. `SlimCoreTeardownLog`'s doc comment already records that "SlimCore flushes mid-line routinely"; the size of the delay had never been measured. The generation's mtime is a flush clock, not an activity clock, and flushes cluster at call boundaries, which is exactly when the oracle no longer needs them. Teardown lines themselves flush promptly (END9 measured the line leading the AX edge by about 1.3 s at p50), which is why the oracle looked trustworthy when END9 measured it and why the fast path for a real end still works.

The input the rule reads is `CallTeardownWatcher.tick`'s `s.logLastWrittenAt = tail.modified`, where `SlimCoreMuteLog.tail` copies the generation's `.modificationDate` from `listing(in:family:)`. Nothing in that chain is wrong; it faithfully reports a clock that means something other than what item 5 assumed.

## Observed, not theorized

The installed binary at `~/Applications/MeetingPipe.app` has an mtime of 2026-08-22 00:31, later than END10 (78219db), END11 (1ff3b72) and REC16 (2822f34), and the daemon process has run since 2026-09-01 12:44:43 local. Everything below is END10's code in the field.

**The tally, 2026-08-22 to 2026-09-02 12:45 local.** 29 recordings. 12 `coordinator`/`lifecycle_provisional_end_confirmed` rows: 11 `oracle: "log_stale"`, 1 `oracle: "teardown_observed"`, 0 `oracle_unavailable`, 0 `hold_cap_reached`. Every `log_stale` row carries `held_sec` between 3 µs and 36 µs and `trimmed: false`, the signature of a first-consult confirm.

| Cut (local) | Recording | Cut at | Leading signal | What followed |
|---|---|---|---|---|
| 08-25 16:30:53 | 20260825-163020 | 33 s | ax_leave_button_invalid | re-prompt +70 s, accepted +84 s |
| 08-25 16:37:43 | 20260825-163217 | 5.4 min | ax_leave_button_invalid | re-prompt +61 s |
| 08-26 10:38:30 | 20260826-103036 | 7.9 min | process_audio_is_running_input_false | nothing (real end) |
| 08-27 15:54:01 | 20260827-153523 | 18.6 min | process_audio_is_running_input_false | nothing (real end) |
| 09-01 11:08:40 | 20260901-110746 | 54 s | ax_leave_button_invalid | manual re-attach +6 s |
| 09-01 13:17:48 | 20260901-124908 | 28.7 min | ax_leave_button_invalid | re-prompt +67 s, timed out |
| 09-01 15:05:31 | 20260901-150420 | 71 s | ax_leave_button_invalid | re-prompt +64 s, accepted +67 s |
| 09-01 16:30:46 | 20260901-163023 | 23 s | ax_leave_button_invalid | manual re-attach +36 s |
| 09-01 16:50:01 | 20260901-163122 | 18.6 min | ax_leave_button_invalid | re-prompt +66 s, timed out |
| 09-02 10:10:28 | 20260902-100200 | 8.5 min | process_audio_is_running_input_false | nothing (real end) |
| 09-02 12:36:24 | 20260902-123106 | 5.3 min | ax_leave_button_invalid | manual re-attach +4 s |

Eight of the eleven are Leave-button-led and every one of those eight was followed by a re-prompt or a manual re-attach within 4 s to 84 s, which is the owner putting a live meeting back on record. The three `process_audio_is_running_input_false`-led rows are real ends (Teams released the mic) confirmed for the wrong reason. On 2026-09-01 Teams' own `UnregisterCall` lines place the real ends of the 12:49 and 16:31 calls at 13:28:18 and 16:55:41 local; the cuts came at 13:17:48 and 16:50:01 and both re-prompts timed out, so about 16 minutes across two meetings were never recorded. The 16:30:24 recording was cut at 22.7 s and produced a no-speech `.empty.json` note of its own.

**One cut end to end, 2026-09-02, local time.**

```
12:31:06.699  coordinator/recording_started      20260902-123106.wav
12:36:24.530  lifecycle/ending_provisional       leading_signal: ax_leave_button_invalid
12:36:24.584  coordinator/lifecycle_provisional_end_confirmed  held_sec: 2.98e-06  oracle: log_stale  trimmed: false
12:36:24.585  lifecycle/ended                    confirmed_by: [ax_leave_rewalk]
12:36:25.461  coordinator/recording_stopped
12:36:26.517  coordinator/cooldown_candidate_retained  cooldown_sec: 60
12:36:29.369  coordinator/record_attached        trigger: manual
```

SlimCore's last write before the cut was the previous call's `UnregisterCall` at 12:27:56, three minutes before this recording began, and `MSTeamsNM_SlimCore_2026-09-01_12-44-26.25.log` still carried that mtime at filing. The call ran on; the re-attached recording was still live at 12:45.

**Proof the mid-call lines were not on disk when the rule fired.** The 16:31:22 recording (`20260901-163122`) was cut at 16:50:01 as `log_stale`, which by the rule means the snapshot's mtime was earlier than 16:31:22 on the tick before the consult. That generation today holds an `EcsSettings` line stamped 16:44:24 local (`2026-09-01T13:44:24.973670+03:00`; SlimCore prints UTC and suffixes the local offset, per `SlimCoreMuteLog`). Had the line been on disk at 16:50:00 the mtime would have read 16:44:24 and the rule could not have fired. The same shape twice more that day: the 15:04:20 recording was cut at 15:05:30 and the file now holds lines stamped 15:04:21 and 15:05:29; the 11:07:46 recording was cut at 11:08:39 and the file now holds lines stamped 11:08:37.

**The one hold that worked, 2026-08-31 15:50:30.** Leading signal `ax_leave_button_invalid`, `lifecycle_end_held` emitted, released 11.9 s later on `in_meeting`. A mute toggle 7 s into that recording (line stamped 15:45:47, read 0.2 s later) had happened to flush the file after `recording_started`, so the rule did not fire and END9's design did exactly what it was built to do. Once in twelve, by luck of a flush.

**The one `teardown_observed`, 2026-09-02 12:27:57.** An ECS refresh at 12:25:08 had moved the mtime past the 12:10:49 recording start, so the check passed, and the teardown at 12:27:56 confirmed on the first consult with no added latency. The fast path is intact and stays intact under this task.

**A real end confirmed for the wrong reason, which shows the check also races the flush.** 2026-09-02 10:10:27.55 provisional (process audio), `UnregisterCall` stamped 10:10:26.97, consult at 10:10:28.43 returned `log_stale`, because the snapshot's mtime was still the join burst's 10:01:57, before the 10:02:00 recording start. Had that been a false end, the same first-consult confirm would have cut it with the teardown 1.5 s from being readable, and the timer that exists to catch a late teardown is never created on this path.

**END10's own field bar passes throughout.** Its Acceptance asks for `lifecycle_end_held` present and no `oracle_unavailable`, and both hold: 9 `lifecycle_end_held` rows, 0 `oracle_unavailable`. But 8 of the 9 holds opened on a `process_audio_is_running_input_false`-led provisional that the cross-class corroboration (`ax_leave_button_invalid`) had already promoted between 1.0 s before and 0.3 s after the hold opened; each closed with the stop and produced no `lifecycle_provisional_end_confirmed` row at all. The bar was written against the reason string of the failure END10 fixed, not against the promise, and a `held_sec` in microseconds is the one-line triage for "no hold ran".

## Why the rule looked right when it was written

END10's observation on 2026-08-21: generation `MSTeamsNM_SlimCore_2026-08-13_18-06-05.23.log` was last written at 13:36:15 and still frozen at 14:06 with Teams pid 635 running, while the call ran to 13:56. Read without the flush measurement that is a dead log. Read with it, it is a quiet call whose lines had not flushed; the same generation went on being written until Teams restarted on 2026-08-24 and rolled to `..._2026-08-24_14-14-57.24.log`. The test that pins the rule, `CallTeardownOracleTests.testGenerationFrozenBeforeTheRecordingConfirmsAsStale`, asserts that "a log not written since the recording began cannot be evidence that no call ended", which is true and beside the point: it is not evidence that the call ended either, and the hold exists for precisely that state.

## Scope

The smallest change that fixes the class, in `MeetingPipeCore/Lifecycle/CallTeardownOracle.swift` and its tests.

1. **Remove the instant confirm on staleness.** Delete the `writtenAt < recordingStartedAt` branch in `CallTeardownOracle.decide`, and the `.logStale` reason with it unless item 2 keeps a use for it. A generation not written since the recording began holds like any other and confirms on a teardown or at the 150 s cap; `hold_cap_reached` already carries the drift warning for a genuinely dead log, which is the failure END9 chose as the cheaper one.
2. **If a dead-log notion is kept at all, measure it against the log's own cadence, never against the recording start.** The family writes one heartbeat pair per hour (observed at a fixed minute through the nights of 2026-08-31 and 2026-09-01), so "no write for more than N hours" is the smallest bound that is true of this file, and it still must open a hold rather than confirm on the first consult. Anything shorter has to be measured against the `log_mute_event` lag corpus above before it ships. Not required for item 1, and not a reason to delay it.
3. **Keep the `logLastWrittenAt` plumbing.** END10 items 3, 4, 6 and 7 are unaffected, and the snapshot's mtime remains the right input for item 2 and for any later reader.
4. **Re-state END10's field bar.** In its ToC comment now, and in `owner-verification.md` when that row moves: the count of `lifecycle_end_held` rows proves nothing (see above); the proof is the two greps under Acceptance below.
5. **Tests.** `testGenerationFrozenBeforeTheRecordingConfirmsAsStale` and `testStalenessOutranksAnOldTeardown` pin the wrong rule and flip to what the oracle now does (a generation not written since the recording began holds; an old teardown outside the lookback still does not confirm, for the lookback's reason rather than staleness). `testFreshGenerationWithNoTeardownStillHolds` and `testOmittedEnd10InputsPreserveTheOriginalBehaviour` stay as they are. On the host side, in `CallTeardownHoldTests`, add the 2026-09-02 12:36 replay: generation mtime before the recording start, a Leave-button provisional, no teardown, assert the hold opens (`lifecycle_end_held`, timer, HUD) and releases when the call comes back; and the 10:10:27 replay: same stale-looking mtime, teardown lands on the next tick, assert it confirms as `teardown_observed` inside the hold rather than as anything on the first consult.
6. **Docs.** `Reason.logStale`'s doc comment goes with the case. [`daemon/docs/gotchas.md`](../../../daemon/docs/gotchas.md) carries END10's reasoning under the entry "A frozen generation read as a healthy oracle" and the rule "Degrade toward the old behaviour, never toward the new one"; rewrite the first with the flush measurement and qualify the second (an unreadable log still confirms, a quiet one holds). At filing, `README.md`, `ARCHITECTURE.md`, `CONVENTIONS.md` and `docs/GUIDE.md` contain no `log_stale`, `hold_cap_reached`, or "Confirming end" text, so nothing there changes unless the HUD copy does; re-check with a grep before shipping. END10's spec carries a dated field-result note pointing here (added in this filing).

## Explicitly not in scope

**Not the AX invalidation, the empty-vs-failed walk type, or the `endDebounceFloor`.** All three are END9's open list. The trigger the owner observes, moving across windows, is upstream of this task; END9 measured the 2026-08-03 ends as an accessibility blackout rather than a window collapse and that finding is not re-litigated here. Whatever the trigger, this task is about what happens after the provisional opens.

**Not the re-prompt cooldown.** DET13's and END11's reasoning stands: it is load-bearing against re-prompt storms, and this task removes the false ends that make it bite.

**Not `beginTeardownHold`'s synchronous first consult.** A real end must keep confirming with no added latency, and with item 1 the first consult only ever confirms on a teardown, which is END9's intent.

**Observed, unfiled, named so they are not lost:**

- 8 of the 9 holds since 2026-08-22 opened on a provisional that corroboration had already ended or ended within 0.3 s, writing "holding a provisional end ... probably still up" to `daemon.log` for a call that was over and flashing the HUD's Confirming end during the stop. Harmless, but it is what inflates the `lifecycle_end_held` count END10's bar reads.
- `coordinator`/`call_teardown_source_missing`: 8,424 rows since 2026-08-21, all `NSCocoaErrorDomain 256: The file "Logs" couldn't be opened.`, peaking at 203 in the hour from 11:00 local on 2026-09-01, against a directory of 21,480 entries that a fresh process lists in 13 to 60 ms. It never reached END10's three-in-a-row (0 `oracle_unavailable`), so it caused no cut, but the event carries the Cocoa code and not the underlying errno, so END10 item 4's legibility goal is half met.
- MIC8 and MIC16 read the same file: the same flush delay means a `log_mute_event` can apply a mute state 10 to 18 minutes late and, through `MuteSourceFusion.accepts`, veto the AX reading for 5 s after it lands. Unmeasured in the field; belongs under the MIC band.

## Acceptance

- `CallTeardownOracle.decide` returns `.hold` for an available log with no teardown regardless of `logLastWrittenAt` (or, if item 2 is taken, for any mtime inside the measured cadence bound), pinned by the two flipped oracle tests and the two new host tests, each measured red against `main` before the change and named in the ship note.
- `swift build` and `swift build -c release` clean with no new warnings; `swift test` green with the tests this task adds; `python3 scripts/truth_fences.py both` green.
- Field bar, one grep each over `events.jsonl` after a working day of Teams calls with window switching: zero `lifecycle_provisional_end_confirmed` rows with `oracle: "log_stale"`; every `lifecycle_provisional_end_confirmed` row with `held_sec` under 1 s carries `oracle: "teardown_observed"`; and every `lifecycle_end_held` opened on an `ax_leave_button_invalid`-led provisional during a live call is followed by `lifecycle_end_hold_released`, not by `recording_stopped`.
- If the HUD's Confirming end copy or timing changes, `README.md` and [`docs/GUIDE.md`](../../GUIDE.md) are updated in the same commit, per the guide's same-commit contract.

## Owner walkthrough

1. **[session] After the fix lands, check the installed binary's mtime is later than the landing** before asking for anything below; a walkthrough against the old build proves nothing.
2. **[owner] Join a Teams call, accept the prompt, then spend a minute or two in other apps and come back.** Pass: the recording keeps running, and if the HUD shows Confirming end it clears by itself within a couple of minutes. Fail: the recording stops and the menu offers Record again.
3. **[owner] Leave the call.** Pass: the recording stops within a few seconds, which is the teardown fast path and must not have slowed down.
4. **[session] Run the three Acceptance greps over that day's `events.jsonl`.** This confirms afterwards; it does not gate building.
