---
id: DET22
title: In a contested scan an idle native with stale signals raises the bar for, or blanks, a real call, because pickBest judges contenders against a shared floor instead of each app's own bar
category: Detection
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). Code-derived, not yet seen costing a call: an idle Teams matches its permissive title most of the day (DET9 counted 293 of 294 Teams drops title-only) and 12 of 108 work-laptop picks had two candidates, so a Zoom title-plus-Mute (4) or a Webex Mute-only call that passes alone fails beside it, and a native with two stale signals scoring 4 blanks a real browser Meet. Drop contenders that fail their own lone bar before choosing the branch, and let a native block a browser only if it clears the contested floor itself.
---

# DET22: In a contested scan an idle native with stale signals raises the bar for, or blanks, a real call, because pickBest judges contenders against a shared floor instead of each app's own bar

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Source findings: D025 and D014 in the [recording reliability audit](../../audits/2026-11-13-recording-reliability-audit.md) (both low; D025 "consistent but unproven", D014 "not seen", both listed as unverified lows), with the audit's correction 9 to D025 in its "Where the code-only trace was wrong" paragraph and the two Zoom pickup rows in [recording-reliability-evidence.md](../../audits/2026-11-13-recording-reliability-evidence.md). Re-verified against HEAD `3a2da4fc` on 2026-11-13 by code reading of `MeetingSourceScorer` and `MeetingSourceScanner`.

**How `MeetingSourceScorer.pickBest` decides today.** It scores every candidate, drops those with zero evidence (`contenders = candidates.filter { distinctSignalCount($0.signals) > 0 }`), and then branches on the count. With exactly one contender it applies that app's own bar: a browser stands on `titleMatch` or any corroborator; a native with `hasAudioLeg` (Zoom, Teams, Slack) must pass `isConfidentNativeMeeting` (the toolbar, or two distinct signals); Webex and spark (`hasAudioLeg` false) need one corroborator (`hasCorroboratingSignal`). With two or more, a title-matched browser wins unless a native that `isConfidentNativeMeeting` and `$0.score >= bestBrowser.score` rivals it, and otherwise the shared floor applies to the top scorer: `best.score >= threshold` (5) and `distinctSignalCount(best.signals) >= minDistinctSignals` (2), else nil.

**Why an idle Teams is a contender most of the day.** `MeetingSourceScanner.isActiveMeetingWindow` for `com.microsoft.teams2` rejects only a fixed chrome list ("chat", "calendar", "activity" and so on) and returns `!lowered.isEmpty` for any other title, by design ("prefers false-positives ... over false-negatives"). A chat thread or meeting-topic window therefore sets `titleMatch`, one distinct signal, so Teams survives the zero-evidence filter. DET9's pickup read of the owner's log found 293 of 294 Teams `candidate_dropped` sightings title-only, around the clock.

**D025, a real native call beside an idle Teams.** Title plus Mute (score 4, two distinct) passes a lone Zoom's bar. Beside a title-only Teams (score 2, one distinct) the contested floor needs 5, so the scan returns nil. A Webex call showing only Mute (score 2) passes alone through `hasCorroboratingSignal` and fails contested at the same floor. The sticky bonus does not rescue either case unless the real call was already the last winner.

**D014, a browser Meet beside a native with two stale signals.** A browser admitted on a Meet title scores 2 (3 if sticky). A native whose control walk ran (`shouldWalkControlAX` walks a title-matched, frontmost or lone native) and found a lingering Mute plus its permissive title scores 4 with two distinct signals, so it is "confident" and `4 >= 2` blocks the browser exemption; the generic floor then rejects the native at 4 and returns nil, blanking the real browser call. Had the stale native scored 5 (for example sticky, or Leave plus Mute), it would win instead and the Meet would be recorded under the wrong app.

Correction at filing: the class summary says `candidate_count` is 1 on every logged pick. The audit's own correction 9 says that does not hold on the work laptop: 12 of 108 `discovery_shadow_pick` rows had two candidates and Teams is a standing second contender, so the contested branch does run in the field. The two Zoom late pickups tagged D025 in the evidence timeline (2026-10-13T14:01:32Z, stem 20261013-170136, beside a title-only Teams; 2026-11-12T15:01:07Z, stem 20261112-170131) were Mute-only Zoom (score 2, one signal), which fails a lone Zoom's bar too, and both were picked at score 5 once process audio arrived; the delay there is D015's (owned by the [DET12](./DET12.md) amendment), not this floor. No logged pick shows this floor costing a call, so the harm stays code-derived, as the audit rated it.

## Scope

1. **Judge each contender against its own bar first.** In `MeetingSourceScorer.pickBest`, lift the lone-candidate `switch` into a static `passesOwnBar(_:)` (browser: `titleMatch` or a corroborator; native with `hasAudioLeg`: `isConfidentNativeMeeting`; native without: `hasCorroboratingSignal`), and filter the zero-evidence contenders through it before branching. None qualifies: nil. One qualifies: return it, whatever else is idling. This is behaviour-identical for a lone candidate.
2. **Two or more qualified: keep today's contested logic, with one narrowing.** A native blocks the trustworthy-browser exemption only if it would itself clear the contested floor (`score >= threshold`, `distinctSignalCount >= minDistinctSignals`) and `score >= bestBrowser.score`; otherwise the browser wins. Between natives that both qualify, the existing floor still decides and still returns nil rather than guess when neither clears it.
3. Update the `pickBest` doc comment and the DET5 comments in the contested branch so they state the new rule, and record in the comment why a title-only native no longer counts as a contender (it could never win, so it should not be able to raise the bar).

## Explicitly not

- Tightening the Teams title recognizer: its permissiveness is deliberate on the end side, and [PERF6](./PERF6.md) owns the idle cost of the title-only Teams walks. This task removes the title-only Teams from contention instead.
- Making audio alone clear a native's bar (D015's question): the [DET12](./DET12.md) amendment, gated on bar Z1 of [DET24](./DET24.md).
- The sticky bonus in the block test: a stale native that was the previous winner reaches 5 with title plus Mute and still outranks a Meet. Named here so it is not lost; changing it needs a field case, since the bonus is what keeps a real call from flapping.
- Changing which candidates the scanner builds, the weights, or the `candidate_dropped` and `discovery_shadow_pick` rows.
- Replacing the scorer as the start authority: [DET26](./DET26.md) (session-bound starts, gated) and [DET25](./DET25.md) (the reducer in shadow). The plan keeps the scanner and scorer as the offer-only second opener, so this fix stays useful either way.

## Acceptance

- `MeetingSourceScorerTests`, new cases: an idle Teams (title only) plus a Zoom with title and Mute picks Zoom; an idle Teams (title only, sticky) plus a Webex with Mute only picks Webex; a native with title and a stale Mute (score 4) plus a browser with a Meet title picks the browser; a native showing title, Leave and Mute (score 7, a real native call) plus a browser Meet title still picks the native; two qualified natives both at score 4 return nil; a lone native title-only still returns nil and a lone browser title-only still wins.
- The existing scorer and scanner tests stay green unchanged, including DET5's idle-Teams-chat-versus-Meet regression and DET12's audio cases.
- `cd daemon && swift build` and `swift test` green with N new tests named in the commit body; `bash scripts/ci-local.sh` green.
