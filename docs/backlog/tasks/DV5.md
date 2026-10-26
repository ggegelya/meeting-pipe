---
id: DV5
title: Research what the Facts rail should become, or whether it should exist
category: Intelligence
status: partial
priority: P2
comment: Filed 2026-08-10 at the owner's request from their 2026-08-04 notes: "facts is barely useful, just endless list with all action items, makes not so many sense ... perhaps we can make some 'dashboard' or 'insights' instead ... or remove it. research it". Follow-on to DV1. Measured over their 226 summaries on 2026-08-10 so the pickup starts from numbers: 1374 actions of which **16 are resolved (1.2%)**, 1358 open, **75% carry an owner but only 4% carry a due date**, 309 decisions, median 6 open actions per meeting. The daemon's own `action_clusters_built` collapses 1300 actions to 838 clusters, so the list is largely repetition. Two readings follow. A backlog closing 1.2% of its items is not a list anyone works from, which makes **Remove a serious candidate rather than a rhetorical one**; and 4% date coverage means **no time-shaped view is buildable at all** (no burndown, overdue chart, or velocity), which is the most useful thing the measurement rules out and should stop a plausible dashboard proposal before it is designed. Owners at 75% and the denser decisions corpus are what remains. Scope is a research pass ending in a named Reshape / Replace / Remove recommendation, probe-first via `/spike DV5` with thresholds pre-registered, **not** a licence to build a dashboard. It must first get the owner's real questions in their own words (the rail's failure is that it answers "what open items exist" and nobody asked that), clarify what "move as separate tab -> research" meant, and say what any proposal adds beyond the shipped People (DV3), Meeting time (AI8) and `mp ask` surfaces. Standing constraints: AI5's classifier NO-GO, AI9's corrections-based shape, the AI/DV egress rule, the de-CLI rule. Explicitly not backfilling due dates (4% is how people talk, not a data bug), not AI7 or AI10, and not using AI8's current numbers as input since UX74 is an open defect in them. **Measurement half done 2026-08-19, recommendation blocked on the owner by the spec's own design.** Analysis at [`../spikes/dv5-facts-rail.md`](../../spikes/dv5-facts-rail.md), with the reproduce command recorded and checked to actually run. Corpus re-measured at 249 summaries (226 at filing). **Two findings move the task before any design exists.** First, the resolution rate is not low, it is zero: resolved is still exactly 16 across a corpus that gained 150 open actions in nine days, so the mark-done control was used zero times over the window rather than 1.2% of the time. Second, and this corrects the spec itself: the filed table's "75% of open actions have an owner" counts string presence, not people. Measured by content, 570 of the 1126 owned open actions are diarization artifacts (357 bare numbers, 127 `THEM-*`, 86 `Speaker N`), so only **556, 36.9%, name a human**. The one field the spec offered as a foundation is half what it credits. Two fields were never measured at filing and are now: 746 open questions (the largest unsurfaced corpus, against 327 decisions), and `group` persisted on 0% of actions, since AI7's clustering is computed at read time. **The survey closes off both obvious reshapes in advance:** anything time-shaped fails on 4.6% date coverage as filed, and anything owner-shaped both fails the field floor and duplicates People (DV3), which already renders per-person open commitments off the same `[ActionCluster]` Facts renders. Verdict thresholds T1 to T5 are pre-registered in the doc, written while the owner's answers were still unknown so they cannot be tuned to the answer, and Remove is the default when nothing survives them. On today's corpus only the action text, `resolved`, decisions and open questions clear the T1 floor, so a Reshape would be about decisions or questions rather than about actions, which is the opposite of what the rail does now. Also added the measured finding to `pipeline/docs/gotchas.md`, since `Facts.swift` renders `action.owner` verbatim while `PeopleRail` matches it against enrolled names and degrades safely. **Blocked on the owner:** walkthrough step 1's two questions (what would you ask of 249 meetings, in your words; and what "facts move as separate tab" meant), which the spec says cannot be derived or guessed. Not owner-verification, so the row stays here rather than moving.
---

