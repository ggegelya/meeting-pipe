---
id: EPIC3
title: Epic: provable zero egress and checkable agent reads, enforced outside the code that keeps changing
category: Feature
status: new
priority: P2
comment: Umbrella, not a work item: pick a child. Filed 2026-11-13 (product-direction band): a cloud vendor cannot print proof that nothing left the machine; this product can, if enforcement sits in the kernel and a harness and canary fence pin it. Children SEC32 (kernel deny for the mp child, bypass harness), AUTO9 (MCP usage kill switch plus cross-reader canary fence), parked AUTO10 (gated on the usage count).
---

# EPIC3: epic, provable zero egress and checkable agent reads

Band origin: filed 2026-11-13 as the umbrella for the product-direction band's privacy and agent ideas ([report](../../research/2026-11-12-product-direction.md): idea I01 picked by all three judges, with I31 and I15 folded in; idea I08's probe legs; idea I10). Epics have no type in this backlog: this file is an umbrella, not a work item, and closes when every child is closed or parked. Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Thesis

Privacy is the project's identity, and the 2026-11-12 [audit](../../audits/2026-11-12-independent-audit.md) found it stronger in documents than in code. Turn each claim into an enforced or machine-checked property: a kernel deny the app's own code cannot bypass, a harness that proves it, a canary fence that sizes and then pins the cross-meeting leak class, and a count that decides whether the agent surface deserves more work at all. State scope plainly: a network deny cannot see policy-layer leaks (F014, F005, F046) or file-mediated ones (synced folders, backups), which stay with their defect tasks and [SEC18](./SEC18.md).

## Children

| Task | Idea | Priority | Depends on |
|---|---|---|---|
| [SEC32](./SEC32.md) | I01 (+ I31 legs) kernel deny for the mp child, bypass harness; receipt later | P2 | Nothing for the spike; the receipt leg waits on ARCH10's single writer |
| [AUTO9](./AUTO9.md) | I08 probe legs: usage count + canary fence | P2 | Nothing; its failures hand off to the F014 and AUTO6 defects |
| [AUTO10](./AUTO10.md) | I10 repository-scoped decision register | P3 | AUTO9 leg 1 GO |

## Later legs, not filed

- The per-meeting egress receipt and the Library's Confined, Guarded or Left this Mac state (inside SEC32's scope, after its PASS and ARCH10).
- Read-broker tiers, client profiles and a read ledger (inside AUTO9's GO path).

## Related existing tasks (referenced, not edited)

[SEC19](./SEC19.md) (in-process socket layer, the fallback if the kernel probe fails), [SEC18](./SEC18.md) (file-mediated egress), [EGRESS1](./EGRESS1.md) (the daemon's wire check, still waived), [AUTO5](./AUTO5.md), [AUTO6](./AUTO6.md), [AUTO8](./AUTO8.md).

## Done when

The kernel probe has a verdict (wrap landed with its standing harness, or fallback to SEC19 recorded), the canary fence runs in CI with every expected failure tied to an open defect, and the usage count has decided the agent lens.
