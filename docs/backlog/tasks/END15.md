---
id: END15
title: Switching the microphone inside a Teams call ends the recording, because Teams' brief input release corroborates a flickering Leave button
category: Detection
status: partial
priority: P1
comment: Fix shipped inside END17 (owner folded it in, 2026-10-24): a process-audio drop no longer confirms an end on arrival, and its return reverts the hold in both orders. Remaining: the owner measures the device-switch gap (switch mics 3 to 5 times in a test call) so it can sit beside `PromotionEngine.defaultConfirmDwell` (60 s), and the walkthrough. Filed 2026-10-22 from the owner reporting that changing the mic in Teams mid-call stops the recording; broken promise: a live call is recorded as one file. `20261022-150025.wav`: the Leave button read invalid at 12:14:53Z, END9's hold opened (no `UnregisterCall`, `live_signal=call_is_up`), then Teams released its input while reopening the new device at 12:14:59Z and `PromotionEngine.handleEndingProvisional` took that as cross-class corroboration and ended at once, bypassing the hold; the owner re-attached 22 s later with the mic already back. Recorder unaffected. Two unconfirmed same-shape splits (2026-09-18, 2026-09-22). Scope: a process-audio `.ended` corroborates or leads only after a measured dwell, and a `.live` inside it reverts. Owner may re-band. [Spec](./END15.md) Amended 2026-11-13 by the audit band: the pack holds one chop (this incident, era B) and none in era C; field mic gaps of 23.1 s and at most 23.54 s, measurement folded into DET23.
---

# END15: switching the microphone inside a Teams call ends the recording, because Teams' brief input release corroborates a flickering Leave button

Band origin: filed 2026-10-22 from the owner reporting that changing the microphone in Teams mid-call stops the recording. Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## What happened

The owner switched the input device from Teams' own device picker during a live call on 2026-10-22. Recording `20261022-150025.wav` (started 12:00:25Z) stopped at 12:14:59Z, and the owner re-attached by hand at 12:15:21Z, producing a second file, `20261022-151521.wav`. The call never ended. The rows, from `events.jsonl` (UTC):

```
12:14:53.286Z signal     ax_leave_button_state      healthy -> invalid (health_poll)
12:14:53.287Z lifecycle  ending_provisional         leading_signal=ax_leave_button_invalid
12:14:53.443Z coordinator lifecycle_end_held        hold_cap_sec=150 live_signal=call_is_up
12:14:59.002Z signal     process_audio_is_running_input  true -> false
12:14:59.006Z lifecycle  ended                      leading=ax_leave_button_invalid confirmed_by=[process_audio_is_running_input_false]
12:14:59.012Z coordinator state_change              recording -> stopping
12:15:21.948Z coordinator record_attached           trigger=manual
12:15:22.542Z signal     process_audio_is_running_input  initial value=true
12:15:22.569Z signal     ax_leave_button_state      initial healthy
```

