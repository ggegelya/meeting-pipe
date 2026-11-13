---
id: ARCH23
title: Experiment: an out-of-tree clean-room Rust reader of the meeting library, written from the docs alone, as a format-conformance test and the only Rust the assessor allows
category: Architecture
status: new
priority: P3
comment: Filed 2026-11-13 (product-direction band, the rewrite assessor's option 2 and idea I34, 12.00 of 20; parked P3, only if the owner wants Rust for its own sake): Rust inside the app is closed (no accelerator path, a third language at the seam the audit already found expensive). A read-only reader built on a synthetic fixture library from CONVENTIONS.md and ARCHITECTURE.md only; every question it can answer only by opening Swift or Python source is logged as a documentation defect. Never ships in the app. After the schemas spike. Child of [EPIC5](./EPIC5.md).
---

# ARCH23: experiment, an out-of-tree clean-room Rust reader of the library format

Band origin: filed 2026-11-13 from the product-direction band ([report](../../research/2026-11-12-product-direction.md), "Radical options and their verdicts", option 2 "Rust for one accelerator-free component: experiment only", and idea I34). Child of epic [EPIC5](./EPIC5.md). Parked: promote by editing the header. Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Option 1 (Rust core) is "do not": the engine is Apple frameworks reached from Rust only through a Swift bridge, the market file's source reports the ONNX Runtime CoreML provider crashing on Parakeet and mlx-rs as immature, and about nine tenths of the audit's findings would survive any language change. Option 2 as an in-app component fails the audit's own test (a third copy of rules like the visibility gate). ADR [0006](../../decisions/0006-swift-over-go-for-hub.md) rejected a second language for a helper on one-language grounds, and nothing since has argued the other way. What is left is an experiment that never ships inside the app. Best run after [ARCH21](./ARCH21.md), whose schemas it can consume.

## Pre-registered pass condition (the assessor's first step, written before any code)

The reader lists meetings, resolves speakers through the overlays, and prints a summary with its evidence anchors, for a synthetic fixture library, using only CONVENTIONS.md and ARCHITECTURE.md as its specification. Every question the agent can answer only by opening Swift or Python source is logged as a format-documentation defect. The deliverable is the gap list, not the binary.

## Explicitly not

- Integration into the app, `install.sh`, `rebuild.sh` or `ci-local.sh` (SwiftPM cannot build Rust; a cargo leg is a permanent third toolchain).
- Running it against the live library: synthetic fixtures only.
- Serving MCP tools from it (a third copy of the visibility gate).

## Acceptance

The crate kept outside the repo; the gap list committed as a doc under `docs/spikes/` with each gap filed or fixed in CONVENTIONS; effort recorded (the assessor's estimate is 2 to 4 agent days and one owner evening).
