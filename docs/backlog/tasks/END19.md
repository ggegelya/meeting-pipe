---
id: END19
title: A browser engage that never reached a recording is never torn down, and its lone weak end from .starting stops a hand-started recording mid-call
category: Detection
status: new
priority: P1
comment: Filed 2026-11-13 (audit band 2026-11-13). Broken promise, a recording lasts as long as the meeting: the hand-started 20261111-155951 was stopped mid-conversation at 876.9 s by a stale Chrome engage's unconfirmed tab-title end from .starting, and stale browser engages lived 15 to 176 minutes on four days; the owner may re-band. Bound an engage that never reaches .starting, and let a source-less recording ignore an end from an engage that predates it and never reached in_meeting.
---

# END19: A browser engage that never reached a recording is never torn down, and its lone weak end from .starting stops a hand-started recording mid-call

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Source findings: D094 and plan patch D in the [recording reliability audit](../../audits/2026-11-13-recording-reliability-audit.md) (evidence in [recording-reliability-evidence.md](../../audits/2026-11-13-recording-reliability-evidence.md)); the field findings "A recording with no source is stopped by any engaged adapter's starting to ended, with no hold" (sessions and lifecycle) and "A manual recording was stopped mid-conversation by an unconfirmed browser tab-title end" (transcripts and summaries) in [field-evidence.md](../../audits/2026-11-13-field-evidence.md). Re-verified against HEAD `3a2da4fc` on 2026-11-13 by code reading.

**The incident, 2026-11-11, stem 20261111-155951 (`bundle_id` manual, work-laptop build era 2).** `discovery_shadow_pick` chose `com.google.Chrome` at 13:59:31.063Z with `winner_score` 2 (title match only; leave, mute, toolbar and process audio all false) and engaged a browser lifecycle that raised no `starting`. The owner started a recording by hand at 13:59:52.402Z. `lifecycle starting` for Chrome came at 14:12:18Z, 767.8 s after the pick and during the recording. `lifecycle ended` (leading `browser_tab_title_left_meet_pattern`, `confirmed_by` empty, predecessor `starting`) at 14:14:28.163Z stopped the recording 6 ms later at 876.9 s, with the transcript mid-topic (tail 0.3 s). The same tab matched again 8.2 s after the stop; `prompt_shown` at 14:14:36.731Z timed out at 14:15:06.823Z into `default_action` skip, and nothing more was recorded that day. All 4 browser `ended` events in the pack are unconfirmed (era A 3, era B 1, era C 0).

**Why the engage outlived its scan.** `MeetingDiscoveryWatcher` calls `onDiscovered` only when a scan has a winner (`if let winnerSource { self.onDiscovered?(winnerSource) }`). The lifecycle is disengaged only on the idle transition (`Coordinator.wireSubsystems`, `stateMachine.onIdleTransition` calling `session.disengageLifecycle()`), in `stopRecording` (`coordinator.lifecycleCoord.disengage()`), or when `MeetingLifecycleCoordinator.engage` for another bundle disengages first. Nothing tears down an engage whose bundle the scans stopped admitting, or whose window read never matched. D094 counted four such Chrome engages on the work laptop: 2026-10-06T08:58:38Z for 95.3 min (ended by a Teams build), 2026-10-07T09:03:34Z for 176.5 min (ended in a Chrome `starting` and a prompt at 12:00:03.385Z that timed out), 2026-10-21T12:32:54Z for 119.5 min (191 signal rows, 28 `shareable_content_unavailable`), and 2026-11-11T13:59:31Z for 15.0 min (the incident).

**Why the end stopped a recording it had nothing to do with.** Three layers each behaved as written:

1. A manual start carries `source: nil`, so `engageLifecycleIfNeeded` returns at `guard let source = source` and the stale Chrome engage stays attached; `beginRecording`'s `lifecycleCoord.confirmRecording()` is a no-op because that engine was still `.idle`.
2. When the tab title later matched, `PromotionEngine.handleIdle` moved the engine to `.starting`. `confirmLateStartIfRecording` promotes a late `.starting` only for `.recording(_, let source?, _)` with a matching bundle, so a source-less recording never confirms it, and `handleMeetingStarted` returns at `isAcceptingPrompts`. The engine stays in `.starting`, where END17's hold does not exist: `handleStarting` ends directly on a lead with `requiresCorroboration == false`, and `.browserTabTitle` (like `.shareableContentWindow`) is one.
3. `MeetingSessionController.handleMeetingEnded` in `.recording` skips another app's end only when the recording has a source (`if let src = src, src.bundleID != bundleID` logs `meeting_end_ignored_other_app`). END11 item 4 chose this on purpose: "A source-less recording has no identity to compare against ... Honouring it stays the safer direction for that path." So `stopRecording` ran.

**Recovery made it worse.** The end left no resume candidate (`resumeCandidate` is written only `if let src = src`), so the re-sighted tab got an ordinary prompt that timed out to skip, and the rest of the call was lost.

