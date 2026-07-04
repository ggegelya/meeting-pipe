"""Durable RAG assembly for engine-backed answers over the meeting library (AI3).

Packs retrieved `embed_index.Chunk`s into a context that tags each excerpt with
its `[stem]` citation marker, frames the question, and - after the model answers
- verifies which citations the model emitted actually correspond to a retrieved
meeting. Verification is what makes AI3's citations trustworthy: a `[stem]` the
model invented (or mangled) is dropped, so a presented citation always resolves
to a real meeting on disk.

Pure and stdlib-only (no engine, no numpy), so the assembly + verification are
unit-testable without a model. The AI2 spike (`ai2_spike.py`) carries its own
copy of the packing shape as throwaway measurement scaffolding; this is the
version `mp ask` ships on.
"""
from __future__ import annotations

import re

from .embed_index import Chunk

# The synthesis system prompt. Deliberately strict: answer only from the
# excerpts, cite the `[stem]` tag(s) used, and say so plainly when the excerpts
# do not contain the answer (an honest "not found" beats a confident fabrication
# for a meeting recall tool).
RAG_SYSTEM = (
    "You answer questions about the user's past meetings using ONLY the provided "
    "excerpts. Each excerpt begins with its source tag in square brackets, e.g. "
    "[20260512-1030]. When you use an excerpt, cite its source tag verbatim in "
    "square brackets in your answer. Cite at least one source. If the excerpts do "
    "not contain the answer, say so plainly rather than guessing. Be concise and "
    "specific; prefer naming the meeting a fact came from."
)

# `[stem]` citation token. Stems are the recording filename stems the daemon
# writes (`YYYYMMDD-HHMMSS`, plus the `needle-NN` / test stems), so the marker
# alphabet is word chars + hyphen; anything else ends the token.
_CITATION_RE = re.compile(r"\[([A-Za-z0-9][\w-]*)\]")


def _chunk_block(stem: str, title: str, text: str) -> str:
    """One excerpt, prefixed with its `[stem]` citation marker and title."""
    return f"[{stem}] {title}\n{text}"


def pack_context(chunks: list[Chunk], target_chars: int) -> tuple[str, list[str]]:
    """Pack retrieved chunks into a context up to `target_chars`, each prefixed
    with its `[stem]` citation marker. Returns (context, distinct stems in order).

    At least one block is always included even if it exceeds the budget, so a
    tiny budget never yields an empty (citation-less) context.
    """
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
    return "\n\n".join(blocks), stems


def rag_user(context: str, question: str) -> str:
    """The user turn: the packed excerpts then the question."""
    return f"Meeting excerpts:\n\n{context}\n\n---\n\nQuestion: {question}"


def extract_citations(answer: str) -> list[str]:
    """Every `[stem]`-style token the model wrote, in first-seen order (deduped)."""
    seen: list[str] = []
    for m in _CITATION_RE.findall(answer):
        if m not in seen:
            seen.append(m)
    return seen


def verify_citations(answer: str, retrieved_stems: list[str]) -> list[str]:
    """The subset of the model's `[stem]` citations that actually name a retrieved
    meeting, in the model's citation order. A hallucinated or mangled tag is
    dropped, so every returned stem resolves to a real chunk that was in context.
    """
    allowed = set(retrieved_stems)
    return [c for c in extract_citations(answer) if c in allowed]
