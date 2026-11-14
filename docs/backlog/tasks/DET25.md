---
id: DET25
title: Add the MicSession reducer in Core and run it in shadow beside PromotionEngine, logging would_offer and would_close for every family
category: Detection
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). End detection has accreted one rule per incident over edge-triggered signals (END9 to END17), and the plan's target is a pure reducer over sampled mic levels; in the newest build one real 98.7 s drop still split a call into two stems. Add MicSession.decide in MeetingPipeCore with per-family profiles, replay it in CI over the truth-labelled corpus, and run it live in shadow logging would_offer and would_close with no behaviour change; depends on DET23, and its numbers feed the plan's GATE (END26).
---

# DET25: Add the MicSession reducer in Core and run it in shadow beside PromotionEngine, logging would_offer and would_close for every family

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Source: stage 8 ("The reducer, a level corpus, shadow decisions (no behaviour change)") of the staged plan and the STATE MACHINE, CONSTANTS, CUT and REJOIN paragraphs of "Recommended target design" in the [recording reliability audit](../../audits/2026-11-13-recording-reliability-audit.md); lows D101 (confirmed, demonstrated) and D021 (not seen, code-derived) folded in below, with D101's evidence in [recording-reliability-evidence.md](../../audits/2026-11-13-recording-reliability-evidence.md). Re-verified against HEAD `3a2da4fc` on 2026-11-13 by code reading.

**Why a reducer.** [END17](./END17.md) records the class: END9 to END15 were each filed P1 from a chopped meeting and each fix patched the rule the previous one shipped, all deciding on edges a third-party UI change can fake (an AX tree blackout, a title format, a device switch). `PromotionEngine` today holds a weak end for `defaultConfirmDwell` (60 s) or `defaultLoneDwell` (720 s) and confirms on cross-class pairs. The audit re-derived from the work-laptop pack that the per-process mic flag was the reading that was right: in the newest build all 4 detected Teams ends were led by the mic release (three real ends and one real 98.7 s drop); 7 of 69 native recordings were stopped with no final release before the stop (the four chopped October recordings and three hand stops); and the stop followed the final release by a median 4.8 s (era A, n=18), 5.5 s (B, n=38) and 62.2 s (C, n=6). Its limits are as plain: every mic row in the pack was logged while the old detector was engaged, the grace rests on two same-call gaps near 23 s sampled through a poll that adds up to 5 s, and browsers have 0 rows. So the reducer is built in shadow first and only acts if the GATE says so.

**The reducer, per the plan.** `MicSession.decide(state, event, now)` is pure, in MeetingPipeCore, returning the next state and a list of effects (show or hide offer, start recorder, stop recorder with cause and cut, log). Events: monitor samples from [DET23](./DET23.md), owner actions, app exit, sleep and wake, recorder callbacks. One state per family (idle, arming, offered, declined, recording, releasing), at most one recording bound to at most one session. Per-family profile: open debounce D (3 s Teams and Zoom, 5 s a browser with an identified meeting page, 20 s a browser without, 30 s an unlisted app), close grace G (60 s first, then set once from DET23's uncensored gap table to the larger of 30 s and 1.25 times the longest same-call gap that returned, capped at 60 s), rejoin window R (120 s), and `release_means_end` (yes for Teams, ambiguous for Zoom until bar Z1 of [DET24](./DET24.md) passes and for Slack, classic Teams, unlisted apps and any browser that fails its mute bar, never for Webex). The cut is the release sample plus 2 s.

**Low D101 folded in (demonstrated once).** A real call drop longer than the 60 s pair dwell splits one meeting into two recordings with a hole. Era C, 2026-11-12: process audio false at 15:44:27.920Z, `lifecycle_end_held` (`confirm_dwell_sec` 60) at 15:44:27.928Z, `lifecycle ended` at 15:45:27.963Z with `confirmed_by` [`ax_leave_button_invalid`, `shareable_content_window_gone`], `held_end_trimmed`, then `recording_resumed_after_end` at 15:46:06.606Z (`since_end_sec` 38.6) into stem 20261112-174606 whose sidecar carries `resumed_from` 20261112-172307. This is ADR 0017's designed resume-into-new-stem with a Merge offer, so the cost is a split and a 39 s unrecorded gap, not lost held audio. It is the "98.7 s drop" this task's corpus case names. The audit's interim direction, if the reducer is slow, is to keep the recorder running through the resume window or, on resume, restore the held tail and join the pair rather than offer a Merge (END17's `resumed_from`).

