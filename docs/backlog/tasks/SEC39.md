---
id: SEC39
title: A workflow picked for one meeting outranks the next meeting's rule match: a skipped prompt's pick stays armed, and resume-after-end pins the previous recording's workflow
category: Security
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). pendingWorkflowOverride is cleared only by a committed start, so a prompt's chip pick survives Skip, timeout, an end during the prompt and force-stop and wins the next start's matcher over its rule and NDA flag (F005); resume-after-end sets the same override from the previous recording (F046), seen once in the field on 2026-11-12 (stem 20261112-174606, 38.6 s after the previous end, no prompt) with no routing harm only because one workflow exists; promote before enabling regulated or NDA. Clear the pick on every prompt exit and key it to the prompt's source; on resume let a rule match win and never resume into a weaker privacy posture.
---

# SEC39: A workflow picked for one meeting outranks the next meeting's rule match: a skipped prompt's pick stays armed, and resume-after-end pins the previous recording's workflow

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Sources: F005 (high, confirmed by both verifiers) and F046 (high, partially confirmed) in the [2026-11-12 independent audit](../../audits/2026-11-12-independent-audit.md), whose summary groups them under "Privacy state leaks across meetings"; the "F046 in the field" row of the [field evidence](../../audits/2026-11-13-field-evidence.md) (class key daemon-health-and-audit-crosscheck#3). Code re-read at HEAD 3a2da4fc on 2026-11-13.

**The override.** `MeetingSessionController.pendingWorkflowOverride` is documented as "consumed by the next `beginRecording`. Highest matcher precedence, so it wins over rule matches", and `WorkflowMatcher.resolve` returns it before any rule scoring (`if let id = overrideID, let wf = workflows.first(where: { $0.id == id }) { return wf }`). Its writers: `setPendingWorkflowOverride`, called only from `Coordinator`'s `meetingPrompt(_:didChooseWorkflow:)` (the prompt's workflow chip menu and AI9's Undo); the clear inside `beginRecording`; and the resume branch of `handleMeetingStarted`. The resolved workflow drives `CaptureMode.resolve(... nda: resolvedWorkflow?.flags.ndaMode ...)` and the meta sidecar's `workflow_nda_mode`, `workflow_backend` and `workflow_sinks`, which `mp.workflow.apply_overrides` applies.

**F005: a pick that was not recorded stays armed.** `beginRecording` clears it with `pendingWorkflowOverride = nil` only after three early returns (a start already in flight, no microphone permission, dry run), and nothing else clears it. Skip (`notifier(_:didChooseSkip:)` calls only `stateMachine.abandonPrompt`), the timeout's skip branch in `startPromptTimeout`, `handleMeetingEndedDuringPrompt`, and `forceStop` on `.prompting` all leave it set. It then decides the next committed start in any app: an auto-consented meeting (`handleMeetingStarted` calls `beginRecording` with no prompt), a timeout-record, or a manual hotkey start with no source. Before that, `workflowForPrompt` resolves the next prompt's chip through it, so the stale pick is shown as that prompt's selection. The value lives in memory, so a daemon restart clears it. The code knows: the `preselectedRoutingHint` doc says "`pendingWorkflowOverride` is only cleared by a start, and this deliberately does not inherit that", and the AI9 hint is keyed to its source for exactly that reason; the `beginRecording` comment "Both are cleared so neither can leak into the next meeting" is wrong for the override. `MeetingSessionControllerBranchTests` pins only the clear on start.

**F046: resume pins the previous workflow.** END17's resume branch (`if let candidate = resumeCandidate, candidate.applies(to: source.bundleID, at: Date())`) sets `pendingWorkflowOverride = candidate.workflowID` and calls `beginRecording` with no prompt. `ResumeAfterEnd` is armed on every sourced lifecycle end, definitive ones included, with `windowSec = 120`. Recording a same-app call without a prompt inside that window is accepted design (ADR 0017's "The way back", README, the `ResumeAfterEnd` doc, which says a genuine back-to-back call "is recorded too"). What nobody weighed is the routing: the pin outranks the new call's own rule match, with no NDA floor, where AI9's hint refuses exactly that downgrade (`WorkflowRoutingHint`, `downgradesPrivacy = (matched?.flags.ndaMode ?? false) && !workflow.flags.ndaMode`).

**Field evidence.** On 2026-11-12, recording 20261112-172307 ended at 15:45:27.963Z (`ax_leave_button_invalid` and `shareable_content_window_gone` after the 60 s dwell). At 15:46:06.606Z `recording_resumed_after_end` (`since_end_sec` 38.64) started 20261112-174606 with no `prompt_shown` row; its meta carries `resumed_from`. The first recording had 14 speakers and 129 segments, the second 5 speakers and 29 segments with speech from 0.08 s, so it reads as a new call. One of the 6 recordings of the newest build's first 22 hours. No routing harm, because every one of the 113 meetings in the pack shares one workflow (nda false). F005 left no field trace for the same reason.