No `UnregisterCall` was observed (that is why END9's hold opened), and 23 s later Teams was holding the mic and showing a healthy Leave button again. The recorder side behaved correctly: there is no `AVAudioEngineConfigurationChange`, no `configuration_change_unrecoverable`, and no HAL default-input (`dIn`) change in the window. Teams picking a different device does not move the macOS default input, so the daemon's own mic tap on `MacBook Pro Microphone` was never disturbed. This is a lifecycle false end, not a capture failure.

## The causal chain

1. Opening the device picker or applying the new device re-renders Teams' call controls, and `AXLeaveButtonSignal`'s health poll reads the Leave button as `invalid`. That is the known accessibility-teardown flicker END9 was built around ([teams false end is an a11y teardown](../../../daemon/docs/gotchas.md#a-signal-cannot-corroborate-itself)).
2. `MeetingSessionController.rescueProvisionalEnd` found no Leave button and called `beginTeardownHold`. `CallTeardownOracle.decide` returned `.hold`, logged as `lifecycle_end_held` with `live_signal=call_is_up`. Up to here everything worked as designed.
3. Teams closes its input stream on the old device and opens the new one. For that gap every Teams process object reports `kAudioProcessPropertyIsRunningInput == false`, so `ProcessAudioSignal` emits `.ended`.
4. `PromotionEngine.handleEndingProvisional`, `.ended` branch: `processAudioIsRunningInput` is in a different `EndEvidenceClass` from `axLeaveButton`, so `event.kind.evidenceClass != leading.evidenceClass` holds and the engine promotes to `.ended` at once. The teardown hold lives in the host (`MeetingSessionController.teardownHold`), not in the engine, so nothing in `PromotionEngine` knows that the only oracle able to tell a teardown from a re-render has just said "still up". The fast path bypasses END9's hold entirely.

The assumption that broke is the one stated in `CallTeardownOracle`'s doc comment, from the 2026-08-20 corpus run: process audio is "a signal that never fires without a real teardown". It does fire without one: an in-call device switch releases the input for a few seconds. DET12 already measured that an in-call **mute** produces zero `isRunningInput` transitions, which is why this was not seen before; a device switch is a different act.

## Same shape elsewhere in the log (unconfirmed)

A scan of `events*.jsonl` (2026-09-15 to 2026-10-22) for a lifecycle `ended` followed by a new `recording_started` within 3 minutes found two more pairs of the same signal shape with short restarts, neither yet tied to a mic switch:

- 2026-09-18T09:39:46Z, restart 33 s later, `leading=process_audio_is_running_input_false confirmed_by=[ax_leave_button_invalid]`
- 2026-09-22T14:52:04Z, restart 20 s later, same pair

These are the reverse order (input release first, Leave flicker second), which goes through `handleInMeeting`'s provisional and the same cross-class fast path. Any fix has to cover both orders. The 55 s and 71 s restarts in the same scan are more likely back-to-back meetings and are not claimed here.

## Scope

Make a brief Teams input release unable to end a call on its own pairing with a same-moment Leave flicker. The seam is `PromotionEngine`'s cross-class fast path in `handleEndingProvisional` and `handleInMeeting` where `processAudioIsRunningInput` is either the lead or the corroborator.

The preferred shape: a `processAudioIsRunningInput` `.ended` counts as a cross-class corroborator (or opens a provisional as lead) only once it has stayed `.ended` for a dwell, and a `.live` from it inside that dwell reverts the provisional the way END14's `veto(for:in:)` revert already does. The dwell constant is pinned from measurement, not taste: DET8's 2026-08-05 probe measured Teams clearing every object's input flag within 11.4 s of a real leave, so the pickup session first measures the device-switch release gap (owner-run: switch mics three to five times in a test call, read `process_audio_is_running_input` transitions from `events.jsonl`) and sets the dwell above the observed maximum and documents both numbers beside the constant. The cost is added end latency on a genuine leave only where process audio is the deciding signal; the hold's audio trim back to `provisionalStartedAt` means nothing extra is published.

The alternative, letting the host's open teardown hold veto the engine's fast path, is recorded so it is not re-litigated: it fixes the ax-leave-first order only (the 2026-09-18 and 2026-09-22 shape never opens a hold), and it moves end-decision state out of the pure engine into the host, against the island rule.

## Explicitly not

- Watching Teams' device picker through AX, or the HAL default-input change. Teams' choice does not move the system default (no `dIn` row on 2026-10-22), and AX labels are the localized-scraping class this repo avoids.
- Removing `processAudioIsRunningInput` from the corroborator set. It is the best end evidence the engine has (`CallTeardownOracle`'s table: 4 confirms, 0 holds as a lead) and END14 depends on it as the veto.
- Any recorder change. Mic capture survived the switch.
- Adjacency, observed but not filed here: `call_teardown_source_missing` ("NSCocoaErrorDomain 256: The file “Logs” couldn’t be opened.") was emitted 6131 times in `events.jsonl` between 2026-10-13 and 2026-10-22, including three times in the two minutes before this incident. `CallTeardownWatcher` only logs on a changed cause, so that count means the source flaps between readable and unreadable. If the oracle is intermittently blind, every END9 hold is weaker than it looks. It deserves its own investigation (dedupe against END10 item 4 first).

## Acceptance

- `PromotionEngineTests` (MeetingPipeCoreTests) pins, with synthetic signals:
  - ax-leave `invalid` lead, then process-audio `.ended`, then process-audio `.live` inside the dwell: verdict returns to `.inMeeting`, never `.ended` (the 2026-10-22 sequence).
  - process-audio `.ended` lead, then ax-leave `invalid`, then process-audio `.live` inside the dwell: no `.ended` (the 2026-09-18 sequence).
  - genuine leave: ax-leave `invalid` and process-audio `.ended` with no return: `.ended` once the dwell elapses, `confirmed_by` still names process audio.
  - END14's clean-leave pair (window-gone then process-audio `.ended` within the debounce) still ends, and END14's veto tests stay green unchanged.
- A test fails without the fix (the first scenario promotes on the current fast path).
- The dwell constant carries the measured device-switch gap and DET8's 11.4 s next to it.
- `cd daemon && swift build` and `swift test` green (CI if local XCTest is unavailable), with the new test count stated in the commit body; `python3 scripts/truth_fences.py` clean if a new event action is added (`CONVENTIONS.md` table in the same commit).
- Owner walkthrough, confirming after the build is installed (not a precondition): switch the mic twice in a live Teams call; one recording results, and `events.jsonl` shows no lifecycle `ended` between the switches.

## Amendment 2026-11-13 (audit band)

Source: D034 in the [recording reliability audit](../../audits/2026-11-13-recording-reliability-audit.md), detail and field rows in its [evidence file](../../audits/2026-11-13-recording-reliability-evidence.md). Re-verified at HEAD 3a2da4fc on 2026-11-14.

**What the field pack adds.** The instant cross-class confirm in `PromotionEngine.handleEndingProvisional` survived END14 (8d4a9449, 2026-10-12) and was removed by END17 (01e904a5, 2026-10-24), but the work laptop was not rebuilt in between: it ran END14 code from 2026-10-12 to 2026-11-12 (era B) and an END17 build only from 2026-11-12 (era C). Across the pack's 381 lifecycle `ended` rows the audit found exactly one instance of the chop, and it is this task's incident: stem `20261022-150025`, Leave `invalid` and `ending_provisional` at 12:14:53.287Z, `lifecycle_end_held` with `live_signal=call_is_up` at .443, `process_audio_is_running_input` false at 12:14:59.002Z, lifecycle `ended` 4 ms later with `confirmed_by=[process_audio_is_running_input_false]`, and a manual `record_attached` 22.9 s later with Leave, mute and mic all live. One more probable instance predates the pack: 2026-09-14T14:20:36Z (stem `20260914-163053`, era A code) stopped 6.5 s after a hold was logged, mid-topic, and was re-attached by hand 405 s later (from `daemon.log` and the transcript; its events had rotated out). Era C has 0 fast confirms of any kind, and its one comparable event (stem `20261112-172307`, mic released at 2026-11-12T15:39:16Z, Leave invalid 1 s later, a matching window back at +22.0 s, mic back at +23.1 s) was held and reverted with nothing trimmed.

**Nothing left to code.** At HEAD the `.ended` branch confirms on arrival only `if event.kind.isDefinitive`, which is `self == .workspaceAppTerminated`; every other `.ended` is absorbed and `PromotionEngine.tick` confirms a pair only when `dwelled.count >= 2` classes have stayed ended for `confirmDwell`. A returning signal reverts the hold (`let returning = previous?.state == .ended`). END15's four acceptance scenarios already sit in END17's tests.

**What remains is the measurement, now with two field gaps.** The only two mid-call mic releases in the pack lasted 23.1 s (`20261112-172307`) and at most 23.54 s (`20261022-150025`: release at 12:14:59.002Z, the re-attached session's initial process-audio reading true at 12:15:22.542Z). `PromotionEngine.defaultConfirmDwell` is 60 s, so it clears both by about 2.5 times, and anything under 30 s is not safe (D109's direction). The constant's doc comment still says "the exact gap still to be measured by the owner"; it should carry both field numbers beside DET8's 11.4 s.

Correction at filing: this file's header comment says the owner re-attached "22 s later"; the logged gap is 22.9 s from the end to `record_attached`, and the mic gap itself is bounded at 23.54 s. The audit's "mic switch chop on the installed build" is live only on builds older than 01e904a5, which the work laptop no longer runs.

**Scope addition (measurement only, no engine change).** Fold the owner's device-switch measurement into [DET23](./DET23.md)'s `mic_gap` rows and its uncensored same-call gap table, plus one deliberate test call with five input-device switches and one Bluetooth headset connect, read from those rows. Whether `defaultConfirmDwell` moves is decided from that table, never below the largest observed gap plus margin. The separate failure where a Leave-led hold older than 12 minutes ends within one tick of a mic blip (the lone dwell measured from the hold's start, D029) is [END18](./END18.md)'s, not this task's.

**Acceptance additions.**

- The `defaultConfirmDwell` doc comment states the measured switch gaps (the two field gaps above and the test call's maximum) beside DET8's 11.4 s, replacing "still to be measured".
- A `PromotionEngineTests` case replays the 2026-11-12 shape (process-audio `.ended` lead, ax-leave `invalid` 1 s later, window gone, window `.live` at +22.0 s, process audio `.live` at +23.1 s) and asserts no `.ended`.
- `cd daemon && swift test` green, with the new test count in the commit body.

## Owner walkthrough (amendment)

1. [session] Confirm the installed build contains DET23's sampler.
2. [owner] In one Teams test call, switch the input device five times from Teams' own picker and connect one Bluetooth headset once. Cost: one short call, no recording kept.
3. [session] Read the `mic_gap` rows for that call (gap lengths and timestamps only) and write the maximum into this file and beside `defaultConfirmDwell`.