# DV5: research what the Facts rail should become, or whether it should exist

Band origin: filed 2026-08-10 from the owner's 2026-08-04 testing notes: "facts move as separate tab -> research. facts is barely useful, just endless list with all action items, makes not so many sense. we need to research what we can do here to make it more interesting. perhaps we can make some 'dashboard' or 'insights' instead, and do some graphs, charts, and more useful stuff for analytics. or remove it. research it". Follow-on to DV1 (shipped in Q5), which built the rail. Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## The measurement that makes the complaint concrete

Taken over the owner's 226 meeting summaries on 2026-08-10, so the pickup starts from numbers rather than from the impression:

| | Count | Note |
|---|---|---|
| Actions, all | 1374 | |
| Actions **resolved** | **16** | 1.2%. The mark-done control DV1 shipped has been used sixteen times in the corpus's life. |
| Actions open | 1358 | This is the "endless list". |
| Open with an owner | 1023 | **75%** |
| Open with a due date | **62** | **4%** |
| Decisions, all | 309 | A quarter the volume of actions. |
| Open actions per meeting | median 6, max 26 | |

The daemon's own clustering agrees the list is mostly repetition: `action_clusters_built` on 2026-08-04 reports **1300 actions collapsing to 838 clusters**, and the 2026-08-03 digest footer says "1242 open action(s) library-wide; the rest are dormant (undated, from before this window)".

Read together, those numbers say something sharper than "it is long". A backlog where 1.2% of items are ever closed is not a task list anyone is working from, and 4% date coverage means **any time-shaped view is not buildable on this data**: no burndown, no overdue chart, no velocity, no "this week" trend. That is the single most useful thing this measurement rules out, and it should stop a plausible-looking dashboard proposal before it is designed.

What the data does support: owners are present on three quarters of open actions, and decisions are a smaller, denser corpus than actions. Whether either is worth a view is the research question, not a foregone conclusion.

## What this task is

A research pass that ends in a **named recommendation the owner accepts or rejects**, with the option to recommend deletion. It is not a licence to build a dashboard. `/spike DV5` is the natural pickup: probe first, verdict thresholds pre-registered before any design work, and a NO-GO that closes the line is an acceptable outcome.

The three outcomes the owner named, all legitimate:

1. **Reshape.** Facts stays and becomes something denser than a list.
2. **Replace.** Facts goes, an insights or dashboard surface takes its slot.
3. **Remove.** Facts goes and nothing replaces it. The rail loses a row and the product loses nothing anyone was using, which the 16-resolutions number makes a serious candidate rather than a rhetorical one.

The owner also floated a fourth thing separately: "facts move as separate tab -> research". Establish what that means before designing to it, since it could be a relocation of the existing rail or a new cross-meeting research surface, and those are very different tasks. Ask rather than guess.

## What the research must establish, before proposing anything

- **What the owner actually wants to answer.** The rail's failure is that it answers "what open items exist" and nobody asked that. Get two or three real questions they would ask of 226 meetings, in their words, and let those select the view. This is the step that decides the task, and it cannot be derived from the corpus.
- **Which of those questions the data can answer at all.** Apply the date-coverage finding above as a hard filter, and check the other fields the same way rather than assuming they are populated. A view that needs a field which is 4% covered is a NO-GO for that view, not a reason to backfill the field.
- **What already exists**, so this does not rebuild a shipped surface with a new name. The INSIGHTS section already carries several projections, and three are directly adjacent: **People** (DV3, shipped 2026-07-24, on owner enrollment), **Meeting time** (AI8, hours per workflow, and note UX74 is an open correctness defect in its numbers, so do not read its current figures as truth), and the **action clustering** behind AI7. A proposal must say what it adds beyond these.
- **Whether `mp ask` already covers it.** Ask is the working cross-meeting answer surface, and "the owner asks a question in prose" may simply be the better shape than any fixed chart. If so, the recommendation is Remove plus a pointer, which is a cheap and honest result.

## Standing constraints the research must not walk into

