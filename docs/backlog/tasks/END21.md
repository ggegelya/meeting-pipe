---
id: END21
title: The held-end trim cuts at the hold's first weak stamp however long the hold ran, and a Stop or any non-lifecycle stop during an open hold applies no trim at all
category: Detection
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). TeardownHoldPolicy.trimPoint returns the hold's first stamp, and a Leave-led hold opens under a live mic (31 such holds in the pack, all reverted so far, so no wrong cut seen; all 4 era C trims equalled the mic release within 0.1 s), while a hand Stop, the low-space stop or the idle backstop inside an open hold trims nothing. Cut at the process-audio release, trim nothing while the mic is live, compute the trim on every stop route.
---

# END21: The held-end trim cuts at the hold's first weak stamp however long the hold ran, and a Stop or any non-lifecycle stop during an open hold applies no trim at all

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Source findings: G001 (critical), G031 and F032 in the [independent audit](../../audits/2026-11-12-independent-audit.md); D028, D037, D043, D069 and plan patch C in the [recording reliability audit](../../audits/2026-11-13-recording-reliability-audit.md) (evidence in [recording-reliability-evidence.md](../../audits/2026-11-13-recording-reliability-evidence.md)). Re-verified against HEAD `3a2da4fc` on 2026-11-13 by code reading.

**The cut is the first doubt, not the end.** `TeardownHoldPolicy.trimPoint(concludingAt:)` returns `hold.startedAt` for any hold of at least `minimumTrimmedHoldSec` (1 s), with no upper bound and no input about liveness; its doc says "Everything captured since it opened is post-call audio by construction". `open(context:at:)` keeps the first stamp on re-entry ("a flapping signal must not move it later"). `TeardownHoldPolicyTests` pins it: `XCTAssertEqual(policy.trimPoint(concludingAt: at(820)), at(100), "re-entry did not move the cut")`.

**A hold can open while the call is plainly up, and stay open.** `PrimarySignalKind.axLeaveButton` has `requiresCorroboration == true`, so `yieldsToLiveVeto` is false and `PromotionEngine.handleInMeeting` opens `.endingProvisional` on a Leave-invalid edge even while process audio reads `.live`. `tick(at:)` never confirms while a vetoer reads live, and `handleEndingProvisional` reverts only on a live *edge*; every native signal emits on change only, so a mic that was already live never re-emits. Teams' compact view hides the Leave control "as long as the owner leaves the call window alone" ([gotchas.md](../../../daemon/docs/gotchas.md), measured 2026-09-04, 40 minutes). When the call then ends genuinely by any route (teardown, the first tick after the mic release, since `loneHeld` counts from `startedAt`, or an app quit), `concludeTeardownHold` sets `pendingEndTrimAt` to that first stamp, and every in-call minute since the Leave flicker is cut.

**What the cut does.** `stopRecording` turns `pendingEndTrimAt` into `trimSeconds`. Under a lossless capture (`activeCaptureMode?.capturesLosslessly == true`) it is written as a suggested trim: the WAV keeps the span, the transcript and summary leave it out (`HeldEndTrim`), and the Audio tab's Restore undoes it. Under the regulated gate (regulated mode, an NDA workflow or an unknown mode) it is passed as `recorder.stop(limitSeconds:)`, and the two-channel merge truncates with intermediates removed, so the in-call audio is gone for good. That destructive leg is what [MIC18](./MIC18.md) may delete outright; the lossless leg stands under either MIC18 verdict.

**A lone-dwell end is not evidence of when the call ended (F032).** A browser hold confirmed by the 12 minute lone dwell (`confirmedBy` carries `lone_dwell`) also trims at its start, so a presenter who stayed in another tab of the same window for 12 minutes loses those minutes from the notes. ADR 0017 and END17's owner decisions accepted the trim point for genuine post-call holds; none weighed this case.

**Stops inside an open hold apply no trim (G031, D043, D069).** `pendingEndTrimAt` is set at one site, `concludeTeardownHold`, reached only from the lifecycle consumer's `.ended` branch and `consultTeardownOracle`. A hand Stop during Confirming end (`toggleManual` or `forceStop(reason: "hotkey")`), `handleLowSpace`'s `forceStop(reason: "low_space")`, the write-failure `forceStop`, the URL-scheme stop and `handleIdleAutoStop` all reach `stopRecording` with it nil; `disengageLifecycle` later only releases the hold. So the post-call tail is kept and transcribed with no `held_end_trimmed` row, contrary to [ADR 0017](../../decisions/0017-hold-long-trim-later-end-detection.md) ("Anything held is marked as the trim point") and [GUIDE.md](../../GUIDE.md) ("the extra minutes are left out of your notes"). Under NDA the tail is kept on disk too. END9's spec deliberately had the force-stop hotkey confirm with `trimAt = now`, so a stop inside a hold is an owner decision, not a bug fix alone.

