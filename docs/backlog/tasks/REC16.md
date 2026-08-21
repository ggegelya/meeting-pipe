# REC16: a recovered engine stops hearing device changes, and a capture gap spanning system sleep is padded with the wrong clock

Band origin: filed 2026-08-21 from the capture-health sweep run during the END10 and END11 investigation, not from an owner report. Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## What is wrong

Three defects in `MeetingRecorder`, all on the mid-recording capture-health paths, all found by reading the recorder against the field log rather than from a symptom. They are filed together because they share one seam and one test fixture; splitting them would mean three sessions loading the same engine-lifecycle context.

## One: a replaced engine is deaf to device changes for the rest of the recording

`armConfigurationChangeObserver()` registers with `object: engine`, so the observer is bound to one specific `AVAudioEngine` instance. It is called from exactly one place, inside `start()`, with the comment "Re-arm capture on a mid-recording device swap (e.g. AirPods unplugged) instead of flatlining the mic."

[REC15](./REC15.md) shipped on 2026-08-19 and gave `recoverCapture` the ability to replace a condemned engine mid-recording (`engine = AVAudioEngine()`, under the comment "replacing the audio engine mid-recording: an installTap raise condemned it"). It does not re-arm the observer. From that moment the observer is watching an object nothing posts to any more, so `AVAudioEngineConfigurationChange` from the live engine never reaches `handleConfigurationChange`, and the exact failure the observer exists to catch runs unhandled for the rest of the recording.

This is a regression introduced by REC15's own fix and it is the reason to fix it here rather than fold it into REC15's remaining owner-verification: REC15's shipped behaviour is correct at the moment of recovery and wrong immediately afterwards.

The third replacement site, in `unwindFailedEngineStart`, is harmless by position: it runs on a failed start, so no recording is live to lose. The site inside `start()` runs before `armConfigurationChangeObserver()` and is therefore also fine. `recoverCapture` is the only one that matters.

## Two: the two capture channels use different clocks, and the system one stops during sleep

The system-audio outage span is measured with `ProcessInfo.processInfo.systemUptime`: `systemLostUptime` is stamped from it, `let now = ProcessInfo.processInfo.systemUptime` is taken on the retry, and the difference becomes the `gap_sec` and the `pad_frames` written into the file. On Darwin that clock does not advance while the system is asleep.

The mic-side gap uses wall clock instead (`evaluateConfigurationChange(gapStart: Date())` from the configuration-change handler, and a `Date()` stamp on the stall path), which is correct across a sleep. So the two channels disagree about how long an outage lasted whenever the Mac sleeps mid-recording, and they drift apart by exactly the sleep duration.

**Measured in the field, 2026-08-17.** `recorder`/`system_capture_lost` fired at 17:45:14 local with reason "Failed to find any displays or windows to capture". `recorder`/`did_wake_while_recording` and `recorder`/`system_capture_resumed` both fired at 17:54:31. Wallclock gap: 557.0 s. The padding written: `{"gap_sec": 106.81894104165258, "pad_clamped": false, "pad_frames": 5127309}`, which is 106.82 s at the 48 kHz capture rate. **The shortfall is 450.2 s, seven and a half minutes**, and `pad_clamped: false` confirms no cap was involved, so the computed gap really was that short.

The consequence is not lost audio, it is a silently wrong timeline: the finished file is shorter than the meeting by the sleep duration, and every system-channel sample after the wake is stamped seven and a half minutes early relative to the mic channel and to reality. Transcript and diarization timestamps after the wake inherit that error.

The control case is in the same log and shows the arithmetic is otherwise sound: on 2026-08-19 an outage with no sleep in it (`system_capture_lost` 11:03:44, `system_capture_resumed` 11:03:51) padded `gap_sec: 7.679` against a 7 s wallclock gap.

This is the same wall-versus-monotonic class PIPE10 already fixed (shipped, archived in [`q6-final.md`](../q6-final.md)) on the summarize timeout, in a different subsystem.

## Three: an unrecoverable configuration change leaves the recording running with a dead mic

