# END13: the hold's 150 s cap confirms an end that a live signal is actively contradicting, and the fast restart it provokes attaches to nothing

Band origin: filed 2026-09-04 after the owner checked their last meeting and found the recording had stopped itself mid-call. Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## What is wrong

[END12](./END12.md) shipped 2026-09-02 and works: since its build installed at 17:16 that day there have been 7 holds and zero `log_stale` confirms, against 11 in the 12 days before. The hold now opens where it should. What it exposed is the next layer: **the hold's ceiling is a wall clock and nothing else, so it fires against a call that every other oracle still says is up.**

`CallTeardownOracle.decide` ends with `guard elapsed < input.holdCapSec else { return .confirm(reason: .holdCapReached) }`. The cap takes no account of any signal but the teardown line. `defaultHoldCapSec` is 150, sized by END9 against "the largest in-coverage accessibility blackout (33.2 s measured two-sided on 2026-08-03) with room for the 65 s tail", which assumes the Leave button comes back. When the owner works in other windows for minutes at a stretch it does not come back, and 150 s is simply the delay before the same chop END9 was built to stop.

Two things make the cap the wrong instrument here rather than merely a short one.

**A live cross-class signal was affirmatively saying the call was up, and nothing consulted it.** `ProcessAudioSignal` reports `kAudioProcessPropertyIsRunningInput` OR-ed across Teams' audio objects, and its own doc comment calls it the control: "a signal that never fires without a real teardown". It is the leading signal on 5 of the 7 holds since END12 and led every real end on 2026-09-03. During the 2026-09-04 hold it never reported an end at all. It is also a different `evidenceClass` (`.processAudio`) from the ax-leave lead (`.callWindowOrControl`), which is exactly the independence `PromotionEngine.tick` demands before it will promote. The engine will not promote this end on that basis; the cap promotes it anyway, over the top of the guard.

**The oracle degrades toward confirming, and that direction was chosen when the only alternative was an unbounded hold.** `Reason.holdCapReached`'s doc comment says "Deliberately still an end: a hold that could run forever would be a worse bug than the one being fixed", and that reasoning is sound as far as it goes. It is a statement about having no other evidence. Here there is other evidence, and it is the best-behaved signal in the set.

## Observed, not theorized

The installed binary at `~/Applications/MeetingPipe.app` has an mtime of 2026-09-02 17:16, after END12 landed at 17:09, and the daemon process has run since 17:16:44 that day. Everything below is END12's code in the field.

**Since END12 installed (2026-09-02 17:16 to 2026-09-04 14:15 local): 9 recordings, 8 provisional ends, 7 holds, 1 released, 1 confirmed.**

| Hold opened (local) | Leading signal | Outcome |
|---|---|---|
| 09-02 19:35:30 | process_audio_is_running_input_false | real end, stopped |
| 09-02 20:35:40 | ax_leave_button_invalid | released after 5.4 s, call came back |
| 09-02 20:44:14 | process_audio_is_running_input_false | real end, stopped |
| 09-03 11:45:27 | process_audio_is_running_input_false | real end, stopped |
| 09-03 13:47:00 | process_audio_is_running_input_false | real end, stopped |
| 09-03 17:18:41 | process_audio_is_running_input_false | real end, stopped |
| 09-04 14:05:10 | ax_leave_button_invalid | **confirmed `hold_cap_reached` at 160.8 s, live call cut** |

The two ax-leave-led holds are the false-end class END9 exists for. One resolved the way the design intends. The other is this task.

**The incident, 2026-09-04, local time.** `20260904-133358.wav` started at 13:33:58.988 and the owner was in the call throughout.

