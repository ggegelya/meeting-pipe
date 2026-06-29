# Three-engine summarization comparison

Which summarization backend to use, measured over 26 real meetings (duration > 5 min, transcript < 13k chars for 14B memory safety) on the owner's Mac (macOS 26.5.1, Apple Silicon). Compares the engine choices the product exposes: Anthropic (cloud), MLX local (3B, 7B, and 14B), and Apple Intelligence (native macOS 26). Apple Intelligence ran on a 5-meeting subset (it is minutes-per-meeting, see below).

Quality grades are a provisional Claude hand-read of the side-by-side outputs against the Anthropic baseline (the dogfood design calls for human grading, since an LLM grading an LLM against a third LLM is circular). They are flagged for owner spot-check. The extraction counts and latencies are objective.

## TL;DR recommendation

- **Best quality, non-sensitive meetings: Anthropic (cloud).** Clearly the most complete and precise; fast. The default for anything that may leave the machine.
- **Privacy / regulated / NDA: MLX 7B (the recommended local default).** It captures about as much as the 14B (hand-graded ~0.56 vs ~0.61 on the same meetings, within noise) with *better* owner naming (real names, not speaker labels), zero failures over 26 meetings, ~30% lower latency (~57 s vs ~84 s), and at ~4.3 GB it never risks the OOM that hung this Mac. The 14B's extra size buys little quality here.
- **Max local quality only with ample RAM: MLX 14B.** Marginally better capture on some meetings, but memory-bound (OOM-unsafe above ~13k-char / ~16k-token transcripts here), slower, and it translated a Ukrainian meeting into Russian.
- **Last resort / very tight RAM: MLX 3B.** Fast and tiny, but vague, and one of 26 produced invalid output. Use only when the 7B will not fit.
- **Apple Intelligence: not yet.** Native, free, and zero-egress, the right long-term posture, but the 4096-token context makes it slow (minutes per meeting) and lossy on real meetings, and it mishandles Ukrainian. Revisit after LOCAL3 (hierarchical reduce, which this run had to prototype) and better language handling, or a larger system-model context.

## Per-engine summary

| Engine | avg actions | avg bullets | action capture vs Anthropic | latency / meeting | privacy | quality (hand) |
|---|---|---|---|---|---|---|
| Anthropic (cloud) | 7.3 | 5.0 | baseline | seconds | cloud egress | A (most complete + precise) |
| MLX 14B (local) | 3.9 | 5.0 | ~0.6 | ~84 s | on-device | B (good gist, under-captures, generic owners) |
| MLX 7B (local) | 4.0 | 5.1 | ~0.56 | ~57 s | on-device | B (on par with 14B, better owners, no failures) |
| MLX 3B (local) | 2.8 | 5.0 | lower | ~36 s | on-device | C (fast, vague, 1/26 failed) |
| Apple Intelligence | 5.8 | 11.3 | lowest | ~86 s+ | on-device | D (slow, lossy, mishandles uk) |

Latency is summarization wall-clock on this Mac and includes a fresh per-meeting model load for the MLX backends (a warm resident server is faster but holds the model in RAM, ~8 GB for the 14B, ~4.3 GB for the 7B). Apple Intelligence is the map+reduce total over its chunks and was measured only on the smallest meetings (a 6-chunk meeting already took ~164 s). "Action capture" is the fraction of Anthropic's action items the engine also surfaced; the dogfood gate (>= 0.80) is in `docs/local-llm-quality.md`.

## What each engine does well and badly

