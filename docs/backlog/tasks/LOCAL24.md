---
id: LOCAL24
title: Spike: run LOCAL12's bench once against an mlx-swift-lm candidate with guided generation, so the all-Swift versus Python-owns-summarize question is decided by a number
category: Local models
status: new
priority: P2
comment: Filed 2026-11-13 (product-direction band, the rewrite assessor's option 3 gate and idea I17's stage zero): LOCAL12 closed NO-GO on 2026-07-12 because no MLX-Swift candidate existed; mlx-swift-lm 3.32.3 (2026-09-30) ships guided generation, Qwen support and a Foundation Models conformer, so the candidate can be assembled in days. Throwaway Xcode-built CLI outside the repo serving the same OpenAI-compatible endpoint; the owner runs both halves of local12_bench.py against LOCAL12's four pre-registered bars. All four pass: plan the staged all-Swift move. Any miss: ARCH11 as written, Python owns summarize and publish. The port itself is not in scope. Child of [EPIC5](./EPIC5.md).
---

# LOCAL24: spike, the Swift local-model bench that decides the language question

Band origin: filed 2026-11-13 from the product-direction band ([report](../../research/2026-11-12-product-direction.md), "Radical options and their verdicts", option 3 "All-Swift, dropping the Python sidecar, staged: stage it", and idea I17's stage zero). Child of epic [EPIC5](./EPIC5.md). `/spike` shaped. Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## The one question

**Does an mlx-swift-lm server with guided generation on the `MeetingSummary` schema clear the four bars LOCAL12 pre-registered against the current mlx_lm path, on the same transcripts and the same Qwen2.5-7B-4bit weights?**

## Context and what changed

- LOCAL12 (done, NO-GO 2026-07-12; row in [q6-final.md](../q6-final.md), verdict in [`docs/spikes/local12-mlx-swift-trigger-evaluation.md`](../../spikes/local12-mlx-swift-trigger-evaluation.md)) said the candidate did not exist and building it was the risk; it operationalized [I7](./I7.md)'s trigger as the owner-run bench [`docs/spikes/local12_bench.py`](../../spikes/local12_bench.py), keyed on host and port so it A/Bs mlx_lm (`--manage`) and an external server (`--no-manage --port`). The four bars: quality at the dogfood SHIP_GATE, latency within margin, peak RSS not materially worse, holds the `MeetingSummary` schema without a higher repair rate. DIST2 ([spike](../../spikes/dist2-swift-port-of-the-pipeline.md)) judged the Swift LM stack immature.
- **What changed.** The market file reports mlx-swift-lm 3.32.3 (2026-09-30) with guided generation, multi-round tool calling, Qwen and Gemma 4 support and a Foundation Models conformer. The assessor read the repo and found the Python baseline is not schema-constrained either: `summarize_local.py` sends a `response_format` json_schema hint, but mlx_lm 0.31.3 in the venv has no handler for it, so JSON discipline today is prompt, three-layer extraction and a repair replay; LOCAL12's fourth bar is lower than DIST2 assumed. The pipeline grew from 13,942 lines when LOCAL12 was written to 22,838 (2026-11-12), so the price of waiting has risen. The local path being protected is itself below the ship gate (action capture 0.42 to 0.56 against 0.80), so the bar is parity with mlx_lm, not excellence.
- **What it decides.** [ARCH11](./ARCH11.md) (P2) asks for an owner-approved boundary ADR, then Apple Intelligence as a provider only. The assessor's recommended path: write that ADR with this number in it.

## Pre-registered decision (the bars are LOCAL12's, unchanged)

Build, outside the app target and outside the repo's package graph, a throwaway Xcode-built Swift CLI that loads the configured Qwen2.5-7B-4bit through mlx-swift-lm, constrains output to the `MeetingSummary` schema with guided generation, and serves the same OpenAI-compatible endpoint. The owner runs both halves of `local12_bench.py` (baseline and candidate) on the same three transcripts, one long enough to hit map-reduce, and grades against the four bars.

| Verdict | Measured | Next |
|---|---|---|
| **GO** | All four LOCAL12 bars clear | ARCH11's ADR adopts staged all-Swift with a worker executable (a second Swift target, not folded into the menu-bar process), Apple Intelligence becomes a provider of the Swift summarizer, and the staged port is planned leg by leg with differential checks against Python on the golden fixtures |
| **NO-GO** | Any bar missed | ARCH11 as written: Python owns summarize and publish, the Swift copies retire, DIST1's embedded runtime stays the end state, and the bench re-runs on each mlx-swift-lm minor release |

Record build friction in the same note: Xcode requirement (the Metal shader library), dependency count, whether it builds under plain SwiftPM.

## Explicitly not

- Any port work, or adding mlx-swift-lm to `daemon/Package.swift`: a new dependency needs the owner's approval, and the candidate lives outside the repo until a GO and that approval.
- Rust (closed in-tree; see [ARCH23](./ARCH23.md) for the one experiment left).
- Reopening Apple's on-device model as the sole local summarizer: at 8,192 tokens on this Mac it cannot hold a one-hour transcript and failed Ukrainian in 3 of 5 runs, so DIST2's second trigger is not met.

## Owner walkthrough

Fetch the 7B weights if not cached (about 4.3 GB, the owner's approval), run the baseline half (`local12_bench.py --manage`), start the candidate server, run the candidate half (`--no-manage --port <port>`), grade the written summaries against SHIP_GATE (one evening, per the assessor). The note records the four bars side by side.

## Deliverables and acceptance

- `docs/spikes/<id-lowercase>-mlx-swift-candidate-bench.md`: the bars copied from LOCAL12, the candidate's build recipe, both halves' numbers, the verdict, and the build-friction note.
- The candidate source kept outside the repo (or under `docs/spikes/` as a non-built reference, matching LOCAL12's DEP1-style throwaway), never in the `mp` package or CI.
- The verdict carried into ARCH11's ADR by that task, not this one.