```
14:05:10.510  signal/ax_leave_button_state       {"previous":"healthy","reason":"health_poll","state":"invalid"}
14:05:10.514  lifecycle/ending_provisional       {"leading_signal":"ax_leave_button_invalid"}
14:05:10.850  coordinator/lifecycle_end_held     {"hold_cap_sec":150,"log_written_sec_ago":3149.5}
14:05:16.995  micgate/mute_state_polled          {"buttons_found":1,"fused":"unmuted","poll_count":1500,"states":["unmuted"]}
14:07:51.648  coordinator/lifecycle_provisional_end_confirmed  {"held_sec":160.8,"oracle":"hold_cap_reached","trimmed":true}
14:07:51.653  lifecycle/ended                    {"confirmed_by":["ax_leave_rewalk"],"leading_signal":"ax_leave_button_invalid"}
14:07:51.849  recorder/held_end_trimmed          {"file":"20260904-133358.wav","limit_sec":1871.9}
14:07:55.217  coordinator/recording_stopped      {"file":"20260904-133358.wav","produced_final":true}
14:07:59.429  coordinator/recording_started      {"bundle_id":"manual","file":"20260904-140759.wav"}
```

Four independent readings say the call was live for every second of that hold.

- **Process audio.** The signal emits only on change (`previous` / `reason` attributes). Its last emission for this meeting is `{"previous":false,"reason":"poll","value":true}` at 13:33:52.148, six seconds before the recording started. It emits nothing again for the rest of the meeting, so its value was `true` continuously, including throughout the hold. `signal/process_audio_object_resolved` rows at 14:02:25 (`object_count: 5`) confirm the resolver was alive minutes into it.
- **The Mute button, in the same accessibility tree.** `micgate/mute_state_polled` at 14:05:16, six seconds into the hold, reports `buttons_found: 1` and `poll_count: 1500`, and `micgate/ax_mute_button_state_kept` then repeats once a second for the rest of the hold. The mute poller resolved a live Teams AX button throughout.
- **Teams' own log.** The generation carries a `SetWindowContentProtection 406` at 12:16:02 (a call registering) and its matching `UnregisterCall 406` at 12:43:02, then `UnregisterCall 417` at 12:52:07. There is no line of either kind for the 13:33 call: it had not been flushed yet, which is END12's finding, and no teardown for this call exists on disk to this day.
- **The owner.** They pressed Record again 4.2 s after the stop and the replacement recording ran another 40 minutes, to 14:48:07.

**The tree went blank and then came back without a Leave button, which is the shape that matters.** The 2026-08-03 investigation established that a false end is an in-process Electron accessibility-tree teardown rather than a window collapse, and this instance opens exactly that way: the Leave button went invalid at 14:05:10.510 and the mute poller lost its own button in the same seconds, logging `micgate/mute_state_cleared_blind` at 14:05:14 with `{"blind_polls": 3, "poll_count": 1499}`. So both controls went at once, as END9 measured.

What follows is the part the cap cannot survive. The tree came back and the two signals did not come back together. `micgate/mute_state_polled` re-resolved at 14:05:16 with `buttons_found: 1` and `previous: null`, and `micgate/ax_mute_button_rearmed` fired at 14:05:19, six and nine seconds in. `signal/ax_leave_button_rearmed` never fired at all, for the remaining 155 s. On the 2026-09-02 hold that released, it fired 5.4 s in and the recording was saved by it.

Two readings, and the log alone cannot separate them: either the rebuilt tree genuinely had no Leave control while it had a Mute control, or `AXLeaveButtonSignal`'s re-arm is weaker than `MeetingAXWindowWatcher`'s and missed a button that was there. **The first is the better supported**, because Teams splits Mute (Meeting controls) and Leave (Calling controls) into separate accessibility containers and the Leave container is absent from the compact call view, measured while building the mute fusion. A Leave-only absence is therefore an expected rendering state rather than an anomaly, and it can last as long as the owner leaves the call window alone. That is precisely why a wall clock is the wrong instrument: the cap is timing a rendering state, and 150 s is a guess about how long the owner will look at something else.

Distinguishing the two readings needs an instrumented run rather than a log read, and item 3's distinct cap reason is what would tell them apart in the field afterwards. It does not gate this task: under either reading the cap fired on a live call over the top of a signal that said so.

**The cost.** The hold's audio is trimmed on confirm by design, so `20260904-133358.wav` is exactly 1871.9 s, cut at the moment the hold opened. From 14:05:10 to the replacement's first sample at 14:07:59 there are **2 minutes 49 seconds of meeting with no recording at all**, and the meeting is split into two library rows with two summaries.

## The second half: the fast restart attaches to nothing