**Correction at filing.** The F005 failure scenario in the audit has the user pick "in the prompt chevron"; the verifier corrected it to the workflow chip menu, which is what `didChooseWorkflow` serves; the chevron carries BYO, Always and Skip. Global regulated mode still clamps independently of the override (`CaptureMode.resolve(regulated: ...)` and the sidecar's `regulated_mode`), so the egress risk is for meetings relying on a per-workflow NDA flag; with two or more non-NDA workflows the harm is wrong sinks and context, not egress.

**Priority.** P2: the owner runs one workflow and no NDA meeting, so the routing harm is latent. Promote before NDA workflows (or regulated routing that depends on a workflow) are used.

## Scope

1. **Clear the pick on every prompt exit.** One `clearPromptRouting()` on `MeetingSessionController` that nils `pendingWorkflowOverride` and `preselectedRoutingHint`, called from the Skip path (`notifier(_:didChooseSkip:)`), the timeout's skip branch, `handleMeetingEndedDuringPrompt`, `forceStop` on `.prompting`, and at the top of a new prompt's present in `handleMeetingStarted` before `workflowForPrompt` runs.
2. **Key the pick to its prompt's source.** `pendingWorkflowOverride` becomes `(source: AppSource, workflowID: UUID)?`, set from the current `.prompting` source in `meetingPrompt(_:didChooseWorkflow:)` (ignored when no prompt is up), and consumed in `beginRecording` only when `source` matches, as `preselectedRoutingHint` already is. A manual start with no source never consumes it. Fix the `beginRecording` comment.
3. **Resume re-runs the matcher.** The resume branch stops writing the override and hands `candidate.workflowID` to `beginRecording` as a separate resume input. There, with `matched` the matcher's answer with no override: if a rule matched, use it; otherwise use the previous workflow, unless `matched` (the default) is NDA and the previous is not, in which case use `matched`. A deleted previous workflow falls to `matched`. This needs `WorkflowMatcher` to say whether a rule matched; coordinate with [SEC21](./SEC21.md), which plans a matcher that returns a reason, and take its shape if it has landed.
4. **Log the routing.** `recording_resumed_after_end` gains `workflow_source` (`rule`, `previous` or `nda_floor`) and `workflow_changed` (bool). Clearing a pick that was never recorded emits `workflow` / `override_discarded` with `bundle_id` and `exit` (`skip`, `timeout`, `ended`, `force_stop`, `new_prompt`).

## Explicitly not

- Whether a resume should prompt, or apply only after a weak, unconfirmed end (the field audit's recommendation): END17 and ADR 0017 accepted the promptless resume, and narrowing it is an owner decision for [END17](./END17.md)'s walkthrough. This task keeps the resume and fixes its routing.
- The resumed recording that could not end because its engine had already ended during bring-up (380 s until stopped by hand): [END20](./END20.md).
- NDA classification when the title is unknown at record start or a rule regex does not compile: [SEC21](./SEC21.md).
- Moving the prompt routing state out of the controller as part of the seam work: [ARCH7](./ARCH7.md). This task changes the state's lifetime, not its owner.
- A visible resume notice with an undo (the audit's "consider"): a UX question, not filed here.
- FEAT9's merge offer for a resumed pair whose workflows now differ: `MeetingMergeEligibility`'s posture check already decides that, and refusing a cross-posture merge is the right answer.

## Acceptance

- `MeetingSessionController` tests with the existing fake host, one per exit: a chip pick followed by Skip, by the timeout's skip, by an end during the prompt, and by `forceStop` each leaves `pendingWorkflowOverride` nil, and a following auto-consented start of an app whose rule maps to another workflow records under that rule's workflow.
- A test that a pick made on one prompt is not shown as the next prompt's chip (`workflowForPrompt`) for a different source, and that a manual start with no source after an unrecorded pick resolves to the default.
- A test that a pick followed by Record still records under the pick (the existing clear-on-start test keeps passing).
- `HeldEndSessionTests`: a resume where a rule maps the new call to an NDA workflow records under the NDA workflow with `.regulatedGate` capture and `workflow_nda_mode` true in the sidecar; a resume with no rule match keeps the previous workflow; a resume after an NDA recording where the default is not NDA keeps NDA; `recording_resumed_after_end` carries `workflow_source`. The existing resume tests keep passing.
- `cd daemon && swift test` green with the number of new tests in the commit body; `python3 scripts/truth_fences.py events` green for `override_discarded`; `bash scripts/ci-local.sh` green.
- Same commit: `docs/GUIDE.md`'s back-to-back paragraph (today "starts recording again straight away, without asking, under the same workflow") and its list of how a workflow is chosen ("You picked one from the chip on the prompt panel") state that a pick applies only to the meeting it was made for and that a resumed call follows its own rule first; README's "A doubtful end keeps recording" bullet gains the same clause if it names the workflow.
