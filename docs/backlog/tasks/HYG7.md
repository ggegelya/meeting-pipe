# HYG7: END9 is a live P1 spec whose citations point at a file ARCH6 deleted, and at seven other places in code they no longer describe

Band origin: filed 2026-08-18 from the ten-task batch that landed the same day (`20e66c7` through `b122e00`). ARCH6 found the first half and deliberately did not fix it, because END9 might have been live in the same batch. Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Why this is P1

[`END9`](END9.md) is **P1 and `new`**: nobody has started it, so the next session to pick it up reads this spec cold and navigates by its citations. Every defect below is in the map rather than the territory, and a pickup that follows a citation into unrelated code has no way to tell a stale reference from a wrong analysis. That false start is precisely what HYG6 existed to prevent, four days after HYG6 swept it. The owner may re-band (the DIAR2 precedent); the case for P1 is the combination of an unstarted P1 spec and a citation set that is now mostly wrong, not the size of the edit, which is small.

## Half one: the deleted file

ARCH6 (`bd32468`, 2026-08-18) deleted `daemon/Sources/MeetingPipe/PromptEndPolicy.swift` and `daemon/Tests/MeetingPipeTests/PromptEndPolicyTests.swift`. It traced all five `EndingReason` constructions first and confirmed no reachable `.ended` can carry `leadingSignal == ax_leave_button_invalid` with an empty `confirmedBy`, so `clearsPromptState` had returned true for every end since START1. The evidence is in `daemon/docs/gotchas.md` under "Three more shapes ARCH6 removed", and both call sites now name the guard that really holds: `MeetingSessionController` records that "Both branches below used to be gated on `PromptEndPolicy.clearsPromptState`", and `DetectionStateMachine` that "`PromptEndPolicy` used to be named here as the filter; it was a second copy of" the same reasoning.

END9 names `PromptEndPolicy` in three places, and each fails differently:

**1. In the causal chain, step 4.** The clause "it appends `ax_leave_rewalk` to `confirmedBy`, which additionally launders the end past `PromptEndPolicy`" is a true observation about a mechanism that no longer has a second half. `PromotionEngine.confirmProvisionalEnd` still does exactly what the clause says (`confirmedBy.append(rewalkSignal)`, default `"ax_leave_rewalk"`, so a confirmed end can never carry an empty `confirmedBy`), which is *why* the filter was unreachable. The laundering is real; the thing it launders past is gone.

**2. In "Already refuted, do not re-derive".** The paragraph opens with a link, `[PromptEndPolicy.swift:7](../../../daemon/Sources/MeetingPipe/PromptEndPolicy.swift#L7)`, quoting the file's own comment as the place the folklore is asserted, and closes "Correcting that comment is in scope." This is the only broken relative link in END9.md, and the refutation it supports is still correct and still worth keeping: the live AX dump in `MeetingAXHandleBuilder` (the "What the dump showed, and why the old Leave anchor could never work" comment) contradicts the compact-window premise. Only the place the folklore lived has moved.

**3. In Scope, the grafts list.** The item "**Correct the `PromptEndPolicy` comment** so the refuted premise stops being restated as fact" is discharged. Deleting the file deleted the comment.

