"""Tests for the durable RAG assembly + citation verification (AI3)."""
from __future__ import annotations

from mp.embed_index import Chunk
from mp.rag import extract_citations, pack_context, rag_user, verify_citations


def _chunk(stem: str, text: str, title: str = "Sync") -> Chunk:
    return Chunk(stem=stem, title=title, index=0, text=text)


def test_pack_context_marks_each_block_with_its_stem() -> None:
    chunks = [_chunk("20260101-0900", "budget cut"), _chunk("20260102-1000", "hiring plan")]
    context, stems = pack_context(chunks, target_chars=10_000)
    assert "[20260101-0900]" in context
    assert "[20260102-1000]" in context
    assert stems == ["20260101-0900", "20260102-1000"]


def test_pack_context_respects_budget() -> None:
    chunks = [_chunk(f"m{i:02d}", "x" * 100) for i in range(20)]
    context, stems = pack_context(chunks, target_chars=250)
    # Budget stops well before all 20 blocks are packed.
    assert 0 < len(stems) < 20
    assert len(context) <= 300  # a little slack for the citation markers


def test_pack_context_always_includes_at_least_one_block() -> None:
    chunks = [_chunk("only", "a" * 500)]
    context, stems = pack_context(chunks, target_chars=5)
    assert stems == ["only"]
    assert "[only]" in context


def test_pack_context_dedups_stems_but_keeps_order() -> None:
    chunks = [_chunk("m1", "first"), _chunk("m1", "second"), _chunk("m2", "third")]
    _, stems = pack_context(chunks, target_chars=10_000)
    assert stems == ["m1", "m2"]


def test_rag_user_includes_context_and_question() -> None:
    user = rag_user("EXCERPTS", "what happened?")
    assert "EXCERPTS" in user
    assert "what happened?" in user


def test_extract_citations_finds_dedups_and_orders() -> None:
    ans = "We decided X [20260101-0900] and Y [20260102-1000], see [20260101-0900] again."
    assert extract_citations(ans) == ["20260101-0900", "20260102-1000"]


def test_extract_citations_empty_when_none() -> None:
    assert extract_citations("no citations here") == []


def test_verify_citations_keeps_only_retrieved() -> None:
    ans = "From [20260101-0900] and the invented [99999999-9999]."
    verified = verify_citations(ans, retrieved_stems=["20260101-0900", "20260102-1000"])
    assert verified == ["20260101-0900"]  # the hallucinated stem is dropped


def test_verify_citations_empty_when_all_hallucinated() -> None:
    ans = "From [made-up] only."
    assert verify_citations(ans, retrieved_stems=["20260101-0900"]) == []
