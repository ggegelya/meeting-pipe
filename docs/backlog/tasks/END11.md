# END11: an attached or manual recording has no end detection, because armLifecycleLeaveButton arms an adapter that was never engaged

Band origin: filed 2026-08-21 after the owner reported that "after starting manually connected to Teams it is not dropping when the meeting obviously ended". Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## What is wrong

A recording started by hand never stops by itself, whether or not it is attached to a detected meeting. The Leave-button element is resolved and handed over correctly; there is simply nothing on the other side to receive it.

`MeetingLifecycleCoordinator.armLeaveButton(_:)` is one line, `activeAdapter?.armLeaveButton(element)`, and its own doc comment already says it is a no-op when no adapter is live. `activeAdapter` is set only by `MeetingLifecycleCoordinator.engage(context:handle:)`. The only caller of `engage` is `MeetingSessionController.engageLifecycle(for:)`, and the only caller of *that* is `handleDiscovery`, whose skip-latch branch and `isCoolingDown` branch both `return` before reaching it.

So the chain for an explicit start is: `toggleManual` or the hotkey or `meetingpipe://record` reaches `startManual`, which either calls `recordAttached` (when `liveSuppressedCandidate()` returns a sighting) or falls to `beginRecording(source: nil)`. Either way `beginRecording` calls `armLifecycleLeaveButton(source:)`, which walks the AX tree off-main, finds the Leave button, and passes it to `lifecycleCoord.armLeaveButton(_:)`, where `activeAdapter` is nil and the element is dropped on the floor. No adapter means no `lifecycle`/`in_meeting`, no Leave-button signal, no provisional end, and no end at all.

## The gap DET13 believed it had closed

[DET13](./DET13.md)'s change 1 shipped 2026-08-18 and its ToC row records the outcome as "a manual Record inside the 60 s window now produces an attached recording: workflow rules see the app, the sidecar carries its identity, and `armLifecycleLeaveButton` has something to arm on".

The first two clauses are true and were verified in the field on 2026-08-21. The third is not. DET13 made the *element* reachable by retaining the cooldown-suppressed sighting, so `armLifecycleLeaveButton` now has a `source` and finds a button. It did not make the *adapter* reachable, because the branch that retains the candidate is the same branch that returns before `engageLifecycle`. DET13's own change-2 finding names that fact in passing, describing `MeetingTitleResolver` as running "behind the `engageLifecycle` this branch returns before", so the constraint was known at that seam and its consequence for change 1 was not carried across.

This is not a regression in DET13 and it is not a reopen: DET13 fixed source attribution, which it did, and this is the neighbouring half that was assumed to follow from it.

## Observed, not theorized

**The attached path, 2026-08-21.** At 13:38:00.126 `coordinator`/`record_attached` fired with `trigger: "manual"` and `bundle_id: "com.microsoft.teams2"`, so DET13's retention worked. The rows that follow are `input_device_resolved`, `idle_sleep_assertion_held`, `state_change` to `recording`, `recording_started`, `ax_handles_built` (with `found_leave: true`), and `mute_poller_started`. There is no `lifecycle`/`in_meeting`, no `signal`/`ax_leave_button_self_armed` and no `signal`/`ax_leave_button_state` at any point in that recording. It ran 18 m 30 s and ended at 13:56:29 with a bare `state_change` from `recording` to `stopping` carrying no preceding `lifecycle`/`ended`, which is the owner stopping it by hand.

**The healthy auto path, ninety seconds earlier, for contrast.** At 13:36:17.918 `recording_started` is followed within 900 ms by `ax_handles_built`, `mute_poller_started`, `lifecycle`/`in_meeting`, `ax_leave_button_self_armed` and `ax_leave_button_state` with `state: "healthy"`. Those last three are exactly what the attached path never emits.

**The pure manual path is worse, and the cost is measurable.** `20260814-163455.wav` and `20260817-164312.wav` both carry `bundle_id: "manual"` and neither has a `recording_stopped` row anywhere in the log. `20260817-164312` started at 16:43:13, held `recorder`/`idle_sleep_assertion_held`, and ran for **72 minutes**, through `system_capture_lost` at 17:45:14, a full system sleep, and a `did_wake_while_recording` plus `system_capture_resumed` with `gap_sec: 106.8` at 17:54:31, before the state finally left `.recording` at 17:55:18. It was started 11 seconds after a false end chopped `20260817-163107.wav`, which is the loop in one pair of stems: the chop pushes the owner onto the manual path, and the manual path cannot end.

