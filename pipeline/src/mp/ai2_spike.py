"""AI2 spike: long-context RAG latency + faithfulness on the local engine.

Throwaway measurement harness (the durable artifact is `embed_index.py`). It:

1. builds the on-device embedding index over the library,
2. assembles RAG contexts at target prompt sizes (4K / 8K / 16K tokens),
3. drives the configured local MLX chat model with a streaming request to
   capture time-to-first-token and total wall-clock (MLX prefills the whole
   context before the first token, so TTFT at RAG-scale context is the
   load-bearing risk this spike exists to measure), and
4. runs needle-in-haystack probes for a faithfulness + citation-accuracy read.

It returns a go/no-go on interactive vs async chat and a recommended context
budget, written to a results JSON and printed as a table.

Zero egress by construction: the chat traffic is loopback (`mlx_lm.server` on
127.0.0.1) and the embedding runs in-process. `arm_for_config()` is called at
entry so the structural guard is in place regardless of the configured backend.
"""
from __future__ import annotations

import argparse
import json
import logging
import statistics
import sys
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Protocol

from . import embed_index

log = logging.getLogger("mp.ai2_spike")

DEFAULT_SIZES = (4000, 8000, 16000)
# Prompt packing uses a chars-per-token estimate; the server reports the real
# `prompt_tokens`, so the estimate only sizes the context, it is not reported.
CHARS_PER_TOKEN = 4
# Bound generation so total wall-clock is prefill-dominated (the thing we are
# measuring), not decode-dominated. A real RAG answer is a few hundred tokens.
LATENCY_GEN_TOKENS = 256
NEEDLE_GEN_TOKENS = 96

# Go/no-go bars (documented, overridable). Interactive chat needs the first
# token fast; below this the user is staring at a blank panel.
INTERACTIVE_TTFT_SEC = 10.0
MIN_FAITHFULNESS = 0.8

_RAG_SYSTEM = (
    "You answer questions about the user's past meetings using ONLY the provided "
    "excerpts. Each excerpt begins with its source tag in square brackets, e.g. "
    "[20260512-1030]. Cite the source tag(s) you used, in square brackets, in your "
    "answer. If the excerpts do not contain the answer, say so plainly. Be concise."
)

_LATENCY_QUERY = "What were the main decisions and open action items across these meetings?"

# Unique, model-unlikely tokens for the needle probes (no real meeting says these).
_NEEDLE_TOKENS = ("BLUEHERON", "ZEPHYRCAP", "QUARTZMOLE", "VERMILIONYAK", "OBSIDIANFERN", "TUNDRAGLASS")


# --------------------------------------------------------------------------- #
# Generation client (the only impure dependency; faked in tests)
# --------------------------------------------------------------------------- #


@dataclass
class StreamTiming:
    ttft_sec: float
    total_sec: float
    text: str
    prompt_tokens: int
    completion_tokens: int
    prompt_tokens_estimated: bool = False


class GenerationClient(Protocol):
    def stream(self, *, system: str, user: str, max_tokens: int) -> StreamTiming: ...

    def close(self) -> None: ...