Every `configuration_change_unrecoverable` path ends in `reportRecoveryFailure()`, which increments a counter, may call `abandonMicCapture`, and fires `onConfigurationChange?(.failed)`. None of them stop the recording. The daemon log line says "mic capture stopped", and it means the mic, not the recording.

So the recording continues to its normal end writing a dead mic channel, behind a single notification. In the field the event fired 13 times against 5 `configuration_change_recovered`. The owner's report of recordings "dropping" is satisfied by a file that keeps growing while capturing nothing from the mic just as well as by one that ends early, and this path is currently indistinguishable from the healthy one once the notification is dismissed.

Whether the right answer is to stop, to keep going with a louder and persistent surface, or to keep going and mark the sidecar is a product decision, not an obvious bug fix, which is why this is stated as a defect in the surfacing rather than in the control flow.

## Scope

1. **Re-arm the configuration-change observer whenever the engine is replaced.** The cheapest correct shape is to remove and re-add inside the replacement, or to hang the arm off a single `replaceEngine()` helper that all three sites call so a fourth site cannot reintroduce this. Prefer the helper.
2. **Measure the system-capture gap on the wall clock**, or add the sleep duration back explicitly from the wake notification. Keep `pad_clamped` and its cap: a sleep-length pad is exactly the case the cap exists for, and this change makes the cap start mattering, so re-check its value against the two field cases above rather than assuming it.
3. **Make an unrecoverable mic failure legible for the rest of the recording.** At minimum the HUD's degraded state must persist rather than fire once, matching how `recording`/`degraded` and `recording`/`recovered` already ride the banner. Whether the sidecar records it is the pickup session's call.

## Explicitly not in scope

**Not REC15's own subject.** The `installTap` format-mismatch raise, the single retry on a fresh engine, and the 1 Hz recovery spin are all REC15, shipped 2026-08-19 and awaiting the owner's verification. The 2026-08-19 field occurrences at 10:46:46, 10:46:50 and 11:08:56 predate that fix landing at 12:01:56 and are evidence for REC15 rather than against it.

**Not the one-recovery-at-a-time latch.** `recoverCapture` deliberately drops a re-entrant device change while a restart is in flight, and its comment says so: "Run one at a time: a re-entrant device change while a restart is in flight is dropped; the watchdog or the next change re-triggers." Checked 2026-08-21 and left alone.

**Not the mic gap's 2.5 s detection latency.** The stall watchdog stamps its gap when the stall is noticed rather than when the tap died, so up to `stall_after_s` of the gap is unaccounted. Real, bounded, and much smaller than item 2; note it while item 2 is open and fix it only if the same code moves.

**Not the idle-sleep assertion's scope.** REC8 holds `PreventUserIdleSystemSleep`, which permits display sleep, and the 2026-08-17 case is a real system sleep that got past it. Whether the assertion should be stronger is REC8's question, not this one.

## Acceptance

- A test proves that after `recoverCapture` replaces the engine, a subsequent `AVAudioEngineConfigurationChange` still reaches `handleConfigurationChange`. Red against `main`.
- A test drives the gap computation across a simulated sleep (a wall clock that advances while the monotonic clock does not) and asserts the pad matches the wall gap. Red against `main`, and it should reproduce the 2026-08-17 numbers: a 557 s gap padding 557 s rather than 106.8 s.
- A test pins whichever surfacing item 3 chooses for an unrecoverable mic failure.
- `swift build` and `swift build -c release` clean with no new warnings; `swift test` green; `python3 scripts/truth_fences.py both` green.
- The two retry paths REC15 could not test behaviourally stay untested for REC12's reason (a live engine bound to a real input device, which neither CI nor this runner has). Do not claim coverage there.

## Owner walkthrough

1. **[owner] No staged repro is needed for items 1 and 3.** Use the app normally with the AirPods for a working day, then grep `events.jsonl` for `configuration_change_unrecoverable` and confirm the HUD showed a persistent degraded state for any recording that carries one.
2. **[owner] Item 2 has a cheap deliberate repro if you want one:** start a recording, close the lid for two minutes, reopen, stop. Pass: `system_capture_resumed`'s `gap_sec` is close to the wallclock time the lid was shut, not a fraction of it.
