# LOCAL12 spike: MLX-Swift trigger evaluation (the I7 gate)

Verdict, 2026-07-12. Harness: [`local12_bench.py`](./local12_bench.py) (throwaway, not in the `mp` package, not in CI). Run from the pipeline venv:

```
cd pipeline && uv run python ../docs/spikes/local12_bench.py \
    --transcript ~/Documents/Meetings/raw/<stem>.transcript.md --runs 3           # baseline (mlx_lm)
cd pipeline && uv run python ../docs/spikes/local12_bench.py \
    --transcript <same-stem>.transcript.md --no-manage --port 8770 --runs 3        # candidate (MLX-Swift)
```

This is not a yes/no spike. It operationalizes I7's amended trigger so the decision stops being aspirational: it ships the measuring instrument and pins the analysis, and the measured A/B is owner-owed because the candidate does not exist yet (building it is the very thing under evaluation). Same split as DIST1 (`dist1-bundle-runtime.md`): instrument shipped + reasoning pinned here, measured artifact owner-owed.

## Question

I7's amended trigger (2026-07-10): reopen the "drop Python entirely" decision when **MLX-Swift LLM inference matches the `mlx_lm` 7B on quality and latency for this workload** (or Apple widens the system-model context). LOCAL12 asks: is that trigger met today, and what is the recommended endgame for the local-summary runtime, given DIST1's embedded-Python bundle shipped 2026-07-12 in parallel?

The comparison is `mlx_lm` (the current Python `LocalSummaryClient` driving `mlx_lm.server`, default `mlx-community/Qwen2.5-7B-Instruct-4bit`) versus an MLX-Swift generation stack, on summary quality (the dogfood SHIP_GATE), latency, peak memory, and long-transcript behaviour (the LOCAL3 map-reduce).

## What is measurable here vs owner-owed

A real measured A/B is **not runnable in the coding harness**, for reasons that are themselves part of the finding:

- **The candidate does not exist.** There is zero MLX-Swift code and zero `mlx-swift` SPM dependency in the repo (`daemon/Package.swift` / `Package.resolved` have no `mlx` entry; every "mlx" hit in `daemon/Sources` is about supervising the *Python* `mlx_lm.server`). "Benchmark MLX-Swift" means first *building* the generation loop, tokenizer parity across the Qwen family, HF model loading, and JSON-schema / grammar-constrained decoding that can hold the `MeetingSummary` contract. That build is exactly the immature-LM-tooling risk DIST2 named. It is the object under evaluation, not a precondition.
- **Adding it needs owner approval.** A new SPM dependency (`mlx-swift` + `MLXLLM` / `swift-transformers`) is gated by both `CLAUDE.md` files ("don't add dependencies without asking first").
- **The 7B is not cached, and quality is hand-graded by design.** Only the 3B is in the HF cache on this Mac; measuring the configured 7B needs a ~4.3 GB fetch. Summary quality is graded by the owner, not an LLM (the dogfood harness rejects LLM-as-judge as self-referential; the LOCAL8 / SUM1-APPLE precedent is "on-device efficacy stays owner-owed dogfood").

So the baseline half (`mlx_lm`) is runnable today (3B immediately; 7B after the fetch); the candidate half is owner-owed and gated on a build that is itself the decision.

## Evidence and analysis

**DIST2 already reasoned this out and stands.** `dist2-swift-port-of-the-pipeline.md` concludes: *defer the full Swift port; pursue DIST1 (bundle the runtime) for near-term distribution.* Everything except the local MLX summarizer is a low-risk Swift rewrite over HTTP + file IO; the local backend is the blocker, "not a port; it is adopting (and maintaining) a second LM runtime." It names MLX-Swift directly and judges the **LM tooling on top of the array framework materially less mature than `mlx_lm`** on the four things this workload actually needs: tokenizer parity across model families, robust HF loading, a sampling generation loop, and constrained/grammar decoding to hold the JSON contract. Nothing has changed that judgement since 2026-07-10.

