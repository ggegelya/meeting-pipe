---
id: END31
title: A clean Teams leave still shows Confirming end for 10 to 30 s; confirm in a few seconds when the microphone release, the Leave button and the call window all agree
category: Detection
status: new
priority: P1
comment: Filed 2026-11-21 from the owner's report after trying real meetings on the newest build, "system still hangs on capturing end after Teams ends the call, for 10 to 30 seconds". P1, broken promise: a recording ends when the meeting does; the hold waits for Teams' teardown log line or the fixed 60 s `defaultConfirmDwell` even when every live reading already says the call is over. Scope: a short dwell when the mic release, Leave invalid and window gone are all fresh edges in the hold. Owner may re-band.
---

# END31: A clean Teams leave still shows Confirming end for 10 to 30 s; confirm in a few seconds when the microphone release, the Leave button and the call window all agree

Band origin: filed 2026-11-21 (owner field report during the second fix review, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

On 2026-11-21 the owner reported that, with the latest landings installed, a Teams call that ends normally leaves the HUD on "Confirming end" for 10 to 30 seconds. That is the END17 hold working as designed, and the design is what this task changes.

What the code does (read at `42cc7d35`): a weak end opens a hold; the recorder keeps running and `RecordingHUDWindow` shows `"Confirming end"`. The hold concludes on one of two routes: `TeardownHoldPolicy.consult` confirming through `CallTeardownOracle` once `CallTeardownWatcher` has parsed Teams' `UnregisterCall` line, or `PromotionEngine` pairing two evidence classes that have each stayed ended for `confirmDwell` (`public static let defaultConfirmDwell: TimeInterval = 60`). Nothing confirms sooner, however strongly the live readings agree.

Why 10 to 30 s and not 60 (inference, not measured): before [END16](./END16.md) the teardown line confirmed 0 of 59 Teams ends in the field pack and every end in the 2026-11-12 build waited 60.01 to 60.08 s. END16 made the watcher keep its tail across failed listings and re-list every 10 s, so the line now usually arrives, late: Teams' own delay in writing it plus the polling interval. The `lifecycle_teardown_consult` and `call_teardown_line` rows END16 added will show the split on the owner's laptop.

What a clean leave looks like in the field (reliability audit, [evidence](../../audits/2026-11-13-recording-reliability-evidence.md), and the [post-audit fix review](../../audits/2026-11-17-post-audit-fix-review.md) incident replay): the call window reads gone 0.2 to 0.4 s before the microphone release, and the Leave button reads invalid within about 2.6 s of it. So within about 3 s all three live readings agree. What the long dwell exists for is the other shape: a microphone release alone, with Leave and window still live (a headphone or device switch; the pack holds two such gaps near 23 s that reverted).

The cost of the wait is the wait itself and a later pipeline start. The transcript is not affected, because [END21](./END21.md) cuts at the microphone release.

## Scope

1. `PromotionEngine`: a third confirm rule beside the pair and the lone dwell. Inside a hold, when process audio has a fresh ended edge (the release), and both members of the call-window class (`axLeaveButton` invalid and the window signal gone) have fresh ended edges that no class-mate contradicts, confirm after `agreementDwell`, proposed 5 s, measured from the latest of the three edges in awake time (END22's clock). Evidence string `full_agreement` in `confirmed_by`, so the route is countable.
2. Only for adapters that publish all three readings (Teams and Zoom natives). Browsers, Webex and Slack keep today's rules.
3. Nothing else moves: a microphone release with Leave or window still live keeps the 60 s pair and the END29 refusal; a returning live reading inside `agreementDwell` reverts the hold exactly as today; the teardown line still confirms at once when it arrives first; the cut stays END21's.
4. Log one `lifecycle_end_held` field `agreement_dwell_sec` when the rule arms, so a field read can tell the three routes apart.

## Explicitly not

- Lowering `defaultConfirmDwell`. The 60 s pair protects the mic-only release and stays.
- Ending on two of the three. A minimised or relocked window (END24) or an unreadable Leave button falls back to the existing routes; that is the safe direction.
- Removing the teardown oracle or its watcher. END16 owns whether that route earns its keep once this lands; the `full_agreement` count against the teardown count is the evidence for that decision.
- A real network drop where all three flip and the call comes back: with this rule the recording ends after 5 s and END17's resume links the second part when the call is sighted again inside the resume window. That trade is accepted here and stated in GUIDE.

## Acceptance

- `PromotionEngineTests`: all three edges inside 3 s confirm at the latest edge plus `agreementDwell` with `full_agreement`; a release with Leave live does not (still the 60 s pair); a release with the window still present does not; a live reading returning at 4 s reverts; a wake inside the dwell needs a fresh reading (END22's gate). 5 new tests, each failing on the engine before the change where it asserts the early confirm.
- One corpus trace of a clean Teams leave from the owner's log (the extraction is owner-owed; a synthetic trace labelled as such until then) replays to an end within 10 s of the release.
- The session test for the HUD: "Confirming end" clears on the `full_agreement` end and the pipeline is queued.
- `cd daemon && swift test` green; `python3 scripts/truth_fences.py both` green with the new attribute; ADR 0017 gets a dated amendment and `docs/GUIDE.md` the one sentence on a dropped call, in the same commit.

## Owner walkthrough

1. [session] Before building, read the owner's latest `events.jsonl` rows `lifecycle_teardown_consult` and `call_teardown_line` for five recent Teams ends and record how long each hold ran and which route confirmed it. This is the baseline and tests the 10 to 30 s inference above.
2. [owner] Rebuild between meetings and make five ordinary Teams calls, leaving each normally.
3. [session] Pass: at least four of five ends carry `full_agreement` and conclude within 10 s of the microphone release, and none of the five recordings ends while the call is still up. One early end on a live call is a fail, and the rule is reverted, not tuned.
4. [owner] During one further call, switch headphones mid-call. Pass: the recording does not end.
