---
id: EPIC4
title: Epic: subtract before adding, deleting the features where audit findings live instead of repairing them, and stop producing claims faster than one person can check them
category: Feature
status: new
priority: P1
comment: Umbrella, not a work item: pick a child. Filed 2026-11-13 (product-direction band): in two months all 74 recordings took one path and five of the 17 critical and high audit findings sit in features that could be deleted. Several children are alternative remedies to defect tasks filed in parallel, so decide each before repairing in place. Children MIC18 (P1, decides G001's remedy), FEAT22, PIPE39, DET16, HYG19, parked FEAT23, PIPE40, HYG20.
---

# EPIC4: epic, subtract before adding

Band origin: filed 2026-11-13 as the umbrella for the product-direction band's contrarian and process ideas ([report](../../research/2026-11-12-product-direction.md): ideas I41, I42, I43, I46, I47 as the judges' subtraction picks, plus I45, I06 and I33's internal half). Epics have no type in this backlog: this file is an umbrella, not a work item, and closes when every child is closed or parked. Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Thesis

The [field evidence](../../audits/2026-11-13-field-evidence.md) shows that from 2026-09-14 all 74 recordings took one path (on-device transcript, one cloud summary, one Obsidian note) with zero retries, regenerations, republishes, re-transcribes or summary edits. The 2026-11-12 [audit](../../audits/2026-11-12-independent-audit.md)'s critical (G001) and several highs (F004, F014, F017, F088) sit inside features that could be deleted. Deleting a feature retires its defects; repairing it first and deleting it later pays twice. And the process itself produces claims faster than one reviewer can witness them.

## Decide before repairing

The parallel 2026-11-13 audit filing is turning these findings into defect tasks. For each pair below, run this epic's child first; its verdict says whether the defect task becomes "deleted with the feature" or proceeds as an in-place fix.

| Finding (defect task filed in parallel) | Deciding child here |
|---|---|
| G001, F004 (regulated gate, destructive end cut) | [MIC18](./MIC18.md) |
| F014 (series continuity leaks a withheld meeting) | [FEAT22](./FEAT22.md) step 1 |
| F017, F088 (Notion wipe-and-append) | [PIPE39](./PIPE39.md) |
| F038 in part (idle discovery cost) | [DET16](./DET16.md) |

## Children

| Task | Idea | Priority | Depends on |
|---|---|---|---|
| [MIC18](./MIC18.md) | I41 delete the regulated real-time gate and end cut | P1 | GO lands only after the F001 and F020 fixes and the library off iCloud; ADR 0016 amendment needs the owner |
| [FEAT22](./FEAT22.md) | I42 delete on a date unless a local witness shows use | P2 | Nothing |
| [PIPE39](./PIPE39.md) | I43 Notion appended revision, no transcript upload, no LAN sink | P2 | Owner's one Notion query |
| [DET16](./DET16.md) | I47 delete detector paths with zero firings | P2 | Nothing |
| [HYG19](./HYG19.md) | I46 witness rule and audit moratorium | P2 | The audit's F151 coverage fix before the rule has an instrument |
| [FEAT23](./FEAT23.md) | I45 archive-first trial | P3 | F023 and F009 on the on-request path |
| [PIPE40](./PIPE40.md) | I06 quote-only minutes, settles PIPE20 | P3 | F107 before anything is called verbatim |
| [HYG20](./HYG20.md) | I33 internal half, blind verify-the-fix probe | P3 | Feeds HYG19 |

## Related existing tasks (referenced, not edited)

[FEAT18](./FEAT18.md) (the surface inventory FEAT22 acts on), [DV5](./DV5.md), [CAL3](./CAL3.md), [PIPE20](./PIPE20.md) (delete-or-verdict for the staged summarizer and dev tooling, the assessor's first seam step), [DET6](./DET6.md), [MIC7](./MIC7.md), [FEAT21](./FEAT21.md). Idea I44 (close the language question by deletion) is parked in [EPIC6](./EPIC6.md); its deletion half is PIPE20's and its boundary half waits on [LOCAL24](./LOCAL24.md).

## Done when

Every P1 and P2 child has a recorded verdict and its delete commit or its documented keep, and each paired defect task above names which way it went.
