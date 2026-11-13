---
id: EPIC1
title: Epic: a speech record that improves with age, measured by a yardstick that needs no labelling and re-derivable from retained audio
category: Feature
status: new
priority: P2
comment: Umbrella, not a work item: pick a child. Filed 2026-11-13 (product-direction band): retained channel-separated audio is the asset funded vendors discard by design, so qualify every speech-stack change on the owner's own audio and let the archive be re-derived when a model wins. Children ASR7 (yardstick, first), ASR8 (Neural Engine in the agent, run early), ASR9 (re-derive corrected meetings), parked riders DV6 and AI15.
---

# EPIC1: epic, a speech record that improves with age

Band origin: filed 2026-11-13 as the umbrella for the product-direction band's speech ideas ([report](../../research/2026-11-12-product-direction.md): ideas I35, I32, I16 with I38, I37, I26). Epics have no type in this backlog: this file is an umbrella, not a work item, and closes when every child is closed or parked. Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Thesis

Two of the four ideas all three judges picked live here. A label-free yardstick (idea I35) turns upgrades from acts of faith into a scorecard diff on the owner's English, Ukrainian and code-switched audio; re-derivation from retained audio (idea I16, in idea I38's safer shape) lets a better model improve last spring's meetings, not only the next one. The Neural Engine question (idea I32) runs first because, if the menu-bar agent has lost the accelerator on macOS 27.2, every other plan re-orders.

## Children

| Task | Idea | Priority | Depends on |
|---|---|---|---|
| [ASR7](./ASR7.md) | I35 label-free speech scorecard | P2 | Nothing; gates the build leg of ASR9 and the voice epic's closed-set scorer |
| [ASR8](./ASR8.md) | I32 Neural Engine in the agent + 0.18.3 on three files | P2 | A fresh build (F021) |
| [ASR9](./ASR9.md) | I16 / I38 re-derive 30 corrected meetings | P2 | The spike is read-only; any write path waits on the audit's F062 overlay-drift defect |
| [DV6](./DV6.md) | I37 owner's commitments by channel | P3 | Rider on ASR7's script; a miss carries out DV5's Remove |
| [AI15](./AI15.md) | I26 listen-only routing | P3 | Rider on ASR7's script |

## Sequence

ASR8 and ASR7 first (weeks 2 to 6 of the report's suggested quarter), then ASR9 with the yardstick as second judge (weeks 6 to 10). Riders only if ASR7 returns USABLE and the owner promotes them.

## Later legs, not filed (promote on a GO)

- The whole-archive speech-only reprint in idea I38's shape: previous print kept for one-step per-meeting rollback, a change line per meeting, published notes never touched, summaries re-derived only on request, each meeting's NDA or regulated flag read at reprint time. Needs ASR9 GO, the F062 fix, and the F001 and F020 sole-copy fixes.

## Related existing tasks (referenced, not edited)

[ASR4](./ASR4.md) (hand-held golden set, stays the second opinion), [ASR6](./ASR6.md) (vendor exposure; ASR8 and ASR9 execute its qualification leg), [DIAR6](./DIAR6.md) (channel-aware attribution), [DV5](./DV5.md) (Facts rail decision).

## Done when

Every child is closed or parked, and either a FluidAudio bump has been accepted or rejected on a scorecard diff, or the yardstick closed and the decision fell back to ASR4.
