---
id: EPIC5
title: Epic: settle the language question with one number and shrink the Swift/Python seam whichever way it goes
category: Feature
status: new
priority: P2
comment: Umbrella, not a work item: pick a child. Filed 2026-11-13 (product-direction band, rewrite assessor): Rust core is a no, all-Swift is decided by one bench, and the direction-neutral seam work is worth doing regardless. Children LOCAL24 (mlx-swift-lm bench against LOCAL12's bars, decides ARCH11's ADR), ARCH21 (executable schemas for the file contract), ARCH22 (target split and a headless recording test), parked ARCH23 (out-of-tree Rust conformance reader).
---

# EPIC5: epic, settle the language question and shrink the seam

Band origin: filed 2026-11-13 as the umbrella for the product-direction band's rewrite verdicts ([report](../../research/2026-11-12-product-direction.md), "Radical options and their verdicts": options 2, 3, 4 and 7; ideas I17, I29, I34). Epics have no type in this backlog: this file is an umbrella, not a work item, and closes when every child is closed or parked. Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Thesis

The assessor's verdicts: a Rust core for the engine, a cross-platform engine and an iOS or watch companion are "do not"; Rust for one component is an out-of-tree experiment only; all-Swift is "stage it", gated on one bench; keeping two trees and shrinking the seam is "do"; a headless daemon is "stage it", taking the target split now and the process split only behind two measurements. About nine tenths of the audit's findings would survive any language change, so no rewrite is a substitute for the fix list.

## Children

| Task | Source | Priority | Depends on |
|---|---|---|---|
| [LOCAL24](./LOCAL24.md) | Option 3 gate, idea I17 stage zero | P2 | Owner's approval to fetch the 7B weights; decides [ARCH11](./ARCH11.md)'s ADR direction |
| [ARCH21](./ARCH21.md) | Idea I29, internal half | P2 | Nothing; becomes [ARCH10](./ARCH10.md) and [PIPE33](./PIPE33.md)'s reference |
| [ARCH22](./ARCH22.md) | Option 7 stages 1 and 2 | P2 | Sequenced after the audit's top data-handling fixes |
| [ARCH23](./ARCH23.md) | Option 2, idea I34 | P3 | After ARCH21; only if the owner wants Rust for its own sake |

## Direction-neutral seam work already filed (referenced, not refiled)

The assessor's option 4 legs map onto existing tasks: delete unwired and dev-only Python ([PIPE20](./PIPE20.md)), one owner for the local model server ([LOCAL21](./LOCAL21.md)), a commit stamp with a spawn-time version handshake ([DIST6](./DIST6.md)), a single writer and an `mp --result` envelope ([ARCH10](./ARCH10.md)), the typed backend ([ARCH14](./ARCH14.md)), the Python-side file contract ([PIPE33](./PIPE33.md)). Hold ARCH11's provider leg (Apple Intelligence under Python) until LOCAL24 reports, since it is throwaway if all-Swift proceeds; the neutral fix for F022 and F023 meanwhile is to resolve the effective backend in Swift before a nil-backend regenerate.

## Explicitly closed

Rust in the app (ideas I07, I14, I20), the cross-platform engine, an iOS or watch companion (ideas I19, I25), and the process split of option 7 stage 3 (idea I18): parked with reasons in [EPIC6](./EPIC6.md).

## Done when

LOCAL24 has a verdict carried into ARCH11's ADR, ARCH21 has a verdict, and ARCH22 has landed both stages.