**Low D021 folded in (not seen).** `MeetingDiscoveryWatcher.scheduleScan` returns at `guard isAcceptingPrompts() else { return }`, and `DetectionStateMachine.State.isAcceptingPrompts` is true only in `.idle`, so no scan runs while a recording is in its held end. A same-app second call inside the hold reverts it through its live signals and continues the first recording under the first call's workflow; a different-app call waits until the hold confirms. The audit inferred (not observed) that the 4 cooldown-held calls of eras A and B, which came back 6 to 54 s after the end signal, would at HEAD merge into the first recording this way. A mic-level reducer cannot tell a dropped call from the next meeting inside G either, so the shadow must log both shapes for the GATE to weigh.

## Scope

1. **`MicSession` in MeetingPipeCore** (`Lifecycle/`), a pure `decide` per the island rules, with the profile as a value type whose defaults are the constants above and whose per-family values the pickup reads from `meeting_apps.toml` as the plan specifies. No AppKit, no HAL handle: the host forwards inputs.
2. **A shadow host in the app** fed by DET23's monitor stream, the owner's Record, Skip and Stop, `WorkspaceSignal` app exit, sleep and wake, and recorder start and stop callbacks. It executes no effect: it logs `would_offer` and `would_close` (category `detector`; family, session id, cause, the cut it would have used, and the live engine's state beside it) and nothing else. Started through `Coordination/SessionWatchers.swift` like DET23.
3. **CI replay** of the reducer over the truth-labelled level traces [T17](./T17.md) builds from the work-laptop pack, with a virtual clock, in `MeetingPipeCoreTests` beside `DetectionCorpusTests` and `LifecycleTraceReplay`. Report G at 30 s and 45 s as well as 60 s.
4. Document the new actions in `CONVENTIONS.md` and the reducer in `ARCHITECTURE.md` as shadow-only.

## Explicitly not

- Any behaviour change. The end switch for Teams is [END26](./END26.md) (gated on the GATE), browsers on the reducer are [DET20](./DET20.md), session-bound offers and hand-start adoption are [DET26](./DET26.md), the release ceiling is [END23](./END23.md). This task is the evidence those decisions read.
- The interim D101 fix (keep the recorder through the resume window, or rejoin the pair automatically). Named here so it is not lost; if the GATE keeps Teams on the patched engine, it is filed against END17's resume item on its own.
- A far-side check on the system channel: the plan ships it only if DET23's 120 s post-release levels show the far side quiet inside G on at least 90 percent of real ends.
- Folding PromotionEngine into the reducer or deleting any END rule (the plan's delete stage, after two clean weeks on a switched path).

## Acceptance

- `MicSession` unit tests over the state table: arming that releases before D shows nothing; a hold of D opens one session and one offer; a gap shorter than G returns to recording with a `mic_gap` and no close; a release held G closes with the cut at release plus 2 s; unknown pauses the clock; app exit closes at once; a same-family return inside R after a close is a linked second part; Webex never closes on release; sleep closes with the mark at sleep time.
- D021 shapes as shadow cases: a same-app second call starting inside an open hold, and a different-app call starting during a hold, each with the expected `would_offer` and `would_close` sequence written by hand before the run.
- CI replay over T17's traces: the four October chops (era A Teams recordings cut after 8 to 87 s by window-gone) stay recording; both same-call gaps near 23 s survive at G = 60 s (results at 30 s and 45 s reported, not gated); the three sourced missed ends (562.4 s to the idle backstop and 63.2 s to a hand stop in era A, 379.8 s to a hand stop in era C, each measured from the mic release) close G after the release; the 98.7 s drop of 2026-11-12 yields two linked parts.
- A fence test that the shadow host holds no reference to the recorder, the prompt window or the state machine's mutators, so it cannot act.
- `python3 scripts/truth_fences.py events` green with `would_offer` and `would_close` documented; `cd daemon && swift build` and `swift test` green with N new tests named in the commit body; `bash scripts/ci-local.sh` green.
- Field, after ten working days of shadow on the work laptop: zero `would_close` while the family's mic reads held, and `would_close` within G plus 5 s of a release on at least 95 percent of calls; the numbers written here and handed to END26's GATE.

## Owner walkthrough

1. [session] Confirm DET23 has its ten days and G is set from its gap table; confirm the installed build is newer than this task's landing commit.
2. [owner] Use the app normally for ten working days. Cost: no extra calls.
3. [session] Read the shadow rows against the live engine's ends (timestamps, families and stems only) and write the two field bars here, with every `would_close` that fired while the mic read held listed by timestamp.
