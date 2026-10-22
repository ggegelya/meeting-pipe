# END15: switching the microphone inside a Teams call ends the recording, because Teams' brief input release corroborates a flickering Leave button

Band origin: filed 2026-10-22 from the owner reporting that changing the microphone in Teams mid-call stops the recording. Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

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