**Anthropic.** The most exhaustive and specific: more action items (avg 7.3 vs the locals' 3 to 4), named owners, well-phrased decisions, and it preserved the meeting's language (kept Ukrainian as Ukrainian). The only backend that transmits off-device. The quality baseline the others are measured against, so it scores 1.00 by construction.

**MLX 7B (recommended local).** The sweet spot. It extracts about as many actions as the 14B (avg 4.0 vs 3.9) and captured a similar fraction by hand (~0.56), but with consistently *named* owners (Anisha, Davendra, Georgi) where the 14B fell back to speaker labels, sensible titles, and not one of the 26 failed to produce valid JSON. It is ~30% faster than the 14B and, at ~4.3 GB resident, sits well clear of the memory cliff, so it would never have caused the OOM hang the 14B did. Its one shared local weakness: on the Ukrainian meeting it summarized in English rather than Ukrainian (Anthropic kept Ukrainian). For an English-reading owner that drift is more useful than the 14B's drift to Russian, but it still ignores the `summary_language = auto` intent.

**MLX 14B.** Coherent and usable, marginally the strongest local on raw capture (it matched Anthropic ~0.85 to 0.9 on light meetings), but it systematically extracts fewer items, so on dense meetings (Anthropic found 9 to 13 actions) it captured about a third, for a hand-graded ~0.42 to 0.61 across samples. Owners are often generic speaker labels. It translated a Ukrainian meeting into Russian (neither the source language nor English), and it is memory-bound here (the OOM that hung the Mac). The extra ~3.7 GB over the 7B does not pay for itself on these meetings.

**MLX 3B.** Fast (about half the 14B's time) and light enough to never threaten memory, but the quality cost is steep: vaguer decisions ("tasks assigned to team members for review"), generic titles, fewer and less specific actions, and on one of the 26 it failed to produce schema-valid JSON after the three repair attempts (a real reliability gap: that meeting would fail in the pipeline). Acceptable only as the fallback when the 7B cannot run.

**Apple Intelligence.** The appealing posture (native, free, fully on-device) is undercut by the system model's 4096-token context. Real meetings must be chunked into many windows and map-reduced, which is slow (about 86 s even on the smallest meetings, ~164 s on a six-chunk one, and it would be minutes on a full-length meeting) and lossy: on a short meeting it echoed raw dialogue fragments instead of summarizing, emitted a malformed language code, ignored the bullet-count cap (avg 11 bullets vs the requested 5), and one of the five attempted failed. Ukrainian tokenizes at ~1.7 tokens/char, so a 3200-char window overflowed the context, and a flat reduce overflows too (this is exactly the open LOCAL3 task; this run worked around it with a hierarchical batched reduce). Not usable as a daily summarizer today, but worth revisiting: LOCAL3 plus a language fix would help, and Apple may widen the context.

## The dogfood ship-decision (local)

`docs/local-llm-quality.md`, generated by `mp dogfood --report`, records **DO NOT SHIP** the local model as the silent default auto-summary: hand-graded action capture ~0.42 to 0.56 and decision capture ~0.52 sit below the 0.80 acceptance gate for both the 14B and the 7B. This does not mean the local path is useless: it is the correct choice when privacy requires it, with the understanding that it under-captures on busy meetings. The 7B is the right local model to standardize on; the 14B is not worth its memory and latency cost for the marginal capture gain.

## How to choose each engine

- `summarization.backend = "anthropic" | "local" | "apple_intelligence"` (Preferences > Pipeline).
- `summarization.local_model` selects the MLX size. **Recommended: `mlx-community/Qwen2.5-7B-Instruct-4bit`** (the current default is the 14B; switching to the 7B is the actionable outcome of this comparison). Sizes are A/B-able directly with `mp dogfood --local-model <repo>` (added with this comparison).
- Regulated / NDA workflows force the local path regardless (the egress guard), so whatever `local_model` is set to is what those meetings get; standardizing on the 7B makes that path both safer (no OOM) and better-attributed.

## Re-run

```bash
cd pipeline
uv run mp dogfood --runs-dir runs/mlx-14b <transcript.md>                              # vs 14B
uv run mp dogfood --local-model mlx-community/Qwen2.5-7B-Instruct-4bit \
  --runs-dir runs/mlx-7b <transcript.md>                                              # vs 7B
uv run mp dogfood --local-model mlx-community/Qwen2.5-3B-Instruct-4bit \
  --runs-dir runs/mlx-3b <transcript.md>                                              # vs 3B
swift ../daemon/scripts/ai-summarize.swift <transcript.md> out.ai.json "" auto        # Apple Intelligence
python3 ../scripts/engine_compare_report.py --runs runs                               # synthesize draft
```

Run the local backends under `caffeinate -dims` and a memory watchdog: the 14B is OOM-unsafe above ~13k-char / ~16k-token transcripts on this Mac (see [`docs/spikes/ai2-embedding-rag-latency.md`](spikes/ai2-embedding-rag-latency.md)); the 7B and 3B are memory-safe.
