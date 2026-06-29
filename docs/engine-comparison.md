# Three-engine summarization comparison

Which summarization backend to use, measured over 26 real meetings (duration > 5 min, transcript < 13k chars for 14B memory safety) on the owner's Mac (macOS 26.5.1, Apple Silicon). Compares the three engine choices the product exposes: Anthropic (cloud), MLX local (3B and 14B), and Apple Intelligence (native macOS 26). Apple Intelligence ran on a 5-meeting subset (it is minutes-per-meeting, see below).

Quality grades are a provisional Claude hand-read of the side-by-side outputs against the Anthropic baseline (the dogfood design calls for human grading, since an LLM grading an LLM against a third LLM is circular). They are flagged for owner spot-check. The extraction counts and latencies are objective.

## TL;DR recommendation

- **Best quality, non-sensitive meetings: Anthropic (cloud).** Clearly the most complete and precise; fast. The default for anything that may leave the machine.
- **Privacy / regulated / NDA: MLX 14B.** The best on-device option and a usable gist, but it under-captures on dense meetings (caught roughly half of Anthropic's action items) and translated a Ukrainian meeting into Russian. Memory-bound on this Mac, so keep transcripts modest.
- **Low RAM or speed-first: MLX 3B.** Fast and light, but vague and lossy, and one of 26 produced invalid output. Use only when the 14B will not fit.
- **Apple Intelligence: not yet.** Native, free, and zero-egress, which is the right long-term posture, but the 4096-token context makes it slow (minutes per meeting) and lossy on real meetings, and it mishandles Ukrainian. Revisit after LOCAL3 (hierarchical reduce, which this run had to prototype) and better language handling, or a larger system-model context.

## Per-engine summary

| Engine | avg actions | avg bullets | action capture vs Anthropic | latency / meeting | privacy | quality (hand) |
|---|---|---|---|---|---|---|
| Anthropic (cloud) | 7.3 | 5.0 | baseline | seconds | cloud egress | A (most complete + precise) |
| MLX 14B (local) | 3.9 | 5.0 | ~0.4 to 0.5 | ~84 s | on-device | B- (good gist, under-captures) |
| MLX 3B (local) | 2.8 | 5.0 | lower | ~36 s | on-device | C (fast, vague, 1/26 failed) |
| Apple Intelligence | 5.8 | 11.3 | lowest | ~86 s+ | on-device | D (slow, lossy, mishandles uk) |

Latency is summarization wall-clock on this Mac and includes a fresh per-meeting model load for the MLX backends (a warm resident server is faster but holds ~8 GB for the 14B); Apple Intelligence is the map+reduce total over its chunks and was measured only on the smallest meetings (a 6-chunk meeting already took ~164 s). "Action capture" is the fraction of Anthropic's action items the engine also surfaced; the dogfood gate (>= 0.80) is in `docs/local-llm-quality.md`.

## What each engine does well and badly

**Anthropic.** The most exhaustive and specific: more action items (avg 7.3 vs the locals' 3 to 4), named owners, well-phrased decisions, and it preserved the meeting's language (kept Ukrainian as Ukrainian). The only backend that transmits off-device. The quality baseline the others are measured against, so it scores 1.00 by construction.

**MLX 14B.** Coherent and usable, the best on-device option. It reliably gets the gist and the headline decisions, and on light meetings it matched Anthropic well (~0.85 to 0.9 capture). But it systematically extracts fewer items, so on dense meetings (where Anthropic found 9 to 13 actions) it captured only about a third, dragging the hand-graded average to ~0.42 action / ~0.52 decision capture. Owners are often generic speaker labels rather than names. On a Ukrainian meeting it produced a Russian summary (Anthropic kept Ukrainian), a real problem for the owner's en/uk usage. Hallucination is mostly low (it under-reports rather than invents), with one meeting where it diverged from the baseline entirely.

**MLX 3B.** Fast (about half the 14B's time) and light enough to never threaten memory, but the quality cost is steep: vaguer decisions ("tasks assigned to team members for review"), generic titles, fewer and less specific actions, and on one of the 26 it failed to produce schema-valid JSON after the three repair attempts (a real reliability gap: that meeting would fail in the pipeline). Acceptable only as the fallback when the 14B cannot run.

**Apple Intelligence.** The appealing posture (native, free, fully on-device) is undercut by the system model's 4096-token context. Real meetings must be chunked into many windows and map-reduced, which is slow (about 86 s even on the smallest meetings, ~164 s on a six-chunk one, and it would be minutes on a full-length meeting) and lossy: on a short meeting it echoed raw dialogue fragments instead of summarizing, emitted a malformed language code, ignored the bullet-count cap (avg 11 bullets vs the requested 5), and one of the five attempted failed. Ukrainian tokenizes at ~1.7 tokens/char, so a 3200-char window overflowed the context, and a flat reduce overflows too (this is exactly the open LOCAL3 task; this run worked around it with a hierarchical batched reduce). Not usable as a daily summarizer today, but worth revisiting: LOCAL3 plus a language fix would help, and Apple may widen the context.

## The dogfood ship-decision (local 14B)

`docs/local-llm-quality.md`, generated by `mp dogfood --report`, records **DO NOT SHIP** the 14B as the silent default auto-summary: hand-graded action capture ~0.42 and decision capture ~0.52 are well below the 0.80 acceptance gate (the hallucination figure is inflated by one diverging meeting). This does not mean the local backend is useless: it is the correct choice when privacy requires it, with the understanding that it under-captures on busy meetings. Five of the 26 are hand-graded; the rest are left pending for the owner to spot-check, per the dogfood workflow.

## How to choose each engine

- `summarization.backend = "anthropic" | "local" | "apple_intelligence"` (Preferences > Pipeline).
- `summarization.local_model` selects the MLX size (3B / 14B / 32B). The sizes are now A/B-able directly with `mp dogfood --local-model <repo>` (added with this comparison).
- Regulated / NDA workflows force the local path regardless (the egress guard), so the 14B is what those meetings get; this comparison is the basis for setting expectations there.

## Re-run

```bash
cd pipeline
uv run mp dogfood --runs-dir runs/mlx-14b <transcript.md>                              # vs 14B
uv run mp dogfood --local-model mlx-community/Qwen2.5-3B-Instruct-4bit \
  --runs-dir runs/mlx-3b <transcript.md>                                              # vs 3B
swift ../daemon/scripts/ai-summarize.swift <transcript.md> out.ai.json "" auto        # Apple Intelligence
python3 ../scripts/engine_compare_report.py --runs runs                               # synthesize draft
```

Run the local backends under `caffeinate -dims` and a memory watchdog: the 14B is OOM-unsafe above ~13k-char / ~16k-token transcripts on this Mac (see [`docs/spikes/ai2-embedding-rag-latency.md`](spikes/ai2-embedding-rag-latency.md)).
