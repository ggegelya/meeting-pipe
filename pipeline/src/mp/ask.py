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

AI11 hardened the run around that shape after an ask ate all available memory and
the Mac hard-rebooted. Three of its five mechanisms are here (the index lifecycle
is in `embed_index`): the context budget is sized on the *retrieved text's script
mix* instead of a Latin-calibrated constant, `--context-tokens` is clamped to what
this machine can answer with, and the retrieval embedder is released before the
answer model spawns, so the two never stack.
"""
from __future__ import annotations

import argparse
import json
import logging
import sys
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path

from . import embed_index, engine, entry, events, rag, resource_guard
from .config import Config, effective_backend

log = logging.getLogger("mp.ask")

# AI2's recommended context budget (~4K tokens on the 14B; 16K was unsafe on the
# owner's Mac). The retrieved pack is sized in characters, so the budget is only
# as honest as the chars-per-token rate used to convert it.
DEFAULT_CONTEXT_TOKENS = 4000

# LOCAL13 measured tokens-per-char over the real corpus: 0.22 to 0.25 for
# English, 0.47 to 0.49 for Ukrainian. Inverted here, at the token-hungriest end
# of each band, so the estimate errs small rather than over-packing.
#
# The flat `CHARS_PER_TOKEN = 4` this replaces was Latin-calibrated, which made a
# "4,000-token" Ukrainian pack ~7,800 real tokens: past the point where AI2
# measured the 14B aborting on the memory watchdog, and one of the mechanisms
# behind the 2026-07-29 incident (AI11).
LATIN_CHARS_PER_TOKEN = 4.0
CYRILLIC_CHARS_PER_TOKEN = 2.0

# A meeting-recall answer is a few sentences; bound generation so the local
# path's wall-clock stays within AI2's budget.
ANSWER_MAX_TOKENS = 512

# Backends whose answer runs on this machine's RAM, and so must respect the tier
# ceiling. `auto` is in here because its fallback leg is the same local model:
# clamping costs a cloud answer a little context, while not clamping costs the
# fallback leg the guarantee this task exists to make.
ON_DEVICE_BACKENDS = frozenset({"local", "apple_intelligence", "auto"})


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


def cyrillic_share(text: str) -> float:
    """Fraction of `text`'s letters that are Cyrillic. Punctuation, digits, and
    whitespace are excluded: they are the part of a transcript whose token cost
    does not swing between the two scripts, so counting them would dilute a
    genuinely Ukrainian pack toward the English rate."""
    letters = 0
    cyrillic = 0
    for ch in text:
        if ch.isalpha():
            letters += 1
            if "Ѐ" <= ch <= "ԯ":  # Cyrillic + Cyrillic Supplement
                cyrillic += 1
    return cyrillic / letters if letters else 0.0


def chars_per_token(text: str) -> float:
    """Chars-per-token for `text`, interpolated between LOCAL13's two measured
    rates by its Cyrillic share. A mixed en/uk library is the normal case here,
    so a blend beats picking one side; an all-Latin text gets exactly the old
    constant, which is why this cannot make an English ask worse."""
    share = cyrillic_share(text)
    return LATIN_CHARS_PER_TOKEN + (CYRILLIC_CHARS_PER_TOKEN - LATIN_CHARS_PER_TOKEN) * share


def context_ceiling(cfg: Config) -> int | None:
    """The safe context-token ceiling for the backend this config will answer on,
    or None when nothing here can judge it (a cloud answer, or unreadable RAM).

    The table is LOCAL16's tier policy, not a second copy of the AI2 numbers:
    `context_token_ceiling` is exactly what those measurements produced (4K safe
    everywhere, 8K only on a 32 GB machine, 16K nowhere local today), and one
    table is what keeps the summarize path and the ask path agreeing.
    """
    if effective_backend(cfg) not in ON_DEVICE_BACKENDS:
        return None
    ram_gb = resource_guard.physical_ram_gb()
    if ram_gb is None:
        return None
    return resource_guard.tier_for(ram_gb).context_token_ceiling


def clamp_context_tokens(cfg: Config, requested: int) -> int:
    """`requested`, held at the machine's ceiling. `--context-tokens` was
    unclamped, so a big number was a documented way to take the Mac down."""
    requested = max(1, requested)
    ceiling = context_ceiling(cfg)
    if ceiling is None or requested <= ceiling:
        return requested
    log.warning(
        "context budget %d tokens is above what this Mac can answer with safely; "
        "using %d instead", requested, ceiling,
    )
    events.emit("pipeline", "ask_context_clamped", requested=requested, ceiling=ceiling)
    return ceiling


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
    budget_tokens = clamp_context_tokens(cfg, context_tokens)
    # Retrieve generously at the Latin rate (the widest the budget can be), so a
    # Cyrillic-heavy library is not starved of candidates before packing gets to
    # apply the real rate below.
    k = max(8, int(budget_tokens * LATIN_CHARS_PER_TOKEN) // 500)
    hits = index.search(question, k=k)
    chunks = [h.chunk for h in hits]
    # The retrieved set is a superset of what gets packed, so its script mix is
    # the honest basis for the rate (AI11): sizing on the query's script, or on a
    # constant, is what put a "4K" Ukrainian pack at ~7.8K real tokens.
    rate = chars_per_token("\n".join(c.text for c in chunks))
    target_chars = max(1, int(budget_tokens * rate))
    context, stems = rag.pack_context(chunks, target_chars)
    titles = _titles_by_stem(chunks)

    # AI11: retrieval is finished, so let go of the embedding model before the
    # answer spawns one of its own. The two used to be resident together for the
    # whole answer, for no benefit; a later `index.search` would just reload it.
    index.release_embedder()

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

    events.emit(
        "pipeline", "ask_answered",
        backend=result.backend, model=result.model,
        retrieved_stems=len(stems), context_tokens=budget_tokens,
        packed_tokens=int(len(context) / rate), packed_chars=len(context),
        chars_per_token=round(rate, 2), verified=was_verified,
    )

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
                    help=f"retrieved context budget in tokens (default {DEFAULT_CONTEXT_TOKENS}); "
                         "clamped to what this Mac's RAM tier can answer with")
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

    started = time.monotonic()

    def beat(stage: str, **extra: object) -> None:
        events.emit_progress(stage, elapsed_s=int(time.monotonic() - started), **extra)

    # The heartbeat shares stdout with `--json`'s payload, so it stays off in
    # that mode: a caller piping `mp ask --json` into a parser must get JSON and
    # nothing else. The daemon reads `--out`, so the app keeps its beats.
    def on_progress(p: embed_index.IndexProgress) -> None:
        beat("indexing", stems_done=p.stems_done, stems_total=p.stems_total,
             chunks_done=p.chunks_done)

    embedder = embed_index.default_embedder()
    # LOCAL16's watchdog, on the path its own incident report named. Constructed
    # here rather than inside the index so the floor comes from config exactly
    # once per run.
    watchdog = resource_guard.MemoryWatchdog(floor_pct=cfg.summarization.local_memory_floor_pct)
    try:
        index = embed_index.load_or_build(
            root, args.index_dir, embedder, rebuild=args.rebuild,
            watchdog=watchdog, on_progress=None if args.as_json else on_progress,
        )
    except (resource_guard.ResourceGuardError, embed_index.EmbedderUnavailableError) as e:
        # A guard abort is a real answer to the question "why did this stop":
        # surfaced verbatim, and (for the memory case) carrying the marker phrase
        # the daemon matches to say `memory` rather than a generic failure.
        return emit(Answer(question=question, answer="", error=str(e)), 1)
    if not index.chunks:
        return emit(_empty_answer(question), 0)

    if not args.as_json:
        beat("answering")
    try:
        ans = answer_question(cfg, index, question, context_tokens=args.context_tokens, model=args.model)
    except engine.EngineError as e:
        return emit(Answer(question=question, answer="", error=str(e)), 1)
    except resource_guard.ResourceGuardError as e:
        # The answer model has its own watchdog and tier refusal (LOCAL16); they
        # reach here as themselves rather than as an opaque engine failure.
        return emit(Answer(question=question, answer="", error=str(e)), 1)

    return emit(ans, 0)


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main(sys.argv[1:]))
