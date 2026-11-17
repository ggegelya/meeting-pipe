---
id: SEC40
title: A hand-picked NDA workflow is dropped on a resume and on a prompt that times out into the one-click offer
category: Security
status: new
priority: P2
comment: Filed 2026-11-17 (post-audit fix review). SEC39 (done) keyed the prompt's workflow pick to its meeting, but two routes still lose a stricter pick: `WorkflowMatcher.resumeWorkflow` returns the rule match whenever a rule matched, and the DET18 timeout calls `clearPromptRouting(exit: "timeout")` before leaving the offer. Scope: never resume weaker than a previous NDA workflow, and carry the pick into the offer for the same source. Reachable only with an NDA workflow: promote before enabling regulated or NDA.
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
