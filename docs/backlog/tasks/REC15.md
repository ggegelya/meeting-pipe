---
id: REC15
title: A caught installTap raise costs the whole meeting's mic, and spins at 1 Hz while it does
category: Recording
status: partial
priority: P2
comment: Filed 2026-08-19 from the field, by the owner reporting the toast "Could not start recording: Audio engine failed to start: installTap raised on the input node". REC12's barrier is working (three raises that day, zero crash reports); what it did not cost out is what the survivor does next, and both halves were wrong. **The toast** is an auto-start lost to a race rather than a state: `installTap` re-reads the hardware format after we read it, the AirPods had gone back to 48000 Hz while the tap was requested at 24000, and the owner's own manual retry 22 s later read 48000 and recorded 22 minutes. Nothing tried that on their behalf. **The third raise**, 18 minutes after REC12's ship note was written, is the larger one: it landed mid-recording, and since every terminal return from `recoverCapture` leaves the engine stopped while REC8 deliberately un-gated the 1 Hz tap watchdog from `engine.isRunning`, recovery was re-entered every second and refused every time (12 consecutive refusals, ended only by the owner hanging up). The `.timedOut` branch's comment asserted the watchdog "stops once isRunning is false", which stopped being true at REC8 and is why the spin looked impossible. **Shipped 2026-08-19, three changes.** A raised start retries once on a fresh engine (raises only, never format refusals: the barrier's own doc draws that line, and a refusal is a state where a raise is a race); `recoverCapture` replaces a condemned engine and retries once the same way, re-applying voice processing and re-reading the format on the new node, so the mic comes back mid-meeting; and `TapWatchdogPolicy.decide` gained a `micAbandoned` input, set at once when a fresh engine also raises and otherwise after a budget of 5 consecutive failed recoveries. A bound rather than a latch, because the other four terminal returns can succeed on the next attempt. A real device-change notification still reaches recovery: it carries new information about the route, where the watchdog's tick carries none. 5 tests, measured red by deleting the guard. Three new `recorder` actions (`mic_tap_start_retried`, `mic_tap_recovery_retried`, `mic_capture_abandoned`), no new category. The two retry paths are not behaviourally tested, for REC12's reason (a live engine bound to a real input device, which neither CI nor this runner has); the pure half that spun is. Spec in [`tasks/REC15.md`](./REC15.md). **P2 by the REC10 precedent** (loss on a path reached only after another failure); the owner may re-band, since the outcome is a whole meeting uncaptured. **Owner-owed:** walkthrough steps 2 and 3, proposed weight `simple` (use the app normally with the AirPods for a day, then grep two event actions; no staged repro). Needs the owner's approval before the row moves to `owner-verification.md`. Amended 2026-11-13 by the audit band: `micCaptureAbandoned` is cleared only by start(), so after a recovery that reports resumed the watchdog and wake re-check stay shut for the rest of the recording; clear it on success (F027).
---

# REC15: a caught installTap raise costs the whole meeting's mic, and spins at 1 Hz while it does

Filed 2026-08-19 from the field, by the owner reporting the error toast "Could not start recording: Audio engine failed to start: installTap raised on the input node; the audio engine was replaced". Shipped the same day.

REC12 is the parent and it did its job: the raise that used to abort the process is caught, and the four crash reports have no successor. What REC12 did not cost out is what the survivor does next, and both halves of that turn out to be wrong.

## The evidence

Three raises on 2026-08-19, all `com.apple.coreaudio.avfaudio: Failed to create tap due to format mismatch`, all on AirPods Pro renegotiating between 24000 Hz (call mode) and 48000 Hz. Times are UTC, as `events.jsonl` writes them; the owner's stems are local at +3.

| `ts` | site | requested format | outcome |
|---|---|---|---|
| 07:46:46 | `mic_level_monitor` | 24000 Hz, 1 ch | prompt waveform flat, the documented degradation |
| 07:46:50 | `meeting_recorder` | 24000 Hz, 1 ch | **the toast**: auto-start failed, meeting not captured |
| 08:08:56 | `meeting_recorder` | 48000 Hz, 1 ch | mid-recording, mic dead for the rest of the call |

The first two are the pair REC12's ship note recorded. The third fired 18 minutes after that commit was written and is what this task is mostly about.

**Half one, the toast.** The raise is a race, not a state: `installTap` re-reads the node's hardware format after we read it, and on 2026-08-19 the hardware had gone back to 48000 while the tap was requested at 24000. The proof that it is a race and not a wall is the owner's own recovery: they started by hand 22 s later, the read returned 48000, and the recording ran 22 minutes. Nothing tried that on their behalf.

**Half two, the spin.** After the 08:08:56 raise the engine was condemned and left stopped, and the 1 Hz tap-liveness watchdog re-entered device-change recovery every second and was refused every time:

```
08:08:57 refusing to install a mic tap ... it needs replacing, not retrying
08:08:58 refusing to install a mic tap ... it needs replacing, not retrying
   ... 12 consecutive refusals, ending only because the owner hung up at 08:09:08
```

`MeetingRecorder.start()` has always replaced a condemned engine; `recoverCapture` never did, and its comment said the next `start()` would pick a fresh one, which is true and is a whole meeting away. On a call that ran another hour this would have been an hour of dead mic and 3 log lines a second.

**Why it spun rather than stopping** is a stale comment that was true when it was written. The `.timedOut` branch said the watchdog "stops once isRunning is false". REC8 deliberately un-gated it from `engine.isRunning`, precisely so a silently stopped engine would be caught, which makes a stopped engine the strongest re-arm trigger there is. Every terminal return from `recoverCapture` leaves the engine stopped, so all five of them re-enter at 1 Hz, not just the condemned-engine one.

## What shipped

1. **A raised start retries once on a fresh engine.** The mic chain (voice processing, format read, mic file, gate, serial writer, guarded tap) moved into `buildMicChain`, which is written to run twice; `unwindFailedEngineStart(recreateEngine: true)` clears it between attempts. Only a **raise** retries, never a format refusal: the barrier's own doc draws that line, since a refusal means the HAL has no usable input (a state, unchanged a millisecond later) while a raise means the format moved (a race, and the next read may have caught up). Once, never in a loop, because a second raise means the format is still moving and a retry loop against a transitioning route is the busy-wait REC12's condemnation exists to refuse.

2. **Recovery replaces a condemned engine and retries once**, the same rule and the same reason, so the mic comes back mid-meeting instead of staying dead. Voice processing is re-applied to the replacement (it does not carry across, and the flag and the node would otherwise disagree for the rest of the recording, which `stop()` reads), and the format is re-read on the new node, rebuilding the converter when it differs from the file format.

3. **The watchdog stands down instead of spinning.** `TapWatchdogPolicy.decide` gained a `micAbandoned` input, checked first because it is the only input that says asking again cannot help. It is set two ways: immediately when a **fresh** engine also raises (provably unfixable by repetition), and otherwise after a budget of 5 consecutive failed recoveries, counted in `reportRecoveryFailure`, which every terminal return already passes through. A bound rather than a latch, because the other four returns (wedged teardown, converter, restart failed, restart timed out) can succeed on the next attempt and standing down on the first would throw away a recovery that was going to work. Cleared by a successful recovery and by `start()`, so the next meeting begins with a full budget however badly this one ended. A real device-change notification still reaches `recoverCapture`: that carries new information about the route, where the watchdog's tick carries none, and that is the whole distinction.

Three new event actions, all in the existing `recorder` category: `mic_tap_start_retried`, `mic_tap_recovery_retried`, `mic_capture_abandoned`.

## Explicitly not in scope

**Not a settle delay before the retry.** An immediate retry re-reads `outputFormat`, which is a fresh HAL query, and there is no measurement saying how long the transition takes. Guessing a number here would encode taste as a constant. The two retry event rows carry the refused and retried sample rates, so the field says whether a delay is needed rather than this task assuming it.

**Not the format check.** REC12's `isInstallable` predicate is unchanged and still refuses 0 Hz / 0 ch before `installTap` is reached.

**Not the condemnation contract.** A condemned engine is still never handed another tap. Both retries here run on a replacement, which is the sanctioned way back that `GuardedTapInstall`'s doc already names.

**Not `MicLevelMonitor`.** Its engine is a `let` held for the monitor's lifetime and a flat waveform is its documented degradation, which is worth incomparably less than a meeting. The 07:46:46 raise stays a flat waveform.

**Not the budget as a tuned number.** Five is a backstop. The watchdog only fires after the tap is already declared stalled, so it is five seconds of asking again before the mic is given up, against the alternative of asking for the rest of the meeting. `mic_capture_abandoned` carries the count, so a recovery succeeding on a sixth attempt would be visible.

## Acceptance

- A test asserts an abandoned mic never re-arms, including on a stopped engine, which is the REC8 trigger this has to override. Red against the unfixed policy.
- A test asserts the default keeps every pre-REC15 call site meaning what it meant, so the three abandonment tests are the only behaviour change.
- A test pins the budget's off-by-one: a budget of 5 is spent on the fifth failure, not the sixth.
- The stale `.timedOut` comment is corrected rather than left, since it is the claim that made the spin look impossible.
- `swift build` and `swift build -c release` clean with no new warnings, `swift test` green with the number of tests recorded in the ship note. Do not pin an absolute suite total.
- `python3 scripts/truth_fences.py both` green. No new event category, so nothing is owed to the `CONVENTIONS.md` table, which fences categories rather than actions.
- No em-dashes in changed lines.

> **Verified 2026-08-19.** Every bar above is met. **+5 tests** in `TapWatchdogPolicyTests` (abandoned on a stopped engine, abandoned on a stalled running engine, the default preserving REC8, the budget's off-by-one, a first failure not spending it). **Measured red, not asserted:** deleting the `micAbandoned` guard turned 2 of them red on their own assertions; the restore was re-run green. `swift build` and `swift build -c release` clean, `swift test` 2840 tests 0 failures (the one pre-existing `MCPStatusStore.ceilingSeconds` actor-isolation warning is untouched and predates this), truth fences green, no pipeline change.
>
> **What this does not claim.** The two retry paths themselves are not behaviourally tested, for REC12's reason: they need a live `AVAudioEngine` bound to a real input device, which neither CI nor this machine's test runner has. What is pinned is the loop that spun, which is the pure half. The retries are evidenced by the field rows they emit, in the same instrument-then-measure shape REC12 used.

## Owner walkthrough (for the session that picks this up)

Steps are tagged [owner] / [session] by who acts.

1. [session] `./scripts/rebuild.sh` after landing, then tell the owner it is ready. Landing on `main` is not installing, and a walkthrough run against the old binary proves nothing.
2. [owner] Use the app normally with the AirPods for a working day. Pass: no repeat of the "installTap raised on the input node" toast on a meeting that then records fine by hand. Worth grepping the same day: `grep mic_tap_start_retried ~/Library/Logs/MeetingPipe/events.jsonl`. A row there with `"installed": true` is the toast this task removed, caught in the act.
3. [owner] If a raise does land mid-recording, check `grep mic_tap_recovery_retried` and `grep mic_capture_abandoned` in the same file. A recovery retry with `"installed": true` means the mic came back mid-call; an abandon row means it did not, and its `consecutive_failures` is the number the budget should be re-argued against.
4. [owner] Say "REC15 good to close" (or what is wrong); [session] moves the row and this spec into `q6-final.md` and deletes this file.

## Amendment 2026-11-13 (audit band)

Source: [independent audit](../../audits/2026-11-12-independent-audit.md) F027 (confirmed, new). Re-verified in code at HEAD on 2026-11-13; the recovery code now lives in `InputDeviceRecovery` (moved out of `MeetingRecorder` after this task shipped), and the behaviour is as below.

**The abandon flag is a latch after all.** This spec's item 3 says the stand-down is "Cleared by a successful recovery and by `start()`". At HEAD only half of that holds. `recoverCapture`'s success tail resets the failure run (`captureRecoveryFailed = false`, `consecutiveRecoveryFailures = 0`) and calls `host.reportConfigurationChange(.resumed)`, but never touches `micCaptureAbandoned`; the only reset is `resetForRecording()`, called from `start()`, and the flag's own doc comment says "cleared by `start()`". Meanwhile a real `AVAudioEngineConfigurationChange` still reaches `handleConfigurationChange` after abandonment, by design, and can succeed.

**What that costs.** Headset drops, five recoveries fail, `mic_capture_abandoned` fires. The headset reconnects, the configuration-change recovery succeeds, `Coordinator`'s `.resumed` branch calls `recordingHUD.setMicCaptureLost(false)` and posts "kept recording", so the HUD looks healthy. But `checkTapLiveness` (`guard !micCaptureAbandoned else { return }`) and `recheckAfterWake` (`guard let host, host.isRecording, !micCaptureAbandoned`) stay shut for the rest of the recording, so a later silent tap stall, or a wake with a stopped engine, is never re-armed, and the mic channel is empty until stop with no surface saying so.

Field: the latch itself is not observable in the [field evidence](../../audits/2026-11-13-field-evidence.md) pack (no `mic_capture_abandoned` followed by `configuration_change_recovered` in one recording); its cross-check finds the adjacent F029 consistent (mic track ending short after 4 tap stalls), which is [REC16](./REC16.md)'s amendment.

### Scope addition

5. **A recovery that reports resumed un-abandons the mic.** In `InputDeviceRecovery.recoverCapture`'s success tail, clear `micCaptureAbandoned` beside `consecutiveRecoveryFailures = 0`, and log it (a `mic_capture_unabandoned` action in the existing `recorder` category, carrying the reason the mic had been abandoned), so the field can tell a recovered abandonment from one that stayed down. Correct the flag's doc comment and this spec's item 3 wording to match. The 1 Hz spin REC15 fixed cannot return: the flag is cleared only on a recovery that actually restarted the engine and installed the tap.

### Acceptance additions

- A test that abandons the mic (budget exhausted), then drives a successful recovery through the configuration-change path, and asserts the watchdog's next tick re-arms on a stalled tap and the wake re-check re-arms on a stopped engine. Red against `main`. If the recovery tail still needs a live engine to run, extract the post-success state change into a seam the test can drive, in the `TapWatchdogPolicyTests` shape, rather than claiming coverage of the engine path.
- `swift build`, `swift build -c release` clean, `swift test` green with the number of new tests in the commit body, `python3 scripts/truth_fences.py both` green.
