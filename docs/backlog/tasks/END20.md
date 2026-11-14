---
id: END20
title: An idle-origin start can lose the first-reading race and commit onto an already-ended engine, and ends or stops during bring-up are dropped because a start in flight is a private Bool, not a state
category: Detection
status: new
priority: P1
comment: Filed 2026-11-13 (audit band 2026-11-13). Broken promise, a recording ends when the meeting does: on 2026-11-12 the resumed 20261112-174606 committed onto an engine a first-reading window-gone had already ended, the mic release at 15:50:34Z raised nothing and it ran 380 s until a hand stop (REC7's latch covers only prompt-origin starts); the owner may re-band. Make an in-flight start one latch for every origin, guard didChooseAlways and the alreadyRecording catch, re-engage a terminal engine, and settle the first-reading rule.
---

# END20: An idle-origin start can lose the first-reading race and commit onto an already-ended engine, and ends or stops during bring-up are dropped because a start in flight is a private Bool, not a state

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Source findings: F030, F044 and F045 in the [independent audit](../../audits/2026-11-12-independent-audit.md); D032, D046, D096, D100, D108, D075 and plan patch B in the [recording reliability audit](../../audits/2026-11-13-recording-reliability-audit.md) (evidence in [recording-reliability-evidence.md](../../audits/2026-11-13-recording-reliability-evidence.md)); the field findings "Era 3: a resumed recording ran with its lifecycle engine already ended", "Newest build: the resume after an end recorded on with no prompt and no end detection" and "F030 in the field: a first reading ended the session and flashed the prompt 322 times" in [field-evidence.md](../../audits/2026-11-13-field-evidence.md). Re-verified against HEAD `3a2da4fc` on 2026-11-13 by code reading.

**REC7's fix does not hold for idle-origin starts.** REC7 (done 2026-07-12, archived in [q6-final.md](../q6-final.md)) claimed that "a confirmed lifecycle `.ended` that lands during the async `recorder.start()` window is latched". The latch is `if recordingStartInFlight { endObservedDuringStart = reason; return }`, and it sits only under `case .prompting, .suppressed:` in `MeetingSessionController.handleMeetingEnded`. Starts from `.idle` (END17's resume, auto-consent, the hotkey, start-late) leave the state machine `.idle` for the whole bring-up, so an end there falls to `default: break` and is dropped without a row. `forceStop` is a no-op in `.idle`, and from `.prompting` it abandons the prompt while the start `Task` still commits `setRecording`.

**The incident, 2026-11-12, stem 20261112-174606 (work-laptop build era C).** 20261112-172307 ended at 15:45:27.963Z after a 60 s pair dwell. At 15:46:06Z, inside the resume window: `ax_leave_button_state` initial healthy .597, `lifecycle starting` .598, `recording_resumed_after_end` .606 (`since_end_sec` 38.6), `shareable_content_window_present` initial false .614, `lifecycle ended` .614 (leading `shareable_content_window_gone`, `confirmed_by` empty), `process_audio_is_running_input` initial true .616, `state_change` idle to recording .677, `recording_started` .743, `lifecycle_engage_skipped` `already_engaged` .813. At 15:50:34.737Z process audio read false and at .823Z the Leave button went invalid; no `ending_provisional`, `ended` or `in_meeting` row followed. The owner stopped it at 15:56:54.489Z, 380 s later, with a 382 s silent tail. 1 of 6 era C recordings, 1 of 1 resumes.

**The causal chain.**