The replacement recording carries `bundle_id: "manual"`, not `com.microsoft.teams2`, so per [END11](./END11.md)'s item 2 it engages no lifecycle, has no AX end anchor, and is hand-stopped by design. A false end therefore costs the meeting twice: the chop, and then a replacement that cannot end itself.

`MeetingSessionController.startManual` attaches when `coordinator.stateMachine.liveSuppressedCandidate()` returns a sighting and otherwise falls to `beginRecording(source: nil)`. That slot is written only by `DetectionStateMachine.noteSuppressedCandidate`, called from the two suppression branches of `handleDiscovery`, and the cooldown branch it needs here cannot run until the *next discovery poll after the stop*, because the cooldown is armed by the stop itself. Discovery polls every 3 to 12 s, so there is a window after every stop in which a manual Record finds nothing.

Measured over every manual or attached start within 120 s of a stop since 2026-08-22, by the gap between the stop and the first `cooldown_candidate_retained`:

| Stop (local) | Restart after | First retention after | Attached? |
|---|---|---|---|
| 09-01 11:08:40 | 6.0 s | 1.4 s | yes |
| 09-01 16:30:47 | 35.6 s | 3.3 s | yes |
| 09-02 12:36:25 | 4.0 s | 1.1 s | yes |
| 09-04 14:07:55 | 4.2 s | never | **no** |

The retention landed 1.1 s to 14.1 s after a stop across the corpus. On 2026-09-04 the owner beat it. This is a race, not a policy: `DetectionStateMachine.noteMeetingEnded`'s doc comment already argues the case, that a false end's candidate is rewritten because "a false end is re-sighted within one poll", and cites 2026-08-19 where the repopulation took 5 s and the owner restarted at 7 s. The argument is right and its window is one poll wide.

## Scope

The smallest change that fixes the class. Two seams, filed together because they are one incident and the second is what makes the first expensive.

