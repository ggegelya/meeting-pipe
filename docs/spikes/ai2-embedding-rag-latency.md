# Spike: on-device embedding index + long-context RAG latency and faithfulness (AI2)

Status: spike complete, decision recorded. Gates AI3 (engine-backed cited answers). Re-evaluate on the triggers in the last section.

## Context

AI2 asked whether an "ask my meetings" chat over the whole library can run on-device, and if so whether it can be interactive (you type, you watch the answer appear) or has to be async (kick it off, get notified). The load-bearing risk is that MLX prefills the entire prompt before emitting the first token, so the often-cited 6.9 s figure is a short-prompt number and time-to-first-token (TTFT) grows with the retrieved context, which is exactly RAG's worst case.

This spike built a real on-device embedding index over the library, then measured RAG-synthesis TTFT and total wall-clock at 4K / 8K / 16K context, plus a faithfulness and citation-accuracy read, on the owner's actual Mac. It returns a go/no-go on interactive vs async and a recommended context budget. It folds FEAT2's deferred vector-RAG follow-up; `mp ask` (the TF-IDF MVP) named this exact next step.

## What was built

- `pipeline/src/mp/embed_index.py`: a reusable on-device embedding index (the durable artifact AI3 builds on). Pluggable embedder: `MLXEmbedder` (multilingual-e5-small on MLX via `mlx_embeddings`, 384-d, en/uk) is the production path; `HashingEmbedder` (numpy-only) is the CI/Linux fallback. Chunks the library with the existing `chunked_windows`, stores L2-normalized vectors + a manifest, searches by cosine.
- `pipeline/src/mp/ai2_spike.py`: the measurement harness (`mp ai2-spike`). Builds/loads the index, packs retrieved context to a target token size, drives the local MLX chat model with a streaming request to capture TTFT and wall-clock, and runs needle-in-haystack probes (a unique planted fact at a known source tag) for faithfulness + citation accuracy. Writes a results JSON per size (so an interrupted run keeps completed sizes) and prints a go/no-go.
- New dependency `mlx-embeddings` (darwin/arm64 only, lazy-imported, same discipline as `mlx-lm`; CI never installs it).

The index half of the acceptance is solid: 2147 chunks over 168 meetings, built with multilingual-e5-small in ~94 s, fully on-device. Search quality is semantic and correct on spot checks. The hard ceiling the spike found is on the generation half, below.

## Method

- Hardware: the owner's Apple-Silicon Mac, the daily-driver machine, under realistic memory conditions (other apps open; the machine paged to swap during the large runs).
- Generation models: the configured `local_model` (Qwen2.5-14B-Instruct-4bit, the "Recommended" preset) and the smaller Qwen2.5-3B-Instruct-4bit (the realistic interactive candidate).
- Latency: each size sends a real retrieved RAG context packed to the target token count. A per-run nonce is prepended so `mlx_lm.server`'s prompt cache cannot serve a prefix-cache hit; without it, a repeated identical prompt reads ~0 s and badly overstates steady-state speed. The first run after a server launch additionally pays one-time kernel compilation (and, for the 3B, the model download), reported separately as "cold".
- Faithfulness/citation: 3 needle probes per size, each planting a unique codename at a known `[source]` tag among real distractor chunks. Faithful = the answer states the planted codename (it used the context); cited = the answer names the right source tag. This is robust to retrieval recall because the needle is inserted, not retrieved.
- Safety: a memory watchdog hard-killed the run if free memory dropped below 10%, after a first attempt swap-stormed the machine and OOM-killed the model server.

## Results (real numbers, this Mac)

Steady-state = warm, cache-busted (a genuine fresh prefill, what a user asking a new question actually pays). Cold = first query after the server launches.

| Model | Context | Prompt tok | Steady TTFT | Total wall-clock | Prefill tok/s | Decode tok/s | Faithfulness | Citation |
|---|---|---|---|---|---|---|---|---|
| 3B  | 4K  | 4030  | 7.8 s  | 13.8 s | 517 | 45 | 1.00 | 0.33 |
| 3B  | 8K  | 8086  | 17.2 s | 23.3 s | 470 | 42 | 1.00 | 0.00 |
| 3B  | 16K | 15901 | 40.6 s | 47.7 s | 392 | 36 | 1.00 | 0.33 |
| 14B | 4K  | 4030  | 30.9 s | 51.2 s | 121 | 15 | 1.00 | 1.00 |
| 14B | 8K  | 8086  | aborted (memory watchdog, 9% free) | | | | | |
| 14B | 16K | ~16000 | OOM crash + system swap-storm | | | | | |

Cold first-query (one-time per server launch): 3B 4K 209 s (includes the one-time model download + kernel compile), 14B 4K 36.3 s. A salvaged earlier 14B run (prompt-cache-contaminated, so latency discarded) corroborated 14B 8K cold near 41 s and 14B 16K crashing.

## Findings