- **AI5's NO-GO is the standing answer for anything tempted to reach for a classifier here.** Its labels agreed on 1 of 10 meeting types across 193 real meetings. AI9 is the shape that works instead and is worth reading first: it labels off the user's own explicit corrections, and its rule is a count with a threshold, because a single-user product accumulates a handful of labels per quarter and nothing more sophisticated has anything to train on.
- **The AI/DV standing rule.** Any new capability that calls an engine routes through the local engine path so `egress_guard` clamps it under regulated and NDA, honours `effective_backend()`, and adds no new always-on egress.
- **The de-CLI rule.** `mp actions --open` existing is not a substitute for a UI. If a capability ships, its affordance ships in the same task.
- **Charts, if any, follow the repo's own visual system**, `design/colors_and_type.css` and `design/README.md`, and clear the DSN3 floor (4.5:1 contrast, Dynamic Type, no new `.system(size:)` literals). "Graphs and charts" is the owner's shorthand for "denser than a list", not a specification.

## Explicitly not / out of scope

**Not building a dashboard on spec.** The deliverable of this task is a recommendation. Anything built here is built to answer the research question, not to ship.

**Not backfilling due dates.** 4% coverage is a property of how people talk in meetings, not a data-quality bug to fix so a chart becomes possible. Extracting dates more aggressively would mean inventing them.

**Not AI7's clustering or AI10's digest bounding.** Both shipped and both are working; the 1300-to-838 number is cited as evidence about the corpus, not as a defect.

**Not UX75.** That is the digest's action groups rendering blank, filed the same day from the same notes. It makes the digest show what it already computes and takes no position on whether that content is worth showing. Fix it first regardless of what DV5 concludes.

**Not UX74.** The Meeting time rail's arithmetic defect is its own row. Do not use its current numbers as input to this research.

**Not removing the mark-done control** if Facts survives in any form. 16 resolutions is evidence about the view, not about the affordance.

## Acceptance

This is a research task, so the bar is on the artifact and the decision, not on tests.

- A written analysis under `docs/spikes/` recording: the owner's stated questions in their words, which of them the corpus can and cannot answer with the field coverage measured, what the three adjacent shipped surfaces already cover, and a single named recommendation of Reshape, Replace, or Remove.
- Verdict thresholds pre-registered **before** any design work, per `/spike`, so the recommendation is a reading of criteria rather than a preference stated afterwards.
- Every quantitative claim in it is a measurement over the real library with the command that produced it recorded, so the next session can re-run rather than re-derive. The table at the top of this file is the starting set and should be re-measured at pickup, since the corpus grows.
- If the recommendation is Remove, it says explicitly what is lost and where those items remain reachable (`mp actions --open`, the digest, Ask), so the owner can weigh it.
- If the recommendation is Reshape or Replace, it names the follow-on task's scope tightly enough to file with `/file-task` without a second research pass, and it says which questions the new view answers that People, Meeting time and Ask do not.
- No em-dashes; no hard-wrapped prose; absolute dates.

## Owner walkthrough (for the session that picks this up)

Per the 2026-07-30 standing rule. Steps are tagged [owner] / [session] by who acts. The first step is the one the task turns on, and it cannot be skipped or guessed.

1. [owner] Answer two questions in your own words, before any design exists. First: what would you actually want to ask of 226 meetings, if the app could answer anything? Give two or three real examples, not categories. Second: what did you mean by "facts move as separate tab -> research", is that moving the existing rail somewhere else, or a new surface for asking across meetings?
2. [session] Measure whether the corpus can answer each of those, and re-run the field-coverage table above against the current library.
3. [owner] Open the existing People and Meeting time rails and say, for each, whether it already answers one of your questions. A recommendation that duplicates a shipped rail is worse than Remove.
4. [session] Pre-register the verdict thresholds, then write the analysis and the named recommendation.
5. [owner] Accept or reject the recommendation. **Remove is a real option and choosing it closes the line**; say so plainly if that is the answer, and the session deletes the rail rather than reshaping it out of reluctance.