1. **A live cross-class signal vetoes the cap.** `CallTeardownOracle.decide` gains an input for whether an independent signal affirmatively says the call is still up, and the `holdCapSec` branch does not confirm while it does. Keep the type pure: the host collects the reading and forwards it, matching how `recordingStartedAt` and the teardown itself arrive. Everything before the cap is unchanged, so a teardown still confirms on the first consult with no added latency.
2. **The veto must be tri-state, never a bool.** Running, not running, and *unknown* are three different answers and only the first may veto. `ProcessAudioSignal` resolved 0 times in 19.8 days of dogfood before DET8 fixed it, its resolver still returns `.unresolved(OSStatus)`, and the signal "holds prior state on nil to avoid flapping". A machine where the probe never resolves must get today's cap, not an unbounded hold. This is the item most likely to be got wrong and it is the one that decides whether this task is safe.
3. **Keep an absolute ceiling above the veto.** A vetoed hold still ends, at a bound chosen for the failure it prevents: Teams holding the mic open after a call would otherwise record until the owner notices. Say what the number is in the commit and why, and log a distinct reason for it so the field can tell "capped with no evidence" (`hold_cap_reached`, today's) from "capped while a signal still claimed the call was live", which is the drift detector for this change the way `hold_cap_reached` is for END9's.
4. **Do not let the drift warning cry wolf.** `MeetingSessionController.consultTeardownOracle` writes "WARN: a provisional end held the full 150s without Teams ever logging a call teardown - if this repeats, the teardown line has moved and the oracle needs re-measuring" on every cap. On 2026-09-04 that fired on a live call whose teardown line was fine and merely unflushed, which is the opposite of what it claims. Gate it on the no-evidence case only.
5. **Give a manual start the source of the recording that just stopped.** Write the just-stopped source into the suppressed-candidate slot at `stopRecording` with `.cooldown` origin, so `liveSuppressedCandidate()` is populated from the instant of the stop rather than from the next poll. The bundle is already in hand at that seam (`stopRecording` arms `recordCooldownEnd(bundleID:)` there), the existing self-expiring read gives it the same grace and the same staleness protection as a poll-written one, and it needs no AX work on the gesture path. An on-demand discovery scan at `startManual` is the alternative and is rejected: it puts an AX walk on a user gesture, which is the freeze class the repo has fixed twice.

## Explicitly not in scope

**Not shortening or lengthening `defaultHoldCapSec` as the fix.** A longer cap moves the chop later and a shorter one moves it earlier; neither reads the evidence that was available. Item 3 may still restate the number, with its reasoning.

**Not `requiresCorroboration` or `confirmProvisionalEnd`'s bypass of it.** Verified deliberate on 2026-08-21 and re-confirmed here: `PromotionEngine.tick` refuses a lone ax-leave lead forever, so the bypass is the only route by which any native Teams end promotes. This task changes when the host calls it, never the primitive.

**Not making process audio a promoting signal.** It stays `requiresCorroboration == true`, and its own doc comment says "Do not turn it off". Using it to *refuse* an end is the opposite direction and strictly safer than using it to declare one; do not let the fix drift into the latter.

**Not the re-prompt cooldown, and not DET14's `noteMeetingEnded` clear.** Both were re-examined for this filing and neither is the operative cause: the candidate slot was empty for the whole recording, so there was nothing for DET14 to clear, and the cooldown suppressing the prompt is load-bearing against re-prompt storms (DET13).

**Not END11's source-less bound.** That a `bundle_id: "manual"` recording has no end detection is END11's settled decision, with a duration ceiling considered and rejected there. Item 5 stops the owner landing in that case by accident; it does not reopen what that case does.

**Not the accessibility trigger itself, and not the re-arm asymmetry.** Why the rebuilt tree carried a Mute button and no Leave button for 155 s is upstream of this task and unresolved between the two readings above. It is worth a row of its own if it recurs, and the discriminating evidence is an instrumented walk during the state rather than anything in `events.jsonl`. This task must work under either reading, which is why the veto is built on process audio rather than on a better Leave re-walk.

**Observed, unfiled, named so they are not lost:**

- `IdleStopBackstop` has fired **zero** times in the whole event log across every generation. It is the only bound END11 gives a source-less recording, and it has never once demonstrated that it works. Belongs under REC or END as its own row.
- `coordinator/call_teardown_source_missing` fired twice inside the 161 s hold (`NSCocoaErrorDomain 256: The file "Logs" couldn't be opened`), against a directory a fresh process lists in 13 ms. Still never three in a row, so it still costs nothing, and still unexplained. Named in END12 too.

## Acceptance

- `CallTeardownOracle.decide` returns `.hold` at and beyond `holdCapSec` while the live-signal input affirmatively says the call is up, and returns `.confirm(reason: .holdCapReached)` at the cap when that input is unknown or says the call is down. Both pinned, and the first measured red against `main` before the change.
- A test proves an unknown or unresolved reading does not veto, written from the DET8 shape (`.unresolved(OSStatus)`), so a machine whose probe never resolves keeps today's bound.
- A test proves the absolute ceiling of item 3 terminates a vetoed hold, and that it logs a reason distinct from `hold_cap_reached`.
- A host test replays 2026-09-04 14:05: an ax-leave-led provisional, no teardown on disk, process audio still running, and asserts the recording is still running past 150 s and that the drift WARN was not written.
- A test proves a manual start immediately after a stop attaches to the just-stopped source with no discovery poll in between, and that the same start attaches to nothing once the candidate's grace has lapsed.
- `swift build` and `swift build -c release` clean with no new warnings; `swift test` green with the tests this task adds; `python3 scripts/truth_fences.py both` green.
- If the HUD's Confirming end copy or timing changes, `README.md` and [`docs/GUIDE.md`](../../GUIDE.md) are updated in the same commit, per the guide's same-commit contract.

## Owner walkthrough

1. **[session] After the fix lands, check the installed binary's mtime is later than the landing** before asking for anything below.
2. **[owner] Join a Teams call, accept the prompt, then work in other windows for four or five minutes without going back to the call.** Pass: the recording is still running when you return. Fail: it stopped, and the menu offers Record again. This is the exact 2026-09-04 shape, and the previous bar (two minutes) did not reach the cap.
3. **[owner] Leave the call.** Pass: the recording stops within a few seconds. The teardown fast path must not have slowed down.
4. **[session] Grep that day's `events.jsonl`** for `lifecycle_provisional_end_confirmed` and confirm no row carries `hold_cap_reached` while the meeting was live, and that any hold on a live call released rather than confirming.