1. The prefill-collapse hypothesis holds. TTFT grows with context and prefill throughput falls as the window grows (3B: 517 -> 470 -> 392 tok/s across 4K/8K/16K). The 6.9 s short-prompt figure does not survive RAG-scale context: even the small 3B is ~40 s at 16K.
2. There is a quality/speed scissors. The model that cites correctly (14B, citation 1.00) is slow and memory-bound: ~31 s TTFT at 4K, the 8K run could not complete on this Mac under session memory load, and 16K OOM-crashed the model server and hung the machine. The model that is fast enough to feel interactive at small context (3B at 4K, 7.8 s) is faithful (states the fact, 1.00) but cites the source unreliably (0.00 to 0.33). Neither model gives interactive speed AND reliable citations AND large context at once.
3. The 14B is memory-marginal for RAG on this machine. It fits for summarization (one short prompt) but a 16K RAG context blows the KV cache past RAM, swaps hard, and crashes. The 14B numbers above are also depressed by swap pressure, so they are pessimistic for a higher-RAM Mac, but the memory-marginality itself is the operative constraint here.
4. Faithfulness is not the problem. Both models reliably used the provided context (faithfulness 1.00 everywhere). The weak link is small-model citation attribution, not hallucination over the retrieved set.

## Recommendation: go/no-go

No-go for interactive live chat as the AI3 default on this hardware. The only configuration that clears a sub-10 s TTFT is the 3B at 4K context, and the 3B does not cite reliably, which defeats the purpose of cited answers. The citation-reliable model (14B) is ~31 s to first token even at 4K.

Ship AI3 as async ask-AI: kick off the query, show a quiet in-progress state, notify when the answer is ready (the register PRODUCT.md already calls for). Use the 14B (or the configured backend) for citation fidelity.

Recommended context budget: about 4K tokens (roughly the top 6 retrieved chunks) on the 14B. Do not stuff 16K: it is both too slow and, on this machine, memory-unsafe. If a larger context is genuinely needed, the 3B handles 16K memory-wise (~40 s, async) but must clear the citation-quality bar first.

One nuance worth keeping: `mlx_lm.server` prefix-caches, so within a single chat session a follow-up that reuses the same retrieved context returns almost instantly. A session-scoped context could make multi-turn follow-ups feel interactive even though the first answer is async.

## Recommendations for AI3

1. Async by default (in-progress state + notification), not a live-typing chat. Scope any interactive affordance to small-context follow-ups within a warm session.
2. Bounded retrieval: cap the packed context near 4K tokens for cited answers on the 14B.
3. Load the embedding model offline-safe. Loading multilingual-e5 triggers a one-time Hugging Face metadata GET. Under the regulated/NDA egress guard that is a non-loopback request, and the guard raises `EgressBlocked` (not a network error hub would catch), so AI3 must load the embedding model with `local_files_only=True` / `HF_HUB_OFFLINE=1` once cached, or it crashes in zero-egress mode. The index build/search compute is otherwise fully on-device.
4. Memory preflight (LOCAL4 territory): refuse or shrink context on memory-marginal machines so a large RAG context cannot OOM the daemon-adjacent process the way 16K did here.
5. Citation quality for small models: if interactive (3B) is ever pursued, invest in citation prompting + post-hoc validation (verify each cited tag exists in the packed context), or use a mid-size model that both cites and fits.
6. Reuse `embed_index.EmbeddingIndex` directly; promote the `embed_model` constant to config, and add incremental/on-change index refresh as the library grows.
7. Reconsider the embedding dependency weight before productionizing. `mlx-embeddings` drags in a heavy transitive tree (mlx-vlm, opencv-python, pandas, scipy, pyarrow), which is a lot for a 384-d sentence embedder. It is confined to darwin/arm64, lazy-imported, and excluded from CI, and the numpy `HashingEmbedder` keeps everything runnable without it, but AI3 should weigh a lighter embedding path (a slimmer package, or loading the XLM-RoBERTa weights directly) against this surface, given the project's deliberately small dependency posture.

## Re-run (runbook)

```bash
cd pipeline
uv run mp ai2-spike --index-only                       # build/refresh the index only
uv run mp ai2-spike --reuse-index --sizes 4000,8000    # measure (configured local model)
uv run mp ai2-spike --reuse-index --gen-model mlx-community/Qwen2.5-3B-Instruct-4bit \
  --sizes 4000,8000,16000 --out ../docs/spikes/ai2-rag-latency-results-3b.json
```

Run under `caffeinate -dims` and watch free memory: the 14B at 16K is OOM-unsafe on a memory-marginal Mac (it hung this machine before the watchdog was added). Raw evidence: `ai2-rag-latency-results-3b.json` (3B, all sizes) and `ai2-rag-latency-results-14b.json` (14B 4K; 8K aborted and 16K crashed, hence absent).

## Re-evaluation trigger

Reopen the interactive-vs-async question when any of these holds:

- A higher-RAM Mac or a memory-comfortable target removes the 14B swap ceiling (re-measure 8K/16K on the 14B there).
- A mid-size local model (7B to 8B class) lands that both cites reliably and fits in memory at RAG context.
- MLX gains materially faster prefill (or speculative decode / prompt-cache reuse across queries) that pulls 8K TTFT under the interactive bar.
- Apple Intelligence Foundation Models become usable as the on-device RAG synthesizer (the TECH-I7 promotion), at which point summarize is already Swift and this measurement should be redone against that backend.

Until then: AI3 is async, 14B for citations, context budget about 4K, and `embed_index.py` is the index AI3 builds on.