**The direction of travel is what makes this an amendment rather than a scope change**, and ARCH6 checked it explicitly: END9 makes confirmation **stricter** (it gates `confirmProvisionalEnd` on Teams' teardown oracle instead of confirming unconditionally on a second empty walk), so it cannot make a bare ax-leave `.ended` with an empty `confirmedBy` reachable again. Nothing in END9's fix is invalidated. Do not reopen that question; record the answer instead.

## Half two: seven line citations that now land on unrelated code

Not observed by ARCH6, measured for this filing on 2026-08-18 against `b122e00`. END9 was filed 2026-08-04; `MeetingSessionController.swift` has taken five commits since (DET7, DET9, REC9, REC10/REC11, REC13, ARCH6), and `PromotionEngine.swift` has moved too. Of END9's twelve non-`PromptEndPolicy` line citations, **seven now resolve to code that has nothing to do with the claim beside them**:

| END9 cites | Claimed to be | Actually at that line now | The symbol's real home |
|---|---|---|---|
| `MeetingSessionController.swift:1193` | `rescueProvisionalEnd` | a doc comment about the AX walk running off-main | `func rescueProvisionalEnd(context:)` at :1219 |
| `MeetingSessionController.swift:1200` | the `leaveButtons.first == nil` path, named as the fix's seam | `func armLifecycleLeaveButton(source:)`, a different function | inside `rescueProvisionalEnd`, after :1219 |
| `MeetingSessionController.swift:578` | `stopRecording` calling `coordinator.lifecycleCoord.disengage()` | `if degraded { return .interrupted }` | `func stopRecording(file:source:summaryMode:)` at :582, the `disengage()` at :590 |
| `MeetingSessionController.swift:1099-1124` | `handleDiscovery`, named as DET9's adjacency | `guard let self = self else { return }` | `func handleDiscovery(_:)` at :1129 |
| `MeetingSessionController.swift:1119-1123` | the `isCoolingDown` branch END9 inserts into | `walkQueue: Self.axWalkQueue` | inside `handleDiscovery`, after :1129 |
| `PromotionEngine.swift:221` | `confirmProvisionalEnd` | the middle of an unrelated comment | `public func confirmProvisionalEnd(rewalkSignal:)` at :246 |
| `PromotionEngine.swift:335` | END8's revert on a returning signal | `leading: PrimarySignalKind,`, a parameter | inside `handleEndingProvisional` |

Five still land close enough to read (`AXLeaveButtonSignal`'s invalid edge, `PromotionEngine.swift:207` on `tick()`'s doc one line above the declaration, both `MeetingAXHandleBuilder` citations, and `ConfigDefaults.swift:35` on `repromptCooldownSec`, which is exact). The drift is a consistent +25 to +30 lines in the two files that moved, which is the tell: nothing was deleted, the citations simply rotted, and a reader has no way to distinguish that from a wrong claim.

The worst of the seven is `MeetingSessionController.swift:1200`, because END9's Scope calls it "the seam is one branch" and points the whole fix at it. A pickup that opens that line finds a different function.

## Scope

Amend `docs/backlog/tasks/END9.md`. Nothing else.

**1. The three `PromptEndPolicy` places.** Rewrite the step-4 clause so it describes what `confirmProvisionalEnd` does without implying a downstream filter that exists. Repoint the folklore paragraph: the premise is still refuted and the refutation still matters, so keep it and cite where the folklore now lives (`daemon/docs/gotchas.md`'s ARCH6 section records both the premise and its refutation, and the two call-site comments name the real guard), with the deletion and its date stated so the next reader does not go looking for the file. Delete the discharged scope item, replacing it with one line saying ARCH6 discharged it on 2026-08-18, so the trail survives the removal.

**2. Re-resolve every citation to a symbol**, per the cite-by-symbol rule HYG6 added to `.claude/commands/file-task.md` on 2026-08-18: a type and function name plus a short quoted snippet, not `file.swift:174`. The seven above are the ones that must change; converting the five that still land is cheap and stops the next five commits recreating this task. A `file.swift:NNN` inside a **quotation of past state** stays legal when a date sits beside it, which is what the table above is.

**3. Record the direction-of-travel finding** in END9 itself, in one line, so the pickup does not re-derive whether ARCH6's deletion reopened anything.

## Explicitly not / out of scope

**END9's analysis, fix, constants, execution contract, acceptance and owner walkthrough.** None of them changes. The oracle, `teardownLookbackSec = 15`, `holdCapSec = 150`, the five grafts other than the discharged one, and the pre-registered A/B all stand exactly as filed. This task moves no engineering decision.

**Its band.** END9 stays P1 and `new`. Amending a spec is not starting it.

**Every other spec's citations.** [`HYG8`](HYG8.md) owns the archive and live-spec link sweep filed the same day, including the dead relative links in `AUTO1`, `CAL3`, `DET12`, `DIAR5` and `DOC13`. END9's single dead link is deliberately **not** HYG8's, because fixing it correctly requires the `PromptEndPolicy` reasoning above rather than a path repair, and repointing it as a path repair would preserve a claim about a deleted comment.

**A mechanical citation fence.** Tempting, and not this task: a checker that resolves `file.swift:NNN` against a symbol needs to parse Swift, and the cheaper half (a relative-link existence check) is in HYG8's scope. If HYG8 ships that fence, it catches END9's dead link too, which is a reason to land this first rather than to merge them.

## Acceptance

- `docs/backlog/tasks/END9.md` contains no reference to `PromptEndPolicy` that reads as a live filter, and no link to `daemon/Sources/MeetingPipe/PromptEndPolicy.swift`.
- Every remaining code citation in END9.md resolves: each named symbol exists in the named file, and each relative link's target exists on disk. Checkable by grepping each symbol and by resolving each relative link from `docs/backlog/tasks/`.
- The `PromotionEngine.confirmProvisionalEnd` and `rescueProvisionalEnd` citations are in symbol form, so the next five commits to those two files cannot rot them again.
- END9's Scope still names one seam and a reader can find it from the spec alone, without a grep the spec did not tell them to run.
- The discharged scope item is recorded as discharged, with ARCH6's date, rather than silently deleted.
- No code change and no test change: the diff touches `docs/backlog/` only. If the pickup finds itself editing Swift, stop and say why, because that is END9's work and not this task's.
- `python3 scripts/truth_fences.py both` green.
- No em-dashes in changed lines.

## Owner walkthrough (for the session that picks this up)

Per the 2026-07-30 standing rule. Steps are tagged [owner] / [session] by who acts.

There is nothing for the owner to observe: this is a document correction whose whole verification is that the citations resolve, and the acceptance above is mechanically checkable by the session.

1. [session] Land, then state which citations were re-resolved and confirm none of END9's engineering content moved.
2. [owner] Optional: confirm that P1 was the right band for a spec amendment, or re-band. The DIAR2 precedent is that the owner decides this and the filing session does not.
3. [owner] Say "HYG7 good to close" (or what is wrong); [session] moves the row and this spec into `q6-final.md` and deletes this file.