Across the 2026-07-13 to 2026-08-21 window `recorder`/`idle_sleep_assertion_held` appears 111 times against 110 `idle_sleep_assertion_released`.

## Scope

The smallest change that fixes the class, in `MeetingSessionController`.

1. **Engage the lifecycle on an explicit start that has a source.** `recordAttached` should reach `engageLifecycle(for: source)` before `beginRecording`, or `beginRecording` should engage when it holds a source and no adapter is live. Prefer the second if both entry points can reach it, so `didRequestStartLate`, the hotkey, the menu row and the URL verb cannot drift apart; DET7 lifted this sequence into one place for exactly that reason and the fix should stay there. Engaging must be idempotent against an adapter discovery already engaged.
2. **Decide what a source-less recording gets.** `beginRecording(source: nil)` has no pid and no AX anchor by construction, so no Leave button exists to arm. Today it also has no bound of any kind. Either give it one (a duration ceiling, or the existing silence backstop made reachable) or state in the spec that a generic recording is hand-stopped by design and make the HUD say so. Do not leave it undefined.
3. **Do not leak the sleep assertion.** `idle_sleep_assertion_held` must have a matching release on every terminal path, including the ones an unstopped recording reaches.
4. **Guard `handleMeetingEnded` on identity.** Its `.recording` branch calls `stopRecording` without comparing the ended `bundleID` to the recording's own `src`, so a stale adapter for a different app can stop the wrong recording. Low likelihood while only one adapter is engaged at a time, and cheap to close while the surrounding code is open.

## Explicitly not in scope

**Not changing what a lifecycle end does to a live recording.** `handleMeetingEnded`'s `.recording` branch honours every end including uncorroborated ones, and its comment records why: a missed real end runs forever, which is worse than a rare late stop. That reasoning is sound and is the opposite failure to this task's. Item 4 above changes *which* recording an end applies to, never *whether* an end is honoured.

**Not stopping the re-prompt cooldown from arming on a false end.** This was investigated on 2026-08-21 and deliberately left out. `stopRecording` arms `recordCooldownEnd(bundleID:)` on every end, so a chop locks the bundle out of an automatic re-prompt for `repromptCooldownSec`, and that is what pushes the owner onto the manual path in the first place. It is still not the right fix here, for two reasons: DET13's shipped comment records that the cooldown suppressing the prompt is "load-bearing against END9's false-end re-prompt storms", so removing it re-opens a worse failure; and END10 removes the false ends that create the situation. Reopen this only if false ends survive END10, and measure the storm before changing the constant. DET13 also explicitly ruled out shortening the cooldown.

**Not the cooldown lockout's visibility.** DET13 already ships `coordinator`/`cooldown_candidate_retained` once per retention, which is the record that a live candidate is being held back. Checked 2026-08-21; nothing is owed here.

**Not the idle backstop's design.** `IdleStopBackstop` exists and, per the dogfood record, has fired zero times. Whether it is the right bound for item 2 is a question for the pickup session, but reworking its VAD input is its own task.

## Acceptance

- A test proves that a recording started through `recordAttached` engages the lifecycle and that a subsequent Leave-button invalidation reaches the promotion engine. This must be red against `main`.
- A test proves `armLeaveButton` is not called against a nil `activeAdapter` on any explicit-start path, or that doing so is loud rather than silent.
- A test pins whichever bound item 2 chooses for a source-less recording.
- A test proves `handleMeetingEnded` for bundle A does not stop a recording whose source is bundle B.
- `swift build` and `swift build -c release` clean with no new warnings; `swift test` green; `python3 scripts/truth_fences.py both` green.
- If the fix changes user-visible behaviour on the menu row or the HUD, `README.md` and [`docs/GUIDE.md`](../../GUIDE.md) are updated in the same commit, per the guide's same-commit contract in the root `CLAUDE.md`.
- Field bar, checkable by the owner: after starting a recording by hand on a live Teams call, `events.jsonl` carries `lifecycle`/`in_meeting` and `signal`/`ax_leave_button_state` for that recording, and the recording stops on its own when the call ends.

## Owner walkthrough

1. **[owner] After the fix installs, join a Teams call and start the recording by hand** rather than accepting the prompt, then leave the call and do not touch the app. Pass: the recording stops on its own within roughly a minute. This confirms afterwards; it does not gate building.
2. **[owner] Repeat with a recording started from `.idle` with no meeting running at all**, which is the source-less path, and confirm the behaviour matches whatever item 2 chose.
