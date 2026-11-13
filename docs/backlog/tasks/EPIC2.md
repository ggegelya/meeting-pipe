---
id: EPIC2
title: Epic: name a voice once and the archive resolves
category: Feature
status: new
priority: P2
comment: Umbrella, not a work item: pick a child. Filed 2026-11-13 (product-direction band): the owner's stated pain and, per the field data, the largest quality problem in the transcripts (352 of 712 attendees are THEM-x labels; the owner's own voice in a THEM-x cluster in 35 of 111 meetings is a separate defect filed with the audit band). Child DIAR10 (census spike, GO builds the name-once queue); the queue's writes wait on the audit's G003, G015 and F019 defects. Closed-set scorer is a later leg.
---

# EPIC2: epic, name a voice once and the archive resolves

Band origin: filed 2026-11-13 as the umbrella for the product-direction band's identity idea ([report](../../research/2026-11-12-product-direction.md): idea I36, picked by all three judges). Epics have no type in this backlog: this file is an umbrella, not a work item, and closes when every child is closed or parked. Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Thesis

One person talks to a small stable set of colleagues, and their own voice is always on one channel: that is what makes identity solvable here when it is not for a cloud vendor. [FEAT17](./FEAT17.md) measured that enrolment, not matching, is the bottleneck, so the move is from a click per meeting to a short ranked queue of recurring strangers, each named once and applied everywhere as a reversible overlay.

## Children

| Task | Idea | Priority | Depends on |
|---|---|---|---|
| [DIAR10](./DIAR10.md) | I36 census separability and clustering spike; GO builds the queue | P2 | The spike is read-only; the queue's fan-out writes wait on the audit's G003, G015 and F019 defects (being filed by the parallel 2026-11-13 audit filing) |

## Later legs, not filed

- A closed-set scorer over the named set with an explicit unknown class, fed by per-segment embeddings from the system channel alone, so the owner's speech never contaminates a colleague's print. Promote only on a [ASR7](./ASR7.md) win; the two-gate rule stays until then.
- Person pages as the Library's home (idea I39) stay parked in [EPIC6](./EPIC6.md) until the census reports.

## Related existing tasks (referenced, not edited)

[FEAT19](./FEAT19.md) (picker, merge, play sample, apply across meetings: the queue reuses them), [FEAT20](./FEAT20.md) (participant names, the NO-GO fallback), [DIAR6](./DIAR6.md) (owner identification per segment, feeds the MARGINAL leg), [SEC22](./SEC22.md) (voiceprint file modes and forget).

## Done when

The census spike has a recorded verdict, and on GO the queue has shipped with one-action undo of a fan-out, or on NO-GO names are routed to FEAT20.
