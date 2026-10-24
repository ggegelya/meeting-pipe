# SEC21: NDA workflow classification fails open: a meeting whose title is not known yet, or whose rule regex does not compile, silently falls through to the default (non-NDA) workflow, and turning NDA on later does not cover past meetings

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([architecture review](../../audits/2026-10-24-architecture-review.md) S7). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Latent on the owner's Mac: all three workflows in `~/.config/meeting-pipe/workflows/` have `nda_mode = false` (checked 2026-10-24). It bites the first time anyone relies on an NDA workflow to catch a meeting by title.

`WorkflowMatcher.resolve` (pure, in `daemon/Sources/MeetingPipe/WorkflowMatcher.swift`) runs once, in `MeetingSessionController.beginRecording`, and its result fixes the capture mode (`CaptureMode.resolve(regulated:nda:redactMuted:)`), the sidecar's `workflow_nda_mode`, the backend and the sinks for that meeting. Re-read on 2026-10-24, each of these returns score 0 for an NDA rule and lets the default workflow win, with no trace:

- **Title not known yet.** `ruleScore` does `guard let title = source.meetingTitle, !title.isEmpty else { return 0 }`. A rule with both a bundle id and a title regex (score 3 when it matches) scores 0 when the title has not been scraped at record start, even though the bundle matched.
- **Invalid regex.** `titleMatches` is `guard let re = try? NSRegularExpression(...) else { return false }`. The Workflows editor (`WorkflowsView`, the `"title regex (optional)"` field) saves any string, and nothing validates it, so a typo makes the rule match nothing forever.
- **Manual recording.** `guard let source = source else { return 0 }`; expected and correct, listed so it is not mistaken for this bug.

And after the fact: `MeetingMetaSidecar` stamps `workflow_nda_mode` and `workflow_id` at record time. Switching a workflow to NDA later changes nothing for the meetings it already owns, so their sidecars still read `false`. Those meetings stay visible to `visibility.withheld_reason` (MCP, `mp ask`, `mp digest`) and a reprocess of one uses the cloud engine and the full sink list.

## Scope

1. **Say why the matcher chose.** `WorkflowMatcher.resolve` returns the workflow plus a reason: `.override`, `.matched(score)`, or `.fallback(undecided: [Workflow])`, where `undecided` lists NDA workflows that had a rule whose bundle id matched but whose title regex could not be evaluated (empty title or regex that does not compile). The function stays pure.
2. **Fail closed on undecided NDA.** In `beginRecording`, a fallback with a non-empty `undecided` list resolves the capture mode and the sidecar as NDA (the `.regulatedGate` capture, local backend, filesystem sink, which is what the NDA workflow would have done), stamps `workflow_nda_undecided: true` and the candidate's id in the sidecar, and logs an event. The Library row shows the meeting as NDA, and reassigning its workflow there (WF8's `reassignWorkflow`) is the existing way out. The alternative, holding every fallback meeting's summary for a confirm whenever any NDA workflow exists, was considered and is not the default: on a Mac with one NDA workflow it would gate most meetings; the owner can ask for it at pickup.
3. **Invalid regex is visible.** The Workflows editor validates the title regex on edit (compile it, show an inline error, refuse to save an uncompilable pattern), and `WorkflowInspector` flags an existing rule whose regex does not compile.
4. **Re-stamp on NDA turn-on.** When a workflow's `ndaMode` flips from false to true, offer once (a confirm sheet naming the count) to set `workflow_nda_mode = true` in the sidecar of every meeting whose `workflow_id` is that workflow. The sidecar writer is shared with the Swift/Python contract (CONVENTIONS.md sidecar schema), so the new key is added to both sides and `test_workflow_overlay.py`.

## Explicitly not

- Re-resolving the workflow mid-recording when the title arrives later. Capture mode is fixed at start by design (ADR 0016); scope item 2 is the start-time answer.
- What was already sent before NDA was turned on: a published summary cannot be recalled. The re-stamp covers what happens next.
- The routing editor's usability (bundle ids and regexes as raw text): UX88.
- MCP's global `regulated_mode` gap: AUTO6.

## Acceptance

- `WorkflowMatcherTests` gains: an NDA rule with bundle + regex and an empty title returns `.fallback` with that workflow in `undecided`; the same with an uncompilable regex; a non-NDA rule in the same situation is not listed; a matching title still returns `.matched(3)`; a manual recording (nil source) returns a plain `.fallback` with an empty list.
- A session test that an undecided fallback produces `.regulatedGate` capture and a sidecar with `workflow_nda_mode` true and `workflow_nda_undecided` true.
- A Workflows editor test (view-model level) that an uncompilable regex cannot be saved.
- A test that flipping a workflow to NDA and confirming rewrites exactly the sidecars carrying its `workflow_id`, atomically, and leaves others untouched.
- `test_workflow_overlay.py` covers the new sidecar key; the `CONVENTIONS.md` sidecar schema section gains the new key; `python3 scripts/truth_fences.py` clean.
- `swift test` and `pytest -q` green, new test counts in the commit body. GUIDE.md's workflow recipe mentions the undecided case in the same commit.