1. *The race.* `ShareableContentSignal` forwards its first reading as a change (`if state.lastValue != present` with `lastValue` nil), and so does `ProcessAudioSignal` (`if lastValue == value { return .steady }`). Since CONC9 and PERF15 (both done, 2026-10-26) `ProcessAudioSignal.start` is `run { self.begin(...) }` on its own queue and the window's initial evaluate is `initialQueue.async`, so `NativeLifecycleAdapter.start` no longer fixes their order. In era C the mic's first reading led the window's by 4, 4, 7 and 11 ms and trailed it by 2 ms once; era B (synchronous starts) had the mic first in 58 of 58.
2. *The veto has nothing to veto with.* `PromotionEngine.handleStarting` ends `.starting` directly on a lead with `requiresCorroboration == false` unless `veto(for:in:)` finds a live process-audio reading already in `states`. When the window lands first, it ends with `confirmed_by` [].
3. *The end is dropped.* The resume branch of `handleMeetingStarted` calls `beginRecording` straight from `.idle`, as does the auto-consent branch; `handleMeetingEnded` drops the end as above.
4. *The engine is terminal and stays attached.* `PromotionEngine.ingest` returns nil in `.ended` and `confirmRecording` guards on `.starting`, so no `in_meeting` is ever published. `MeetingLifecycleCoordinator.isEngaged` is `activeAdapter != nil`, so `engageLifecycleIfNeeded` logs `already_engaged` and keeps the dead engine.
5. *The backstop's stand-down is off too.* `handleIdleAutoStop` passes `lifecycleCoord.current.isLive`, false for `.ended`, so the silence backstop can stop such a recording during a quiet stretch of a live call (D100).

**The oldest build shows the same edge at scale.** In era A (to 2026-10-12) 307 of 336 `lifecycle ended` rows fired within 1 s of `starting` from an initial reading, and 322 of 357 prompts were withdrawn without a choice, 285 in under 0.1 s, 222 on 2026-10-08 alone (daemon health and cross-check). END14's veto stopped that loop in era B (136 `end_vetoed`), and CONC9 then reopened the ordering it depends on.

**The UI desync (F044).** `Coordinator.notifier(_:didChooseAlways:)` is the only prompt outcome with no `guard case .prompting(let pending) = stateMachine.current, pending == source`. If it fires while a recording is live (a `.starting` queued behind an idle-origin start can raise a prompt that survives the commit), `audioRecorder.start` throws `alreadyRecording`, and `beginRecording`'s catch unconditionally runs `stateMachine.setIdle()` and `statusUI.setIdle()` while the recorder keeps running. Every stop path keys on `.recording`, so none works until Quit. Code-derived; not seen in the field.

**D075 (low, verified).** The lifecycle consumer in `startConsumers` awaits `MeetingSessionController.resolveAppSource(from:)` for every `.starting` before it looks at anything else, and that title read runs on `axWalkQueue`, the queue that also carries the per-recording mute walk, both AX builds and `rescueProvisionalEnd`'s walk, each AX call bounded only by the 2 s system-wide messaging timeout set in `App.swift`. Meanwhile no later verdict is read, and an explicit start sits in `.starting`, where a reliable end is immediate, until `confirmLateStartIfRecording` runs, which does not need the title.

## Scope

**Controller half (agreed across the slices).**

1. **One start latch for every origin.** Replace the private `recordingStartInFlight` plus `endObservedDuringStart` pair with one latch (or a real in-flight start state in `DetectionStateMachine`; do not name it `.starting`, since the lifecycle verdict already uses that word, and coordinate with UX106, which adds a user-visible Starting state and should build on whichever lands first). `handleMeetingEnded` latches an end for every origin, `forceStop` and `toggleManual` set a cancel on it, and `beginRecording` checks it on the same MainActor run, immediately before `setRecording`; a cancelled start stops the fresh recording through the normal path and logs `recording_ended_during_start` (existing) or `recording_cancelled_during_start` (new, `coordinator`, `origin`).
2. **Guard `didChooseAlways`** like its siblings, and in `beginRecording`'s catch do not go idle on `RecorderError.alreadyRecording`. Dismiss any prompt when a start commits.
3. **Never keep a terminal engine.** When a sourced recording commits and the engine for that source is `.ended` (or `engageLifecycleIfNeeded` finds one), disengage and engage again, logging `lifecycle_reengaged_terminal` (`coordinator`, `bundle_id`). Add a row when a recording runs with its engine in `.ended` for any other reason, and a fence (`lifecycle_recording_on_terminal_engine`) the dogfood report can count.
4. **D075.** In the lifecycle consumer, run `confirmLateStartIfRecording` before `resolveAppSource`, give the title read a deadline, and fill the title into the prompt when it arrives.