Correction at filing: the class summary says the stale engages lasted 95 to 176 minutes; the four measured 15.0, 95.3, 119.5 and 176.5 minutes. D094 says `engageLifecycleIfNeeded` logged `already_engaged` for the manual start; for a source-less start it returns before that guard and logs nothing, with the same effect. And discovery runs no scans outside idle (PERF17's scan gate), so a "scan stopped admitting the bundle" disengage can act only before a recording starts; the controller-side guard in Scope item 3 is what protects a recording already running.

## Scope

1. **Bound an engage that has not reached `.starting`.** In `MeetingSessionController.handleDiscovery` and the discovery watcher's no-winner path, track the engaged bundle's last admitting sighting; when a scan completes with no winner for that bundle for a short life (a few scan intervals, value and reasoning beside the constant) and the engine is still `.idle`, call `disengageLifecycle()` and log `lifecycle_disengaged_stale` (`coordinator`, `bundle_id`, `engaged_sec`, `scans_without_sighting`).
2. **One matcher set for admission and the window signal.** The browser adapter's `ShareableContentSignal` match (`matchers.contains { $0(title) }` in `BrowserMeetingLifecycleAdapter.start`) and the scanner's browser admission must be the same predicate, so an engage the window signal can never see as live is not made. Do not engage on a score-2 title-only browser pick unless that shared predicate accepts the selected tab; coordinate with DET17 (the code-less Meet title opener) so its prompt-only opener does not reintroduce the gap.
3. **A source-less recording ignores an end from a foreign, never-promoted engage.** In `handleMeetingEnded`'s `.recording` branch with `src == nil`, drop an `.ended` whose engage began before the recording started and never reached `.inMeeting` for this recording, and log `meeting_end_ignored_sourceless` (`coordinator`, `ended_bundle_id`, `leading_signal`, `engaged_before_recording` true). The controller records the engage time and whether `confirmRecording` promoted it; the Core engine is unchanged. An engage that did reach `.inMeeting` under this recording (a future hand-start adoption) is still honoured, so this narrows END11 item 4 rather than reversing it.
4. **A re-sighted source after an end-stopped recording resumes rather than prompting into skip.** When a lifecycle end stops a recording (sourced or not) and the same bundle's `.starting` arrives within seconds, offer END17's resume (`ResumeAfterEnd`) for the source-less case too, keyed to the ending bundle, or at minimum present the prompt with Record as its timeout action. The pickup picks one and records why.

**Owner decision at pickup.** Item 3 narrows END11's recorded decision that a source-less recording honours any end. Put it to the owner before landing: honour only ends from an engage this recording promoted (recommended), or keep honouring all ends and rely on items 1 and 2 alone.

## Explicitly not

- Adopting the engaged meeting into a hand start (attach the engaged adapter's source and run the normal hold): DET26 (gated on its own owner decision). If it lands first, item 3 still guards the source-less remainder.
- The end side of browser detection (tab switches, Spaces, the 120 s floor): DET20. The first-reading race for native signals: END20.
- A source-less recording's only end being the silence backstop (long tails): END11's 2026-11-13 amendment.
- Deleting browser detection: [DET16](./DET16.md)'s probe decides that; a FAIL verdict keeps browser detection and this task with it. A PASS verdict shrinks items 1 and 2 but item 3 still applies to any engaged adapter under a hand start.
- [DET6](./DET6.md) (browser corroboration by mic) and [DET13](./DET13.md) (retained candidate) are adjacent and unchanged.

## Acceptance

- `MeetingSessionController` test of the 2026-11-11 shape: a browser engage in `.idle`, a manual start with `source: nil`, then `.starting` and a `.ended` led by `browser_tab_title_left_meet_pattern` with empty `confirmed_by`; the recording keeps running and `meeting_end_ignored_sourceless` is emitted once.
- The control: a sourced recording's own `.ended` still stops it, and a source-less recording with no engage at all is unchanged.
- An engage whose bundle is absent from consecutive idle scans for its stated life is disengaged and logs `lifecycle_disengaged_stale`; one re-sighted inside the life is kept (two tests, injected scan results and clock).
- A browser candidate the shared predicate rejects produces no engage (scanner plus adapter test against one fixture of title shapes, shape classes only).
- Item 4: a same-bundle `.starting` within the window after an end-stopped recording records without a prompt, or prompts with Record as its timeout action, per the pickup's choice.
- New `coordinator` actions documented in `CONVENTIONS.md`; `python3 scripts/truth_fences.py events` green (the fence diffs categories, and `coordinator` exists).
- `cd daemon && swift test` green with N new tests named in the commit body; `bash scripts/ci-local.sh` green; `docs/GUIDE.md` updated in the same commit if a hand-started recording's end behaviour changes in a user-visible way.

## Owner walkthrough

1. [owner] Answer the Scope decision on END11 item 4 before the pickup lands item 3.
2. [session] Confirm the installed build is newer than the landing commit.
3. [owner] Once, with a Meet tab open but not in a call, start a recording by hand with the hotkey, then join and later leave a Meet call in that tab. Pass: the recording is not stopped by the tab title changing; it stops by hand.
4. [session] Grep that day's `events.jsonl` for `meeting_end_ignored_sourceless` and `lifecycle_disengaged_stale` and report each with its timestamps.
