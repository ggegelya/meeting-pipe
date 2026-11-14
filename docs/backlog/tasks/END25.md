---
id: END25
title: The idle backstop is not a ceiling: it stands down for any live native verdict and re-nudges forever, any sound resets it, and it reads a muted verdict as silence while the owner talks (gated)
category: Detection
status: new
priority: P3
comment: Filed 2026-11-13 (audit band 2026-11-13). No runaway recording in the pack (one correct backstop stop 562 s after a release, one correct stand-down on 2026-11-10), but the stand-down has no cap, any sound restarts the streak, a stale muted_by_app nudged the owner mid-sentence on 2026-10-12, and the banner fired during live meetings in 3 of 6 cases. Scope: one unconditional level-based ceiling, a stand-down only on a fresh positive reading, a streak held by mic energy whatever the mute verdict, the banner under the same test, and the levels logged; gated on two weeks of DET23's per-second channel levels projecting zero stops on a live call.
---

# END25: The idle backstop is not a ceiling: it stands down for any live native verdict and re-nudges forever, any sound resets it, and it reads a muted verdict as silence while the owner talks (gated)

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Source findings: D041, D066 and D102, with D033 folded in, from the [recording reliability audit](../../audits/2026-11-13-recording-reliability-audit.md) (D041 and D102 in full in the [reliability evidence](../../audits/2026-11-13-recording-reliability-evidence.md)); the [field evidence](../../audits/2026-11-13-field-evidence.md) findings "The silence banner fired during live meetings in 3 of 6 cases" and "Silence backstop: one correct auto-stop, one nudge caused by the stale gate, and one auto-stop attempt during a muted aside that only the lifecycle veto stopped"; stage 10's delete list in the audit's staged plan ("SilenceAutoStopPolicy's stand-down on the lifecycle verdict and IdleStopBackstop's reading of a muted verdict as silence, but only after two weeks of logged channel levels show the level-based ceiling is safe").

**The code at HEAD** (re-read 2026-11-13).

- **The stand-down has no cap (D041, D066).** `SilenceAutoStopPolicy.shouldAutoStop` is `if sourceKind == .native, lifecycleIsLive { return false }`, and `MeetingLifecycleVerdict.isLive` is true for `.starting` and `.inMeeting`. On false, `MeetingSessionController.handleIdleAutoStop` logs `auto_stop_silence_skipped` (`reason: lifecycle_still_in_meeting`), calls `coordinator.silenceBackstop.keepAlive()` and re-posts the banner, with no count and no limit. A native recording whose engine stays live therefore re-nudges every horizon for as long as it runs. Since [END17](./END17.md) removed END13's 7200 s ceiling, nothing else bounds it by time; the low-space stop and the writer-backlog cap are byte bounds.
- **Any sound resets it (D041).** `IdleStopBackstop.ingest` restarts the streak on `!isSilent(verdict) || hasSystemAudio`, so far-side music, a video or the next call playing keeps a finished recording alive.
- **A muted verdict is silence whatever the mic hears (D102).** `IdleStopBackstop.isSilent` returns true for `.silentByRMS, .mutedByApp, .mutedByHardware, .uncertain`; under a muted verdict only far-side audio holds the streak, so a mis-read mute, or real talk in the room under a real mute, counts as an empty call.
- **The banner skips the stand-down.** `handleIdleNotify` logs `silence_notified` and calls `notifyStillMeeting()` with no lifecycle check; only `handleIdleAutoStop` applies `SilenceAutoStopPolicy`.
- **A backstop stop ignores the hold (D033).** `.endingProvisional` is not `isLive`, so a native recording with a hold open, and any browser, manual or mic-only recording, is stopped at the horizon. `handleIdleAutoStop` calls `stopRecording` directly; `pendingEndTrimAt` is set only by `concludeTeardownHold`, so a backstop stop inside an open hold writes no trim and the hold is merely released on the idle transition. The `silence_notified` banner about half a horizon earlier mitigates it but does not guard it.

**Field record, work laptop, 2026-09-29 to 2026-11-13.** Horizon on this machine 480 s with the nudge at 240 s (the nudge-to-decision gap is 240.0 s in both pairs), not the 900 s default.