**The LOC tax that would justify a port is real but bounded.** Spot-checked on this tree: total pipeline `src/` is **13,942 LOC**; the publishers are **2,042 LOC** of real Python behaviour with no Swift equivalent; the LLM band and embeddings/RAG are likewise Python-only behaviour (the backlog's ~2.9k / ~1.3k accounting). The Swift-mirror upkeep the backlog quantifies at ~8% (~1.1k lines) is the genuine duplication cost: `render_summary_md` ↔ `AppleIntelligenceSummarizer.renderMarkdown`, `largest_balanced_json_object` ↔ `.largestJSONObject`, the chunker, and the meta-contract, each pinned by a CI golden fixture (`chunking-golden.json`, `json-extract-golden.json`, `summary-md-golden.json`, plus the meta-contract fixture). That tax grows slowly as mirrors are added; it does not yet overtake the cost + risk of adopting and maintaining a second, less-mature LM runtime, especially now that DIST1 has made the embedded-Python bundle a shippable end state rather than a stopgap.

## The I7 trigger, operationalized

The trigger fires (i.e. reconsider dropping Python for an MLX-Swift summarizer) only when an MLX-Swift server, driven through the **same OpenAI-compatible HTTP seam** `mlx_lm.server` exposes, clears all of:

1. **Quality:** meets the dogfood SHIP_GATE against the same transcripts the `mlx_lm` 7B does (actions_capture >= 0.80, decisions_capture >= 0.80, hallucination_rate <= 0.05); owner-graded, no regression versus the baseline label.
2. **Latency:** within a small margin of the `mlx_lm` 7B p50 on the same transcripts (harness `latency p50`), including a long transcript that exercises the LOCAL3 map-reduce.
3. **Memory:** peak resident set not materially worse than the `mlx_lm` 7B (harness `peak RSS`; the 7B-4bit sits around ~4.3 GB).
4. **Contract:** holds the `MeetingSummary` JSON schema across the corpus without a higher repair-loop rate than the baseline (the constrained-decoding maturity DIST2 flagged).

`local12_bench.py` measures 1–3 directly and surfaces the written summary for grading 1; a higher repair rate for 4 shows up as latency + quality drift. If any bar fails, the Meet-native summarizer stays deferred and the embedded-Python runtime remains the end state.

## Verdict: NO-GO now; keep the embedded-Python runtime as the end state

- **NO-GO on the I7 trigger today.** The trigger is not met, and cannot be met here, because the candidate has not been built. Do not start a Swift port of the summarizer on the strength of the LOC tax alone.
- **Recommended endgame: maintain the DIST1 embedded-Python bundle as the end state**, not a transitional artifact. Treat the MLX-Swift summarizer as contingent on the operationalized trigger above, measured with this harness, not on a hoped-for maturity date. DIST1's daemon plumbing + build tool (shipped 2026-07-12) plus the owner-owed notarize / clean-Mac test are worth completing regardless of this verdict.
- **If the trigger ever fires,** start the port at `engine` / `summarize` per `dist2-swift-port-of-the-pipeline.md`, and keep the OpenAI-compatible HTTP seam so `local12_bench.py` A/Bs the new server against `mlx_lm` with no pipeline changes (base = `mlx_lm` on :8765, candidate = MLX-Swift on another port via `--no-manage --port`). Publishers, the LLM band, and embeddings/RAG stay Python; only the generation call moves.

## What shipped in this task

`local12_bench.py`: a throwaway harness that drives the **real** production path (`mp.summarize_local.LocalSummaryClient` with the pipeline's own system prompt and the LOCAL3 map-reduce, so the numbers are the workload) and reports per-run + p50 latency, peak server RSS (a best-effort `lsof` + `ps` sampler keyed on the listening port, so it measures the `mlx_lm` server this tool spawns and an external MLX-Swift server identically), and an approximate tok/s, then writes the produced summary for quality grading. Keyed on `host:port`, so the same tool measures the `mlx_lm` baseline today and the MLX-Swift candidate the day a server exists. `--help` and ruff verified; the measured run is owner-owed (below), mirroring DEP1's throwaway-script and MIC7's owner-run-probe precedents.

## Owner-owed remainder

1. **Capture the baseline** on a real Mac: `--runs 3` over a few real transcripts against the configured 7B (needs the ~4.3 GB HF fetch), including one long enough to hit the map-reduce. Records the latency / peak-RSS / quality the trigger measures against.
2. **When (if) an MLX-Swift server exists,** run the candidate half (`--no-manage --port <mlx-swift>`) and compare the two labels against the four bars above. That measurement, not a calendar, is what flips I7.
3. The dependency + build decision (adding `mlx-swift`, standing up the generation harness) stays owner-gated and out of scope here.

## Reconciliation

DEP1 measured a system-framework alternative fully in-harness; MIC7 shipped an owner-run probe because the measurement needed live state; LOCAL12 is DIST1-shaped (instrument shipped and reasoning pinned, measured artifact owner-owed) because the candidate must be built before it can be measured, and that build is the decision. This verdict is the concrete evaluation I7's 2026-07-10 amendment asked for, so the decision stops drifting: the answer is NO-GO now, keep the embedded-Python runtime, and let `local12_bench.py` (not a maturity guess) be what reopens it.