**Engine half (conflicting proposals, settle at pickup).**

- *(a) Main and field:* in `PromotionEngine`, ignore `.ended` from a signal that has not read `.live` in this engagement (the browser adapter's `hasMatchedMeetingTitle` gate, generalised). Removes the race outright.
- *(b) Plan patch B:* in `NativeLifecycleAdapter.start`, when the config uses process audio, deliver process audio's first evaluation (true, false or unresolved) before forwarding any window or Leave event, bounded at 2 s, and never drop a first window-gone. Patch B's objection to (a): a mic release cannot lead an end in `.starting`, it only lifts the veto on a held window-gone, so dropping the first window-gone would leave nothing to withdraw the prompt when the owner hangs up before answering, and with Record as the timeout action that prompt would then record a dead call.

The pickup picks one (or (a) with an explicit prompt-withdrawal path that answers (b)'s objection), records why in this file, and pins the hang-up-before-answering case either way.

## Explicitly not

- Repairing the Teams end-side title matcher (D095, `MeetingTitlePatterns.teams` against `MeetingSourceScanner.isActiveMeetingWindow`): the first reading should not decide an end whatever the matcher says; the matcher is its own filing.
- Which workflow a resume records under: SEC39. A hand start's adoption of the engaged meeting: DET26.
- The 60 s Teams dwell and the teardown line confirming nothing in era C (D109): [END17](./END17.md)'s amendment.
- The source-less foreign end of 2026-11-11: END19.
- [ARCH7](./ARCH7.md)'s per-meeting state object; item 1 should fit it but does not wait for it.

## Acceptance

- A detection corpus trace of the 2026-11-12T15:46:06Z order (Leave initial healthy, window initial false 2 ms before process audio initial true) that must not end: under (a) no `.ended`, under (b) `end_vetoed`. T17's truth-label work owns the corpus format if it lands first.
- The hang-up-before-answering case still withdraws the prompt: a `.starting` with a window-gone held under a live mic, then the mic release, yields `.ended` before any answer.
- `MeetingSessionController` tests: a resume start and an auto-consent start each receive a lifecycle `.ended` during `audioRecorder.start`; each ends with the fresh recording stopped and `recording_ended_during_start`. A hotkey start that gets `forceStop` mid-start never reaches `.recording`. A start from `.prompting` that gets `forceStop` mid-start does not commit.
- `didChooseAlways` while `.recording` starts nothing; `alreadyRecording` in the catch leaves the state machine `.recording`.
- A sourced recording committing onto an `.ended` engine is re-engaged and logs `lifecycle_reengaged_terminal`; a later process-audio release then opens a hold.
- D075: a `.starting` for the app being recorded is confirmed before a stalled title read returns (injected resolver that never returns).
- New `coordinator` actions documented in `CONVENTIONS.md`; `python3 scripts/truth_fences.py events` green.
- `cd daemon && swift test` green with N new tests named in the commit body; `bash scripts/ci-local.sh` green.

## Owner walkthrough

1. [session] Confirm the installed build is newer than the landing commit.
2. [owner] For one working week: when a Teams call drops and the recording resumes on its own, leave it alone. Pass: it stops by itself within a minute of the call ending.
3. [session] Grep that week's `events.jsonl` for `lifecycle ended` within 1 s of `starting` with empty `confirmed_by` (target 0), `lifecycle_reengaged_terminal` and `lifecycle_recording_on_terminal_engine`, and report each with its stem.
