---
id: END17
title: End-of-call detection stops the recording on the first end it believes, so every new third-party UI shape chops a live meeting; invert it to record long and trim later
category: Detection
status: partial
priority: P1
comment: Shipped 2026-10-24 on the owner's four decisions (inversion accepted, lone_dwell 12 min, keep-and-suggest-trim, END15 folded in; T8 to follow, synthetic traces meanwhile): definitive/weak tiers in PromotionEngine with a 60 s pair dwell and 12 min lone dwell, the hold keeps recording on every weak end, CallTeardownOracle is teardown-or-nothing, `held_end_trim_sec` with the Audio tab's Restore, `resumed_from` with a header Merge, no 120 s browser floor, `debounce_end_sec` retired, ADR 0017. Remaining: re-verify against T8's raw incident traces once they exist, the owner's END15 mic-switch measurement for `defaultConfirmDwell`, and the field walkthrough. [Spec](./END17.md) Amended 2026-11-13 by the audit band: native adapters emit no app-quit signal (0 of 381 ends carry it), a vanished process-audio object keeps the veto live, and the regulated cut skips single-source recordings.
---

# END17: end-of-call detection stops the recording on the first end it believes, so every new third-party UI shape chops a live meeting; invert it to record long and trim later

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([go-live assessment](../../audits/2026-10-21-go-live-assessment.md) "Fix before anyone else installs it" #2: PD-1, PD-3, PD-9, FQ-6, UX-15; [harness audit](../../audits/2026-10-24-ai-harness-audit.md) #2; [architecture review](../../audits/2026-10-24-architecture-review.md) D4). P1: the broken promise is that a live meeting is recorded whole; the owner may re-band. Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

**The class.** [END9](./END9.md) (2026-08-04), [END10](./END10.md), [END11](./END11.md), [END12](./END12.md), [END13](./END13.md), [END14](./END14.md) and [END15](./END15.md) (2026-10-22) were each filed P1 from a chopped live meeting, and each fix replaced or patched the rule the previous one shipped. END9 to END14 are `partial`, awaiting field confirmation; END15 is `new`. One Teams title change on 2026-10-08 produced 217 `shareable_content_window_gone` ends that day and 89 the next (END14's spec).

**How the policy decides today** (re-read 2026-10-24). `PromotionEngine` moves `.endingProvisional` to `.ended` (a) at once when a corroborator from another `EndEvidenceClass` arrives, in `handleEndingProvisional` and `handleInMeeting`; (b) on the end debounce (`debounce_end_sec = 5`) for a lead with `requiresCorroboration == false`, subject to END14's live veto; (c) through `confirmProvisionalEnd` when the host's hold confirms. The browser tab-title lead has `endDebounceFloor` 120 s. The hold (`MeetingSessionController.beginTeardownHold`) asks `CallTeardownOracle.decide`, which confirms on `teardownObserved`, on `oracleUnavailable`, on the 150 s `defaultHoldCapSec` when no live signal vetoes it, and on the 7200 s `defaultLiveSignalCeilingSec`. A confirmed end stops the recorder, and a held one calls `recorder.stop(limitSeconds:)` at the hold's start (`pendingEndTrimAt`), so audio after the first doubt is discarded at stop, never kept.

**Why the shape is wrong.** Every branch decides in real time, on signals a third-party UI change can fake (an AX tree blackout, a title format, a device switch), and a wrong decision is unrecoverable lost audio. A late decision costs minutes of extra audio that the trim already knows how to remove. The asymmetry runs one way, and the policy is tuned the other.

**Browser Meet (PD-3).** `endDebounceFloor` returns 120 for `.browserTabTitle`, so a presenter sharing another tab, a minimized window, or another Space for more than 120 s ends the recording. The only other browser end is `workspaceAppTerminated`.

**False-end recovery (PD-9).** After any end, `reprompt_cooldown_sec = 60` suppresses prompts for that bundle. [DET13](./DET13.md)'s change 1 keeps the candidate, so a manual Record attaches, but no prompt appears, and when one does it times out after `prompt_timeout_sec = 30` to `default_prompt_action = "skip"`. A user who does not notice within about 90 s loses the rest of the meeting; one who does gets two stems that only a manual `mp merge-meetings` (FEAT9) joins.

## Scope

1. **Two evidence tiers, in Core.** *Definitive*: `workspaceAppTerminated`, a teardown observed for this recording (`CallTeardownOracle.Reason.teardownObserved`), and an explicit user Stop. *Weak*: every other end signal (ax-leave invalid, window gone, window title, browser tab title, process-audio input released). A definitive signal ends as today.
2. **A weak end holds and keeps recording.** It opens the hold with the recorder running and the HUD in its existing confirming state (`hud.setConfirmingEnd(true)`). The hold confirms when weak signals from two evidence classes have *stayed* ended for `confirm_dwell` (pinned from measurement: DET8 measured Teams clearing input within 11.4 s of a real leave, and END15's device-switch gap is measured there), when a lone weak signal has stayed ended for `lone_dwell` (owner decision), or when the idle backstop (`mic_only_silence_seconds = 900`) fires. Any signal returning live inside the hold reverts to in-meeting, generalising END14's `veto(for:in:)` revert. `oracleUnavailable` stops being a confirm and becomes "no evidence".
3. **Keep, then trim.** On a held confirm the recording stops and the start of the held episode is written as a suggested trim (a new sidecar key, so the Swift writer, the Python reader and `test_workflow_overlay.py` change together per the root `CLAUDE.md`). Transcription and summary use the trimmed span; the full audio is kept. Under regulated and NDA workflows the tail is truncated at stop as today: `consultTeardownOracle`'s comment gives the reason, that under those postures [ADR 0016](../../decisions/0016-capture-first-mute-redaction.md) says post-call audio must not exist at rest. The Library detail shows "Trimmed N min after the call ended" with an undo that re-runs the pipeline on the full file.
4. **Browser.** The tab-title lead becomes weak and the 120 s floor goes; a browser meeting ends on a browser quit, the lone dwell, or the idle backstop.
5. **Recovery.** When a confirmed end is followed within a recovery window (proposed 120 s) by the same bundle's call going live again, the reprompt cooldown is bypassed, recording resumes into a new stem carrying `resumed_from: <stem>`, and the Library offers FEAT9's merge for the pair.
6. **An ADR** in `docs/decisions/` recording the inversion and the tier table, so the next incident extends the table instead of adding a rule.

## How this relates to the open END and DET tasks

END17 supersedes the rule-by-rule approach. It closes none of them; each keeps its own walkthrough, and only the owner closes one.

- **END9, END13, END14**: their rules become special cases of the tiers (the empty re-walk, the capped hold and the lone window-gone are all weak ends that now hold). Their tests must stay green.
- **END15**: its dwell is item 2's `confirm_dwell`, and its four scenarios become this task's acceptance. Owner decision 4 below says whether END15 lands first as the narrow fix or is closed by this task.
- **END10, END11, END12**: orthogonal and still required. The watcher must run, a manual start must engage the lifecycle, and the oracle must read the log correctly for `teardownObserved` to mean anything.
- **END16**: orthogonal (the watcher's idle cost and source flapping), but item 2 removes the reason its flapping was dangerous, since an unreadable source no longer confirms.
- **DET13**: item 5 builds on change 1's retained candidate; DET13's closed change 2 is not reopened.
- **T8** lands first: its raw incident traces and Core hold policy are what this task is verified against. **DET15** adds the per-app oracle this tier table consumes.

## Owner decisions (answered 2026-10-24)

1. Accept the inversion: after a real leave that only a weak signal saw, the recording and the HUD run for up to `lone_dwell` before stopping, and the tail is trimmed afterwards. **Accepted.**
2. The `lone_dwell` value. **12 minutes** (`PromotionEngine.defaultLoneDwell = 720`): above a ten-minute tab share, which acceptance needs, and below the 15 minute idle backstop. The local event log on the owner's personal Mac held one ended meeting, so the value was not derived from a corpus; the work laptop's log is where T8's extraction would measure it.
3. Keep-and-suggest for non-regulated workflows (item 3), or truncate everywhere as today. **Keep and suggest.**
4. END15 first as a narrow P1 fix, or folded into this task. **Folded in.**

T8 sequencing (asked at pickup): **END17 first, on synthetic traces** built from the raw rows each END spec quotes; END17 stays `partial` until T8's raw traces replay to `no_end`.

## Shipped 2026-10-24 (partial)

Items 1 to 6 as scoped, with these choices the spec left open. `confirm_dwell` is 60 s, above DET8's 11.4 s and the 22 s inside which the 2026-10-22 incident re-acquired the mic; the device-switch gap END15 asked to measure is still unmeasured. The end debounce (`detection.debounce_end_sec`, its Preferences slider and `config.py`'s copy) had no consumer left and was retired. The revert rule is any signal of the lead's own class, any signal that had itself gone ended, or process audio. The Library's merge offer sits in the detail header ("Picks up where ... stopped." with **Merge**), which restores and re-transcribes the earlier recording's held tail before FEAT9's merge; any merge drops the primary's trim key. The incident traces are engine-only, so END9's empty re-walk and END12's quiet log are pinned on the host side in `CallTeardownHoldTests` instead.

Remaining: replay T8's raw traces for END9, END12 to END15 (and drop the synthetic ones T8 replaces), the owner's mic-switch measurement for `defaultConfirmDwell`, and the walkthrough below.

## Explicitly not / out of scope

- Detecting browser meetings other than Meet (the UX-15 half): [DET6](./DET6.md). Capture losses in FQ-6 belong to [REC17](./REC17.md) and REC14.
- Locale coverage of the weak signals: DET15. Changing the idle backstop's threshold.

## Acceptance

- T8's raw traces for END9, END12, END13, END14 and both END15 orders replay to `no_end`; END15's `known_defect` flag is removed in this commit.
- The 26 existing promotion traces (20 distilled real ones, 6 synthetic) and END14's clean-leave pair still end. A Teams leave with ax-leave, process audio and `UnregisterCall` ends no later than today (the teardown leads the AX edge, p50 about 1.3 s, per `beginTeardownHold`'s comment).
- Tests: a browser tab away for 10 minutes then back gives one recording; a browser quit ends at once; `oracleUnavailable` alone never confirms; a held confirm writes the trim key, the transcript excludes the tail, and the WAV keeps it; a regulated workflow truncates as today; a same-bundle return inside the recovery window resumes with `resumed_from` and no prompt.
- New `coordinator` actions documented in `CONVENTIONS.md`; `python3 scripts/truth_fences.py` clean.
- `bash scripts/ci-local.sh` green, with the new test counts in the commit body.

## Owner walkthrough

1. [session] Confirm the installed build is newer than the landing commit.
2. [owner] For one working week on that build: in a Meet call, share another tab for three minutes; in a Teams call, switch microphones twice; end calls normally; quit the app mid-call once. Pass: one recording per call, each ending within `confirm_dwell` of a normal leave. Cost: no extra calls.
3. [session] Grep that week's `events.jsonl` for confirmed ends without a definitive signal and report each with its dwell.

## Amendment 2026-11-13 (audit band)

Sources: G025, F033, G026 and G028 in the [independent audit](../../audits/2026-11-12-independent-audit.md), and the field count from the [field evidence](../../audits/2026-11-13-field-evidence.md) (sessions-and-lifecycle). Re-verified at HEAD 3a2da4fc on 2026-11-14.

**The definitive app-quit tier does not exist for native apps (G025, F033).** Item 1 and ADR 0017 list `workspaceAppTerminated` as definitive, and `PrimarySignalKind.isDefinitive` is `self == .workspaceAppTerminated`, but the only `WorkspaceSignal(` constructed anywhere in `daemon/Sources` is in `BrowserMeetingLifecycleAdapter`; `NativeLifecycleAdapter` (Teams, Zoom, Webex, Slack) builds none. `PromotionEngineTests.test_workspace_termination_is_not_vetoed_by_live_process_audio_END14` asserts a Teams-context quit with a live process-audio reading, a pair that cannot occur in production (browsers never emit process audio, native adapters never emit app termination). In the field, 0 of 381 lifecycle `ended` rows carry `workspace_app_terminated`. A normal native quit usually releases the mic first and ends on the 60 s pair dwell; Webex and Slack, which never emit process audio, end on the 720 s lone dwell.

**The live-mic veto never lapses when the process-audio object vanishes (G025, F033; conditional).** `PromotionEngine.tick` returns early `if states.contains(where: { $0.key.vetoesLoneEnd && $0.value.state == .live })`, with no freshness bound. `ProcessAudioSignal.evaluate` emits nothing when the probe returns `nil` ("the signal holds prior state on nil"), and `defaultProbe` returns `nil` when the resolved object set is empty or none of it can be read. So if CoreAudio removes a crashed or force-quit app's process objects before a readable `false` lands, the engine keeps `.live`, a window-gone is vetoed, and no dwell confirms; `SilenceAutoStopPolicy.shouldAutoStop` also returns false for `sourceKind == .native, lifecycleIsLive`, so the idle backstop stands down too ([END25](./END25.md) owns that leg). The HAL teardown order on a crash is unmeasured; the code path is read, the outcome is not observed.

**The regulated held-tail cut is skipped on the single-source path (G026).** `RecordingPostProcessor.produceFinal` applies `applyTrim(lengths, limitSeconds: limitSeconds)` only inside `if hasMic && hasSystem`; the single-source branch (`let source = hasMic ? mic : system`) calls `convertToTempViaFFmpeg` with no duration cap. `MeetingSessionController` logs `held_end_trimmed` with `"mode": keepsHeldTail ? "suggested" : "truncated"` and calls `recorder.stop(limitSeconds:)`, so under the regulated or NDA posture with Screen Recording denied (or a system file under the 4 KB floor) the event says truncated while the held tail stays at rest. Not exercised in the field: all 113 sidecars have NDA off and all 4 `held_end_trimmed` rows are mode `suggested`. If [MIC18](./MIC18.md) lands GO and deletes the destructive stop-time cut, this leg is moot and is closed there; [END21](./END21.md) defers G026 to this amendment explicitly.

**Two comments contradict the shipped rule (G028, accepted trade-off).** `ProcessAudioSignal`'s header says the rail "is what makes the flip safe" because "a mute-, churn- or restart-induced input drop can never solo-confirm a meeting end", and `NativeLifecycleConfig.usesProcessAudio`'s comment says "a lone input drop cannot solo-confirm an end". Since this task's owner decision 2 a lone process-audio drop confirms after the 720 s lone dwell, pinned by `test_a_lone_process_audio_drop_holds_until_the_lone_dwell`. That is the accepted design; the comments are stale. The residual: `reduceIsRunningInput` treats "a mix of one unreadable and one false" as false, so a stale cached mic-owner ID beside readable idle helpers reads `false` rather than unknown, and the poll re-resolves only on a `nil` reading (`if reading == nil && !reResolvedThisStreak`), never on a false. If Teams' mic-owning helper re-registers under a new ID and the list notification is missed, the signal emits ended and a live call ends on the lone dwell 12 minutes later. The re-registration trigger is inferred from DET8's notes, not observed.

**Scope additions.**

7. Start a `WorkspaceSignal` in `NativeLifecycleAdapter` for the adapter's bundle family, so a native quit is definitive as the tier table says.
8. In `ProcessAudioSignal`, when a previously resolved, previously live object becomes unreadable or the resolved set goes empty, re-resolve, and if still unreadable emit an unknown reading that clears the engine's `.live` for that signal (a new state, or dropping the reading from `states`), so the veto lapses. The same rule covers G028's residual: an object that read live and is now unreadable counts as unknown, not as a false beside idle helpers.
9. Settle the conditional part with an owner-run, read-only HAL probe: force-quit Zoom and Teams mid-test-call and log the process-object list and `kAudioProcessPropertyIsRunningInput` reads at 100 ms for 10 s. Record the ordering in this file.
10. Pass `limitSeconds` into the single-source convert as a duration cap (ffmpeg `-t`) and assert the produced length on both merge paths, unless MIC18 has deleted the cut by then.
11. Rewrite the two stale comments to say what is true since END17: a lone drop confirms after `loneDwell`, never sooner.

**Acceptance additions.**

- `NativeLifecycleAdapterTests` (or equivalent): a native adapter emits `workspaceAppTerminated` `.ended` when its app terminates; the existing END14 test is rewritten so the quit arrives through the native adapter, not a hand-made event.
- `ProcessAudioSignalTests`: live, then the resolved set empties, yields an unknown reading and no `.ended`; live, then the owning object unreadable beside a readable false helper, yields unknown and a re-resolve, not `false`.
- `PromotionEngineTests`: a native hold with process audio gone unknown and window gone confirms on the lone or pair dwell instead of staying vetoed (fails at HEAD).
- `RecordingPostProcessorTests`: a single-source produce with `limitSeconds` yields a file of that length; the two-source path still does.
- `bash scripts/ci-local.sh` green, new test counts in the commit body; any new event action documented in `CONVENTIONS.md` with `truth_fences.py` clean.

**Owner walkthrough addition.** [owner] Run scope item 9's probe once (a test call per app, no recording kept; a few minutes). [session] Write the observed ordering into this file before scope item 8 lands, and say there whether the frozen veto is real or only possible.
