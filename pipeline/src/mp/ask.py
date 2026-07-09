"""`mp ask` - engine-backed, cited answers over the meeting library (AI3).

Retrieval-augmented "ask my meetings": retrieve the most relevant excerpts from
the on-device embedding index (`embed_index.py`, the AI2 artifact), synthesize a
natural-language answer with the configured engine, and carry `[stem]` citations
that are verified against the retrieved set so every presented citation resolves
to a real meeting on disk.

Zero-egress + backend: the answer runs through `engine.complete_text`, which
honours `effective_backend()` (regulated / NDA force the on-device path with no
cloud fallback) and routes through httpx, so the egress guard armed at entry
clamps it. Async by design: AI2's spike found on-device long-context synthesis is
too slow for live typing, so `mp ask` is one blocking call that returns the whole
answer (the daemon shows a spinner around it), with a ~4K-token context budget.

This replaces the FEAT2 TF-IDF ranker: retrieval is now semantic (embeddings),
and the output is an answer, not a ranked file list.
"""
from __future__ import annotations

import argparse
import json
import logging
import sys
from dataclasses import asdict, dataclass, field
from pathlib import Path

from . import embed_index, engine, entry, rag
from .config import Config

log = logging.getLogger("mp.ask")

# AI2's recommended context budget (~4K tokens on the 14B; 16K was unsafe on the
# owner's Mac). A generous chars-per-token estimate sizes the retrieved context;
# the model reports the real token count, this only bounds packing.
DEFAULT_CONTEXT_TOKENS = 4000
CHARS_PER_TOKEN = 4
# A meeting-recall answer is a few sentences; bound generation so the local
# path's wall-clock stays within AI2's budget.
ANSWER_MAX_TOKENS = 512


@dataclass
class Citation:
    stem: str
    title: str


@dataclass
class Answer:
    question: str
    answer: str
    citations: list[Citation] = field(default_factory=list)
    sources_considered: list[str] = field(default_factory=list)
    backend: str | None = None
    model: str | None = None
    # True when the model's own `[stem]` citations verified against the retrieved
    # set; False when we fell back to the top retrieved meeting as the source.
    verified: bool = False
    empty: bool = False
    error: str | None = None

    def to_json(self) -> dict:
        return asdict(self)


def _titles_by_stem(chunks: list[embed_index.Chunk]) -> dict[str, str]:
    titles: dict[str, str] = {}
    for c in chunks:
        titles.setdefault(c.stem, c.title)
    return titles


def answer_question(
    cfg: Config,
    index: embed_index.EmbeddingIndex,
    question: str,
    *,
    context_tokens: int = DEFAULT_CONTEXT_TOKENS,
    model: str | None = None,
) -> Answer:
    """Retrieve, synthesize, and verify citations for one question.

    Raises `engine.EngineError` if the backend cannot produce a completion; the
    empty-library case is handled by the caller (this assumes a non-empty index).
    """
    target_chars = max(1, context_tokens) * CHARS_PER_TOKEN
    # Retrieve generously, then pack to the char budget (mirrors the AI2 spike).
    k = max(8, target_chars // 500)
    hits = index.search(question, k=k)
    chunks = [h.chunk for h in hits]
    context, stems = rag.pack_context(chunks, target_chars)
    titles = _titles_by_stem(chunks)

    result = engine.complete_text(
        cfg,
        system_prompt=rag.RAG_SYSTEM,
        user_message=rag.rag_user(context, question),
        max_tokens=ANSWER_MAX_TOKENS,
        model=model,
    )

    verified = rag.verify_citations(result.text, stems)
    if verified:
        cited_stems, was_verified = verified, True
    else:
        # The model cited nothing that resolves (a weak local model may cite
        # poorly, per AI2). Fall back to the top retrieved meeting so the answer
        # still carries at least one real, verifiable citation.
        cited_stems, was_verified = stems[:1], False

    return Answer(
        question=question,
        answer=result.text,
        citations=[Citation(stem=s, title=titles.get(s, s)) for s in cited_stems],
        sources_considered=stems,
        backend=result.backend,
        model=result.model,
        verified=was_verified,
    )


def _empty_answer(question: str) -> Answer:
    return Answer(question=question, answer="No searchable meetings found.", empty=True)


def _render_text(ans: Answer) -> str:
    lines = [ans.answer]
    if ans.citations:
        lines.append("")
        lines.append("Sources:")
        for c in ans.citations:
            lines.append(f"  {c.title}  [{c.stem}]")
        if not ans.verified:
            lines.append("  (citation inferred from the closest matching meeting)")
    return "\n".join(lines)


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(
        prog="mp ask",
        description="Ask a natural-language question about your meetings, with cited answers (AI3).",
    )
    ap.add_argument("question", nargs="+", help="the question to ask")
    ap.add_argument("--dir", type=Path, default=None, help="override the recordings directory")
    ap.add_argument("--index-dir", type=Path, default=embed_index.DEFAULT_INDEX_DIR,
                    help="where the embedding index is cached")
    ap.add_argument("--context-tokens", type=int, default=DEFAULT_CONTEXT_TOKENS,
                    help=f"retrieved context budget in tokens (default {DEFAULT_CONTEXT_TOKENS})")
    ap.add_argument("--model", default=None,
                    help="override the answer model (14B is recommended for citation fidelity, per AI2)")
    ap.add_argument("--rebuild", action="store_true", help="force a rebuild of the embedding index")
    ap.add_argument("--out", type=Path, default=None, help="write the answer JSON to this file (for the daemon)")
    ap.add_argument("--json", action="store_true", dest="as_json", help="print JSON instead of text")
    args = ap.parse_args(argv)

    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")

    cfg = entry.prepare()  # SEC13: arm, then secrets. Library-wide, so no meeting anchor.

    root = Path(args.dir) if args.dir is not None else cfg.recording.output_dir
    question = " ".join(args.question).strip()

    def emit(ans: Answer, rc: int) -> int:
        if args.out is not None:
            Path(args.out).expanduser().write_text(
                json.dumps(ans.to_json(), indent=2, ensure_ascii=False), encoding="utf-8"
            )
        if args.as_json:
            print(json.dumps(ans.to_json(), indent=2, ensure_ascii=False))
        elif ans.error:
            print(ans.error, file=sys.stderr)
        else:
            print(_render_text(ans))
        return rc

    embedder = embed_index.default_embedder()
    index = embed_index.load_or_build(root, args.index_dir, embedder, rebuild=args.rebuild)
    if not index.chunks:
        return emit(_empty_answer(question), 0)

    try:
        ans = answer_question(cfg, index, question, context_tokens=args.context_tokens, model=args.model)
    except engine.EngineError as e:
        return emit(Answer(question=question, answer="", error=str(e)), 1)

    return emit(ans, 0)


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main(sys.argv[1:]))
