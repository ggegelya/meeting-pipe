---
id: SEC33
title: Ask's suggestion chips and empty state ignore the visibility gate mp ask enforces, so a withheld meeting's title can be sent to a cloud backend
category: Security
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). G037: `mp ask` drops NDA, regulated and sidecar-less stems through `visibility.visible_stems`, but `AskView` builds its chips from the newest Library rows unfiltered, so one click puts a withheld meeting's title or workflow name into a question sent to the configured backend; latent here (no NDA or regulated sidecar among the 113 field meetings), the NDA and regulated legs need those modes, the sidecar-less leg does not. Derive chips and the invitation's count from visible rows only, add a sidecar-present fact to `Meeting`, and say when meetings are withheld instead of "No meetings to search yet.". [Spec](./SEC33.md)
---

# SEC33: Ask's suggestion chips and empty state ignore the visibility gate mp ask enforces, so a withheld meeting's title can be sent to a cloud backend

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Source: [independent audit](../../audits/2026-11-12-independent-audit.md) finding G037 (security lens, confirmed). Re-read at HEAD `3a2da4fc`.

**What `mp ask` enforces.** `ask.py` computes `allow = visibility.visible_stems(Path(root))` before the index is built ("AUTO3 leg 0. Computed before the index so a withheld meeting is never chunked, never embedded, and never a retrieval candidate"). `visibility.withheld_reason` withholds a stem for `no_sidecar` (no `<stem>.meta.json`), `nda` (`workflow_nda_mode`) and `regulated` (`regulated_mode`). The corpus rule is "withheld meetings are not in this corpus", applied unconditionally, put to the owner 2026-08-18 (AUTO3, owner-verify).

**What the pane does.** `AskView.pane` calls `AskPane.derive(... recentWorkflow: recentWorkflow, recentTitle: meetingStore.meetings.first?.displayTitle, meetingCount: meetingStore.meetings.count)`, and `recentWorkflow` is `meetingStore.meetings.prefix(20).compactMap(\.workflowName).first`. Neither looks at the row's posture. `AskPane.suggestions` turns them into `"What did we decide in \(workflow) recently?"` and `"What came out of \(clip(title))?"`, and a chip's button is `askModel.ask(suggestion.text)`, so the text becomes the question `mp ask` sends to whichever backend it resolves. `Meeting.displayTitle` prefers `summaryTitle`, which for a withheld meeting is a title the model wrote from its transcript. With global regulated mode off, a newest meeting recorded under an NDA workflow puts its summary title into a chip, and one click sends that title to the cloud backend while the answer itself can only cite other meetings. The workflow chip does the same with an NDA workflow's name. UX38 (done, [q6-final.md](../q6-final.md)) built the chips off the newest rows without this gate.

**The empty state.** `AskPane.derive` says "No meetings recorded yet." only when `meetingCount == 0`, counting every row. When every row is withheld, `mp ask` builds an empty index and returns `_empty_answer` ("No searchable meetings found.", `empty=True`), which `AskView.outcome` renders as "No meetings to search yet.", false for a library that holds meetings.

**Correction at filing:** the all-withheld leg is a copy defect, not egress. `ask.py` returns `emit(_empty_answer(question), 0)` at `if not index.chunks` before any backend call, so a chip's text reaches a backend only when at least one other meeting is visible. The egress leg needs one visible meeting plus a withheld newest row (or a withheld meeting among the newest twenty for the workflow chip).

**Correction at filing:** `Meeting` carries no "sidecar present" fact. `Meeting.isZeroEgress` is `(workflowNDAMode ?? false) || (regulatedMode ?? false) || metaUnreadable`, which is false for an absent sidecar, while Python withholds that stem as `no_sidecar`. So filtering on `isZeroEgress` alone, the audit's direction, would still let a sidecar-less meeting's title through. `MeetingStore`'s row build already has the read (`let metaRead = metaURL.map { MeetingMetaRead.load(at: $0) }`) and can record whether it was `.absent`.

**Field evidence.** None for this class on this Mac: `workflow_nda_mode` is false on 113 of 113 metas in the [field pack](../../audits/2026-11-13-field-evidence.md) and the newest meetings carry sidecars. The same pack records `mcp_serve_started.withheld = 41` on all 2,950 MCP server starts, so 41 meetings are withheld library-wide on this Mac by the same gate. The pack does not split the reason; [AUTO3](./AUTO3.md) split the same 41 on 2026-08-18 as `nda` 2 and `no_sidecar` 39, all older than the 113 meetings the pack covers, so none of them is the newest row today and the egress leg has not fired here.

## Scope

1. **One sidecar-present fact on the row.** Add `hasMetaSidecar` (or equivalent) to `Meeting`, set in `MeetingStore`'s row build from `metaRead` not being `.absent`, defaulted so test constructors need not supply it. A row is Ask-visible when it has a sidecar and `isZeroEgress` is false, mirroring `visibility.withheld_reason` (absent is `no_sidecar`, unreadable is already zero-egress per SEC25).
2. **Chips and count from visible rows only.** In `AskView` (or a small pure helper on `AskPane` that takes `[Meeting]`, so it is testable without a view), derive `recentTitle` from the newest Ask-visible row, `recentWorkflow` from the newest twenty Ask-visible rows, and `meetingCount` from the Ask-visible count. A withheld row never contributes text to a suggestion.
3. **Say when meetings are withheld.** `AskPane.derive` takes the withheld count. With rows present and none visible, the subhead says so plainly (for example "Your N meetings are kept out of Ask because of their privacy settings.") instead of "No meetings recorded yet.", and offers no library-derived chips. With some withheld, the centred invitation may note the count in one line. `AskView.outcome`'s `answer.empty` row uses the same wording when the library has rows, rather than "No meetings to search yet.". Read [docs/GUIDE.md](../../GUIDE.md) before writing the copy so the two agree.

## Explicitly not

- Changing what `mp ask` or the MCP server withholds, or the global-regulated gap in MCP: [AUTO6](./AUTO6.md). One bad sidecar crashing the gate: [PIPE29](./PIPE29.md).
- Gating the question text the user types: the user's own words are theirs to send.
- Proving no reader leaks a withheld meeting in general: the canary fence in [AUTO9](./AUTO9.md) and the kernel-level spike in [SEC32](./SEC32.md). This task fixes one known reader.
- Cmd+K search and the Library list: those stay on-device and are not egress.

## Acceptance

- `AskPaneTests` (or a new test beside them): a library whose newest row is NDA offers no chip naming that row's title or workflow and takes the title from the newest visible row; a newest row with no sidecar is skipped the same way; a newest row with a regulated sidecar is skipped; an unreadable-sidecar row is skipped; a library where every row is withheld shows the withheld wording, not "No meetings recorded yet.", and offers only the library-independent chip or none; an all-visible library keeps today's chips unchanged.
- A `MeetingStore` test (existing scan fixture) that a stem with no `<stem>.meta.json` gets `hasMetaSidecar == false` and one with a sidecar gets `true`.
- `swift test` green with the new test count in the commit body; `bash scripts/ci-local.sh` green.
- [docs/GUIDE.md](../../GUIDE.md)'s Ask recipe mentions that withheld meetings are left out of Ask and its suggestions, in the same commit, if it describes the suggestions at all.