- 6 `silence_notified`, 1 `auto_stop_silence`, 1 `auto_stop_silence_skipped`; none of them in the newest build's 1.39 h.
- The one auto-stop was right and late: stem 20261006-163051 at 2026-10-06T14:43:59.495Z, 562 s after the mic release, 550 s after the last speech.
- The one stand-down was right: stem 20261110-162917 at 2026-11-10T14:44:06.666Z. The owner had muted at 14:34:37Z, the streak began about 14:36:06Z, and the 240 s before the attempt held 52.8 s of owner-labelled speech plus 67.6 s from three other speaker labels while the mute button read muted, so this was talk in the room under a real mute. The recording ran about 1,920 s more with 1,303 s of speech. Without the stand-down, the backstop would have stopped a live call.
- One nudge fired during owner speech: stem 20261012-182939 at 2026-10-12T15:43:37.594Z. The verdict had gone `muted_by_app` at 15:30:35.632Z on a headset mute event, an AX unmuted reading was suppressed at 15:30:39Z, and the 240 s before the nudge hold 230 s of owner-labelled speech. The stale verdict is [MIC24](./MIC24.md)'s defect; this task's part is that a muted verdict made the backstop deaf to it.
- The banner fired during live meetings in 3 of 6 cases (stems 20261012-182939, 20261104-170016, 20261110-162917; the meetings ran 1,214 s, 402 s and 2,154 s more and ended with speech in their last seconds).
- No runaway recording: the longest of 74 ran 97.3 min and ended through a lifecycle end. The unbounded run is code-derived (D066 is consistent but unproven), because the owner stops by hand. The far-side level the backstop compares is never logged, so the 2026-11-10 reading of the far side as silent is inferred.

Correction at filing: D041's "Owner sees" puts the nudges at 8 and 15 minutes; on this machine they fall at 4 and 8 minutes. D066's "re-nudges forever" holds by code but was not observed: the pack has one stand-down and it was correct.

## Scope (gated)

**Gate, before any behaviour change.** Two weeks of per-second levels of both channels beside every backstop nudge, stand-down and stop, from [DET23](./DET23.md)'s monitor, replayed through the proposed rules below, project zero stops on a call the owner says was live, including the 2026-11-10 call, and still stop the 2026-10-06 shape. Write the projection and the verdict into this file. Until then, the sooner relief is [END23](./END23.md) (a Teams release ceiling that bounds the overrun class) and [MIC24](./MIC24.md) (the stale mute verdict).

0. **Observability, not gated.** `silence_notified`, `auto_stop_silence` and `auto_stop_silence_skipped` carry the system level, the mic level, the verdict and `streak_started_at`. This can ride with DET23 if the owner wants it sooner.
1. **The streak hears the mic.** In `IdleStopBackstop`, mic energy or voice activity above the open threshold holds the streak whatever the mute verdict says (`.mutedByApp` and `.uncertain` stop counting as silence when RMS is open), so a muted aside or a stale mute is not an empty call.
2. **The stand-down needs fresh evidence.** `SilenceAutoStopPolicy` stands down only while a positive reading younger than a bound exists (the monitor reports the meeting app holding the mic, or a live Leave reading inside the bound), not on the lifecycle verdict alone, and never auto-stops while the source's family still holds the mic.
3. **One unconditional ceiling.** Both channels below level for the ceiling (the configured horizon, doubled while the source's family reads held) stops the recording with cause `idle_ceiling`, the cut at the last sound; no lifecycle state can stand it down and `keepAlive` cannot re-arm it more than the ceiling allows.
4. **The banner obeys the same test.** `handleIdleNotify` applies item 2's stand-down before posting.
5. **A backstop stop closes the hold.** When a teardown hold is open, the backstop concludes it explicitly so the stop carries a cut; the trim computation on that route is [END21](./END21.md)'s.

## Explicitly not

- Changing the default horizon (`mic_only_silence_seconds`, 900 s) or the nudge ratio.
- Deleting the backstop: it is the only end for a source-less recording ([END11](./END11.md)'s amendment) and a browser one until DET24's bars land.
- The Teams release ceiling ([END23](./END23.md)), the stale mute verdict ([MIC24](./MIC24.md)) and the reducer's ceilings under the Teams end switch ([END26](./END26.md)); [REC17](./REC17.md)'s down-channel hold stays as it is.

## Acceptance

- `MeetingPipeCoreTests` (`IdleStopBackstopTests`): a `.mutedByApp` verdict with mic RMS open holds the streak (the 2026-10-12 and 2026-11-10 shapes produce no nudge and no stop); mic and system both silent for the ceiling stops even with a live lifecycle; `keepAlive` after a stand-down cannot carry the recording past the ceiling.
- `MeetingPipeTests` (`SilenceAutoStopPolicyTests` and a controller test): a live lifecycle verdict with no fresh positive reading does not stand down; the family holding the mic does; the banner is suppressed under the same condition; a backstop stop with a hold open writes the cut and leaves no hold timer; the 2026-10-06 shape (the family's mic released, a hold open, both channels silent) still stops.
- New attributes documented in `CONVENTIONS.md#event-log-schema`; `python3 scripts/truth_fences.py` clean.
- `cd daemon && swift test` green with the number of tests added in the commit body; `bash scripts/ci-local.sh` green.

## Owner walkthrough

1. [session] After DET23 has logged two weeks of levels, run the projection and list every projected stop with its stem and time.
2. [owner] Label each projected stop as a live call or not. One live call projected to stop fails the gate.
3. [owner] After landing, one call in which you mute and talk to someone in the room for five minutes: no banner and no stop.