**Field.** Not seen as a wrong cut. 31 Leave-led holds under a live mic in the pack: 26 reverted when the control read healthy within 5.0 to 44.9 s, 3 on a returning window reading, 1 ended by a second signal, 1 coincided with a hand stop. In era C, holds of 5.5, 8.3 and 38.3 s opened on live calls and reverted. All 4 era C trims were mode `suggested` and each equalled the mic release offset within 0.1 s (112.8, 1030.8, 1280.5, 594.0 s). 0 of 113 sidecars carry the NDA flag, so the destructive form has never run. 0 stops inside an open hold in era C.

Correction at filing: G001's critical rating rests on the regulated gate; under the default lossless posture the loss is transcript and summary only and one click restores it, which is why this files at P2 while MIC18 (P1) decides the destructive leg. The cut also needs the Leave control (or window) not to read live again before the end; if it does, the hold reverts and the trim clears (`self.pendingEndTrimAt = nil` in the consumer's default branch).

## Scope

1. **Cut at the release, not the doubt (plan patch C).** When the engaged adapter uses process audio, the trim point is process audio's `.ended` stamp in the engine's `states` (the mic release), handed to the host with the `.ended` verdict or read through the coordinator; if process audio still reads `.live` when the hold concludes, nothing is trimmed. `TeardownHoldPolicy.trimPoint` takes that stamp as an input instead of returning `hold.startedAt` unconditionally.
2. **Adapters without process audio (browser, Webex, Slack): owner decision.** Either keep the hold's start as the cut for pair-confirmed and teardown ends and trim nothing for a `lone_dwell` confirm (F032's direction), or keep the hold's start everywhere. Recommended: no trim on `lone_dwell`.
3. **Every stop route inside an open hold.** `stopRecording` computes the trim itself while `holdPolicy.isOpen`, so the hand Stop, `forceStop` (hotkey, low space, write failure, URL scheme) and `handleIdleAutoStop` all apply the same rule and write `held_end_trimmed`, with a new `stop_route` attribute. What a user Stop inside a hold means is the owner's call: treat it as concluding the hold (cut at item 1's point), or as END9's `trimAt = now` (no cut). Recommended: conclude the hold under item 1's rule, since the Stop is usually the owner confirming what the HUD already said.
4. **Docs in the same commit.** Align ADR 0017's "What a confirmed hold does to the audio" paragraph and `docs/GUIDE.md`'s Stopping and Confirming end text with items 1 to 3.

## Explicitly not

- Whether the regulated truncating cut exists at all: [MIC18](./MIC18.md). If MIC18 deletes it, items 1 to 3 still decide what the transcript and summary leave out.
- The regulated single-source branch ignoring `limitSeconds` (audit G026) and native app quit as a single source: [END17](./END17.md)'s 2026-11-13 amendment.
- `HeldEndTrim.trimSeconds` reading the sidecar with `try?`: SEC37.
- Revert rules that act on levels rather than edges (a healthy Leave re-arm never reverting a hold, D028's engine half): END18. Sleep inside a hold: END22.
- [END13](./END13.md)'s Confirming end HUD and [T8](./T8.md)'s replay harness are reused, not changed. The low-space stop itself is [REC20](./REC20.md)'s.

## Acceptance

- Replace `TeardownHoldPolicyTests`' first-stamp pin with: a Leave-invalid hold opened at 31 min under a live mic, mic released at 60 min, ended by the pair dwell; the trim point is the release, not 31 min. A second case: the hold concludes while process audio still reads live; no trim.
- A lifecycle trace in the detection corpus with the same shape (40 minute Leave-absent hold, late genuine end), cut at the release.
- F032: a browser hold confirmed by `lone_dwell` follows the owner's item 2 choice (no trim, if recommended).
- `HeldEndSessionTests`: a hand Stop, `forceStop(reason: "low_space")` and `handleIdleAutoStop` each inside an open hold write `held_end_trimmed` with the item 3 trim and their `stop_route`; under a lossless mode the trim is suggested, under the regulated gate it is passed as `limitSeconds` (until MIC18 says otherwise).
- The 4 era C trims still land at the release: the existing pair-dwell and teardown tests (`CallTeardownHoldTests`, `zoom_native_lifecycle_pair_dwell_trim.json`) stay green, updated only where they pinned the first stamp.
- `stop_route` documented beside `held_end_trimmed` in `CONVENTIONS.md`; `python3 scripts/truth_fences.py` green; ADR 0017 and `docs/GUIDE.md` updated in the same commit.
- `cd daemon && swift test` green with N new tests named in the commit body; `bash scripts/ci-local.sh` green.

## Owner walkthrough

1. [owner] Answer items 2 and 3 before the pickup lands them.
2. [session] Confirm the installed build is newer than the landing commit.
3. [owner] Once during a Teams call, switch to the compact call view for a few minutes, then end the call normally; once, press Stop while the panel reads Confirming end. Pass: in the Audio tab neither recording shows a trim earlier than the moment the call actually ended.
4. [session] Grep `events.jsonl` for `held_end_trimmed` rows that week and compare each `limit_sec` with the preceding `process_audio_is_running_input` false row; report any gap over 5 s.
