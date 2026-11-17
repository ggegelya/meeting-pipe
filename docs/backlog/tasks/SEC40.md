---
id: SEC40
title: A hand-picked NDA workflow is dropped on a resume and on a prompt that times out into the one-click offer
category: Security
status: partial
priority: P2
comment: Shipped 2026-11-17, both routes: `WorkflowMatcher.resumeWorkflow` keeps a previous NDA workflow over a non-NDA rule match (`workflow_source: previous_nda_floor`), and a prompt that times out into DET18's offer keeps its chip pick for that offer (`override_carried_to_offer`), kept in its own slot and discarded when the offer's span lapses or the offer is skipped; a pick weaker than the rule match is not carried. 3 matcher + 6 session tests (four carry tests and the new floor row red-first), GUIDE and CONVENTIONS updated, ci-local green. Nothing owed by a session; the owner closes it.
---

# SEC40: A hand-picked NDA workflow is dropped on a resume and on a prompt that times out into the one-click offer

Band origin: filed 2026-11-17 (post-audit fix review, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Found by the [post-audit fix review](../../audits/2026-11-17-post-audit-fix-review.md) (session report, M1 and M6), confirmed by reading the code at `78b72306`. SEC39 (done 2026-11-16) is not regressed: its guarantee that a pick cannot reach a different meeting holds. These are two routes it and DET18 did not weigh, and both lower the privacy posture of the same call the owner raised it for.

Route 1, resume. `WorkflowMatcher.resumeWorkflow(matched:reason:previous:)` opens with `if case .matched = reason { return (matched, "rule") }` and its NDA floor only ever raises: `if (matched?.flags.ndaMode ?? false) && !previous.flags.ndaMode { return (matched, "nda_floor") }`. Scenario: a rule maps the meeting app to a non-NDA workflow, the owner picks an NDA workflow on the prompt chip because this call is confidential, a weak end stops the recording, and the same call is sighted again inside the resume window. The second half records under the rule match with `workflow_source: rule`: lossless audio at rest and the rule's sinks.

Route 2, timeout into the offer. In `MeetingSessionController.startPromptTimeout`, the default branch runs `notePromptDismissed(source, reason: .timedOutToOffer)`, then `clearPromptRouting(exit: "timeout")`, then dismisses the panel and leaves DET18's one-click offer. The offer is the same call and the same source, but `pendingWorkflowOverride` and the AI9 `preselectedRoutingHint` are gone, so the offer's Record click goes through `recordAttached` and records under the rule match. The event `override_discarded` with `exit: timeout` records it. SEC39's progress note states the discard as a choice; its privacy cost was not weighed.

## Scope

1. `WorkflowMatcher.resumeWorkflow`: a floor in both directions. When `previous` has `ndaMode` and the rule match does not, keep `previous` and report a source such as `previous_nda_floor`.
2. `startPromptTimeout`: keep the pick for the offer, keyed to the offer's source the way SEC39 keys a prompt's pick to its meeting, and discard it when the offer lapses (`spanLapsed`) or the source changes. `recordAttached` consumes it.
3. Log both: the resume source above, and an `override_carried_to_offer` row.

## Explicitly not

- Changing which workflow a new, different call resolves to. SEC39's rule stands.
- Auto-recording on timeout. DET18 owns that default.

## Acceptance

- `WorkflowMatcherTests`: previous NDA plus a non-NDA rule match resumes under the previous workflow; previous non-NDA plus an NDA rule match still takes the rule (existing floor); no previous takes the match. 3 new tests.
- A session test: chip pick, prompt timeout, offer accepted for the same source records under the picked workflow; the same pick with the offer lapsed and a new call from another source does not carry. 2 new tests.
- `cd daemon && swift test` green; `bash scripts/ci-local.sh daemon` green; the two new event actions pass the truth fences.

**Progress (2026-11-17): shipped.** Route 1: `resumeWorkflow` returns `(previous, "previous_nda_floor")` when a rule matched, the previous workflow is NDA and the match is not; an NDA match over a non-NDA previous still takes the rule. Only `ndaMode` is floored: regulated mode is global, and `redactMutedSpans`, the one other per-workflow posture flag, is not floored (the spec names NDA only).

Route 2: the timeout's default branch takes the pick out before `clearPromptRouting(exit: "timeout")` (so no false `override_discarded`) and moves it to its own slot, `offerWorkflowOverride`, logging `override_carried_to_offer`. `recordAttached` (the offer's Record, Record BYO, Always, the menu row, the start-late notification) hands it to the start as the chip pick; any start of that source clears it; `noteHoldsEnded` discards it on `span_lapsed` and the offer's Skip on `offer_skipped`. Its own slot because the review found that reusing `pendingWorkflowOverride` let another app's prompt (`new_prompt`) or recording wipe the pick while the offer still lived.

Two decisions the spec did not make, both from the opus review:
- **A pick weaker than the rule match is not carried.** The offer, like SEC39's pick, is keyed by app (`AppSource` equality ignores the title), and the post-audit review records that a back-to-back call under about 3 s inherits the offer's hold; such a call would inherit the pick too. So a non-NDA pick over an NDA rule is discarded at the timeout (`exit: timeout`) and the offer records under the rule. Residual, accepted: a stricter pick can reach that back-to-back call, which over-protects it.
- **The routing state is consumed before `beginRecording`'s early returns** (no microphone, dry run). `recordAttached` clears the offer's latch first, so a refused start used to leave the pick armed with no offer left to lapse it, for the next start of that app, possibly hours later; SEC39's L3 (`pendingResumeWorkflow`) was the same shape and closes with it.

Deviation from scope item 2's wording: only the chip pick is carried, not AI9's `preselectedRoutingHint` (a suggestion the owner did not act on; the review's M6 is about the pick). Tests: SEC39's `test_aTimeout_discardsThePick` is replaced by six PromptRoutingTests (`test_aTimeout_carriesThePickIntoTheOffer_andTheOfferRecordsUnderIt`, `test_aCarriedPick_goesWithTheOffersSpan_andNeverReachesTheNextCall`, `test_aSkipOnTheOffer_discardsTheCarriedPick`, `test_aPickWeakerThanTheRuleMatch_isNotCarried`, `test_aCarriedPick_survivesAnotherAppsPrompt`, `test_aRefusedStartFromTheOffer_leavesNoPickArmed`); WorkflowMatcherTests gains the three resume rows the spec lists, of which only `test_resume_aPreviousNDAWorkflow_outranksANonNDARuleMatch` is red on the old matcher (the other two pin rows that already held). On the pre-fix controller the carry, span-lapse, offer-skip and another-app tests fail; the weaker-pick and refused-start tests pin this change's own decisions and pass there, since the old timeout dropped every pick. GUIDE's "How a meeting picks one" and the resume paragraph, CONVENTIONS and ARCHITECTURE updated. Nothing is owed by a session or a harness; the owner can close it (`done` is the owner's to set).