class MLXStreamClient:
    """Drives the configured local model over `mlx_lm.server`, reusing
    `LocalSummaryClient` for the spawn/health/idle/terminate lifecycle and then
    issuing a streaming chat-completion so the first content delta gives a true
    TTFT (vs the blocking call `summarize()` makes)."""

    def __init__(self, model: str, *, startup_timeout_sec: float = 300.0) -> None:
        self._model = model
        self._startup = startup_timeout_sec
        self._local = None

    def _ensure_server(self):
        """Spawn + health-check on first use, and hand the client back so callers
        hold a non-None reference rather than re-reading the optional attribute."""
        from .summarize_local import LocalSummaryClient

        if self._local is None:
            self._local = LocalSummaryClient(model=self._model, startup_timeout_sec=self._startup)
        self._local._ensure_running()  # spawn + health; the warm internal path
        return self._local

    def stream(self, *, system: str, user: str, max_tokens: int) -> StreamTiming:
        import httpx

        base = self._ensure_server().base_url
        payload = {
            "model": self._model,
            "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
            "max_tokens": max_tokens,
            "temperature": 0.2,
            "stream": True,
            "stream_options": {"include_usage": True},
        }
        ttft: float | None = None
        pieces: list[str] = []
        prompt_tokens = 0
        completion_tokens = 0
        start = time.monotonic()
        with httpx.Client(timeout=httpx.Timeout(900.0, connect=5.0)) as client:
            with client.stream("POST", f"{base}/v1/chat/completions", json=payload) as resp:
                resp.raise_for_status()
                for line in resp.iter_lines():
                    if not line or not line.startswith("data:"):
                        continue
                    data = line[len("data:") :].strip()
                    if data == "[DONE]":
                        break
                    try:
                        obj = json.loads(data)
                    except json.JSONDecodeError:
                        continue
                    for choice in obj.get("choices") or []:
                        content = (choice.get("delta") or {}).get("content")
                        if content:
                            if ttft is None:
                                ttft = time.monotonic() - start
                            pieces.append(content)
                    usage = obj.get("usage")
                    if isinstance(usage, dict):
                        prompt_tokens = int(usage.get("prompt_tokens", prompt_tokens) or prompt_tokens)
                        completion_tokens = int(usage.get("completion_tokens", completion_tokens) or completion_tokens)
        total = time.monotonic() - start
        text = "".join(pieces)
        estimated = False
        if prompt_tokens == 0:
            prompt_tokens = max(1, len(system) + len(user)) // CHARS_PER_TOKEN
            estimated = True
        if completion_tokens == 0:
            completion_tokens = max(1, len(text) // CHARS_PER_TOKEN)
        return StreamTiming(ttft if ttft is not None else total, total, text, prompt_tokens, completion_tokens, estimated)

    def close(self) -> None:
        if self._local is not None:
            self._local.close()


def _make_client(model: str) -> GenerationClient:
    """Indirection so tests can swap a fake without a server."""
    return MLXStreamClient(model)


# --------------------------------------------------------------------------- #
# Pure helpers (unit-tested)
# --------------------------------------------------------------------------- #


def _chunk_block(stem: str, title: str, text: str) -> str:
    return f"[{stem}] {title}\n{text}"


def _pack_blocks(chunks: list[embed_index.Chunk], target_chars: int) -> tuple[list[str], list[str]]:
    blocks: list[str] = []
    stems: list[str] = []
    used = 0
    for c in chunks:
        block = _chunk_block(c.stem, c.title, c.text)
        if used + len(block) + 2 > target_chars and blocks:
            break
        blocks.append(block)
        if c.stem not in stems:
            stems.append(c.stem)
        used += len(block) + 2
    return blocks, stems


def pack_context(chunks: list[embed_index.Chunk], target_chars: int) -> tuple[str, list[str]]:
    """Pack retrieved chunks into a context up to `target_chars`, each prefixed
    with its `[stem]` citation marker. Returns (context, stems in order)."""
    blocks, stems = _pack_blocks(chunks, target_chars)
    return "\n\n".join(blocks), stems


def rag_user(context: str, question: str) -> str:
    return f"Meeting excerpts:\n\n{context}\n\n---\n\nQuestion: {question}"


@dataclass
class NeedleProbe:
    question: str
    fact: str
    answer_token: str
    expected_stem: str


def make_needle_probe(i: int) -> NeedleProbe:
    """A unique planted fact + the stem it lives under. The answer is verifiable
    (a token no real meeting contains), so faithfulness and citation accuracy are
    scorable without ground-truth over the real corpus and without depending on
    retrieval recall (the needle is inserted, not retrieved)."""
    token = _NEEDLE_TOKENS[i % len(_NEEDLE_TOKENS)]
    return NeedleProbe(
        question="What is the internal project codename mentioned in the excerpts? "
        "Answer with the codename and cite the [source] it came from.",
        fact=f"For the record, the internal project codename agreed in this meeting is {token}.",
        answer_token=token,
        expected_stem=f"needle-{i:02d}",
    )


def build_needle_context(
    probe: NeedleProbe, distractors: list[embed_index.Chunk], target_chars: int, position: int
) -> str:
    """A context of `target_chars` made of real distractor chunks with the
    probe's needle block inserted at `position` (clamped). The needle always
    fits: distractors are packed to the remaining budget first."""
    needle = _chunk_block(probe.expected_stem, "Planning sync", probe.fact)
    blocks, _ = _pack_blocks(distractors, max(0, target_chars - len(needle) - 2))
    pos = 0 if not blocks else max(0, min(position, len(blocks)))
    blocks.insert(pos, needle)
    return "\n\n".join(blocks)


def score_citation(answer: str, probe: NeedleProbe) -> dict:
    """faithful: the answer states the planted token (used the context).
    cited: the answer names the right source stem."""
    low = answer.lower()
    return {
        "faithful": probe.answer_token.lower() in low,
        "cited": probe.expected_stem.lower() in low,
    }


@dataclass
class SizeResult:
    target_tokens: int
    actual_prompt_tokens: int
    prompt_tokens_estimated: bool
    median_ttft_sec: float
    median_total_sec: float
    median_prefill_tok_s: float
    median_decode_tok_s: float
    faithfulness: float
    citation_accuracy: float
    probe_count: int
    runs: list[dict] = field(default_factory=list)


@dataclass
class Recommendation:
    verdict: str  # "interactive" | "interactive-bounded" | "async-only"
    recommended_context_tokens: int
    interactive_ttft_sec: float
    min_faithfulness: float
    rationale: str


def recommend(
    results: list[SizeResult],
    *,
    interactive_ttft_sec: float = INTERACTIVE_TTFT_SEC,
    min_faithfulness: float = MIN_FAITHFULNESS,
) -> Recommendation:
    """Go/no-go. A size is interactive-viable when its median TTFT clears the bar
    AND faithfulness holds. Recommended budget = the largest viable size."""
    if not results:
        return Recommendation("async-only", 0, interactive_ttft_sec, min_faithfulness, "no sizes measured")
    viable = [
        r.target_tokens
        for r in results
        if r.median_ttft_sec <= interactive_ttft_sec and r.faithfulness >= min_faithfulness
    ]
    budget = max(viable) if viable else 0
    largest = max(r.target_tokens for r in results)
    if budget >= largest:
        verdict = "interactive"
        rationale = (
            f"every tested size up to {largest} tokens keeps TTFT <= {interactive_ttft_sec:.0f}s "
            f"with faithfulness >= {min_faithfulness:.0%}; interactive chat is viable."
        )
    elif budget > 0:
        verdict = "interactive-bounded"
        rationale = (
            f"interactive up to {budget} tokens; larger contexts breach the "
            f"{interactive_ttft_sec:.0f}s TTFT or {min_faithfulness:.0%} faithfulness bar, so cap context "
            "for interactive chat and route larger asks to async."
        )
    else:
        verdict = "async-only"
        rationale = (
            f"no tested size clears TTFT <= {interactive_ttft_sec:.0f}s with faithfulness "
            f">= {min_faithfulness:.0%}; ship ask-AI as async (spinner/notification), not live chat."
        )
    return Recommendation(verdict, budget, interactive_ttft_sec, min_faithfulness, rationale)


@dataclass
class SpikeResult:
    gen_model: str
    embed_model: str
    library_root: str
    chunk_count: int
    repeats: int
    sizes: list[SizeResult]
    recommendation: Recommendation
    measured_at: str

    def to_json(self) -> dict:
        return {
            "gen_model": self.gen_model,
            "embed_model": self.embed_model,
            "library_root": self.library_root,
            "chunk_count": self.chunk_count,
            "repeats": self.repeats,
            "measured_at": self.measured_at,
            "sizes": [asdict(s) for s in self.sizes],
            "recommendation": asdict(self.recommendation),
        }


# --------------------------------------------------------------------------- #
# Measurement
# --------------------------------------------------------------------------- #


def _median(values: list[float]) -> float:
    return float(statistics.median(values)) if values else 0.0


def measure_size(
    index: embed_index.EmbeddingIndex,
    client: GenerationClient,
    target_tokens: int,
    *,
    repeats: int,
    probes: int,
) -> SizeResult:
    target_chars = target_tokens * CHARS_PER_TOKEN
    # Retrieve generously, then pack to the budget (16K tokens is ~50+ chunks).
    k = max(8, target_chars // 500)
    hits = index.search(_LATENCY_QUERY, k=k)
    distractors = [h.chunk for h in hits]
    context, _ = pack_context(distractors, target_chars)
    user = rag_user(context, _LATENCY_QUERY)

    runs: list[dict] = []
    for r in range(max(1, repeats)):
        # Prepend a per-run nonce so mlx_lm.server's prompt cache cannot serve a
        # prefix-cache hit on a repeated identical prompt: each run measures a
        # real fresh prefill, which is what a user asking distinct questions
        # actually pays. (Without this, repeats after the first read ~0s.)
        nonce_user = f"(retrieval session {r}/{target_tokens})\n{user}"
        t = client.stream(system=_RAG_SYSTEM, user=nonce_user, max_tokens=LATENCY_GEN_TOKENS)
        prefill_tok_s = t.prompt_tokens / t.ttft_sec if t.ttft_sec > 0 else 0.0
        decode_span = max(t.total_sec - t.ttft_sec, 1e-6)
        runs.append(
            {
                "ttft_sec": round(t.ttft_sec, 3),
                "total_sec": round(t.total_sec, 3),
                "prompt_tokens": t.prompt_tokens,
                "completion_tokens": t.completion_tokens,
                "prefill_tok_s": round(prefill_tok_s, 1),
                "decode_tok_s": round(t.completion_tokens / decode_span, 1),
                "prompt_tokens_estimated": t.prompt_tokens_estimated,
            }
        )

    faithful = cited = total = 0
    for i in range(max(0, probes)):
        probe = make_needle_probe(i)
        pos = 0 if probes <= 1 else int(i / (probes - 1) * len(distractors))
        nctx = build_needle_context(probe, distractors, target_chars, pos)
        nt = client.stream(system=_RAG_SYSTEM, user=rag_user(nctx, probe.question), max_tokens=NEEDLE_GEN_TOKENS)
        sc = score_citation(nt.text, probe)
        total += 1
        faithful += int(sc["faithful"])
        cited += int(sc["cited"])

    return SizeResult(
        target_tokens=target_tokens,
        actual_prompt_tokens=int(_median([r["prompt_tokens"] for r in runs])),
        prompt_tokens_estimated=any(r["prompt_tokens_estimated"] for r in runs),
        median_ttft_sec=round(_median([r["ttft_sec"] for r in runs]), 3),
        median_total_sec=round(_median([r["total_sec"] for r in runs]), 3),
        median_prefill_tok_s=round(_median([r["prefill_tok_s"] for r in runs]), 1),
        median_decode_tok_s=round(_median([r["decode_tok_s"] for r in runs]), 1),
        faithfulness=round(faithful / total, 3) if total else 0.0,
        citation_accuracy=round(cited / total, 3) if total else 0.0,
        probe_count=total,
        runs=runs,
    )


def _now_iso() -> str:
    from datetime import datetime, timezone

    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _print_table(result: SpikeResult) -> None:
    print()
    print(f"AI2 spike  gen={result.gen_model}  embed={result.embed_model}")
    print(f"library={result.library_root}  chunks={result.chunk_count}  repeats={result.repeats}")
    print()
    header = f"{'target':>8} {'tokens':>8} {'TTFT s':>8} {'total s':>8} {'prefill t/s':>12} {'decode t/s':>11} {'faith':>6} {'cite':>6}"
    print(header)
    print("-" * len(header))
    for s in result.sizes:
        star = "~" if s.prompt_tokens_estimated else " "
        print(
            f"{s.target_tokens:>8} {s.actual_prompt_tokens:>7}{star} {s.median_ttft_sec:>8.2f} "
            f"{s.median_total_sec:>8.2f} {s.median_prefill_tok_s:>12.1f} {s.median_decode_tok_s:>11.1f} "
            f"{s.faithfulness:>6.2f} {s.citation_accuracy:>6.2f}"
        )
    print()
    r = result.recommendation
    print(f"VERDICT: {r.verdict}  (recommended context budget: {r.recommended_context_tokens} tokens)")
    print(f"  {r.rationale}")
    if any(s.prompt_tokens_estimated for s in result.sizes):
        print("  (~ = prompt tokens estimated; server did not report usage)")


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(
        prog="mp ai2-spike",
        description="AI2 spike: on-device embedding index + long-context RAG latency and faithfulness.",
    )
    ap.add_argument("--sizes", default=",".join(str(s) for s in DEFAULT_SIZES),
                    help="comma-separated target prompt sizes in tokens (default 4000,8000,16000)")
    ap.add_argument("--repeats", type=int, default=2, help="latency runs per size (median reported)")
    ap.add_argument("--probes", type=int, default=3, help="needle-in-haystack probes per size")
    ap.add_argument("--embed-model", default=embed_index.DEFAULT_EMBED_MODEL)
    ap.add_argument("--gen-model", default=None, help="override the chat model (default: config local_model)")
    ap.add_argument("--index-dir", type=Path, default=embed_index.DEFAULT_INDEX_DIR)
    ap.add_argument("--reuse-index", action="store_true", help="reuse a saved index instead of rebuilding")
    ap.add_argument("--index-only", action="store_true", help="build the index and stop (no measurement)")
    ap.add_argument("--dir", type=Path, default=None, help="override the library (recordings) directory")
    ap.add_argument("--out", type=Path, default=None, help="write the results JSON here")
    ap.add_argument("--json", action="store_true", dest="as_json", help="print the results JSON to stdout")
    args = ap.parse_args(argv)

    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")

    from . import entry

    # SEC13 entry contract; zero-egress leaves loopback chat + in-process
    # embedding unaffected, so the spike runs identically under regulated mode.
    cfg = entry.prepare()
    root = Path(args.dir) if args.dir is not None else cfg.recording.output_dir
    gen_model = args.gen_model or cfg.summarization.local_model

    embedder = embed_index.default_embedder(args.embed_model)
    manifest = args.index_dir / "manifest.json"
    if args.reuse_index and manifest.exists():
        index = embed_index.EmbeddingIndex.load(args.index_dir, embedder)
        print(f"index: reused {len(index.chunks)} chunks from {args.index_dir} (model={index.model})")
    else:
        index = embed_index.EmbeddingIndex.build(root, embedder)
        index.save(args.index_dir)
        print(f"index: built {len(index.chunks)} chunks (model={index.model}, dim={index.dim}) -> {args.index_dir}")

    if args.index_only:
        return 0
    if not index.chunks:
        print(f"no searchable meetings under {root}; nothing to measure", file=sys.stderr)
        return 1

    sizes = [int(s) for s in args.sizes.split(",") if s.strip()]
    embed_model = args.embed_model if isinstance(embedder, embed_index.MLXEmbedder) else embedder.name

    def assemble(rs: list[SizeResult]) -> SpikeResult:
        return SpikeResult(
            gen_model=gen_model,
            embed_model=embed_model,
            library_root=str(root),
            chunk_count=len(index.chunks),
            repeats=args.repeats,
            sizes=rs,
            recommendation=recommend(rs),
            measured_at=_now_iso(),
        )

    size_results: list[SizeResult] = []
    client = _make_client(gen_model)
    try:
        for t in sizes:
            sr = measure_size(index, client, t, repeats=args.repeats, probes=args.probes)
            size_results.append(sr)
            log.info(
                "size %d: ttft=%.2fs total=%.2fs faithfulness=%.2f citation=%.2f (prompt~%d tok)",
                t, sr.median_ttft_sec, sr.median_total_sec, sr.faithfulness, sr.citation_accuracy,
                sr.actual_prompt_tokens,
            )
            # Persist after each size so an interrupted run keeps completed sizes
            # (16K full-prefill is slow and the long-meeting case most likely to
            # be cut off). The file is rewritten whole each time, not appended.
            if args.out is not None:
                Path(args.out).expanduser().write_text(
                    json.dumps(assemble(size_results).to_json(), indent=2), encoding="utf-8"
                )
    finally:
        client.close()

    result = assemble(size_results)
    if args.out is not None:
        print(f"results written to {args.out}")
    if args.as_json:
        print(json.dumps(result.to_json(), indent=2))
    else:
        _print_table(result)
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main(sys.argv[1:]))
