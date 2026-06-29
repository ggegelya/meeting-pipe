"""Tests for the AI2 RAG-latency spike harness.

CI-safe: the only impure dependency (the MLX generation client) is faked, and
the embedder falls back to the numpy `HashingEmbedder` when MLX is absent. No
server, no network.
"""
from __future__ import annotations

import json
import re
from pathlib import Path

from mp import ai2_spike
from mp.ai2_spike import (
    SizeResult,
    StreamTiming,
    build_needle_context,
    make_needle_probe,
    pack_context,
    recommend,
    score_citation,
)
from mp.embed_index import Chunk


def _chunks(*specs: tuple[str, str]) -> list[Chunk]:
    return [Chunk(stem=s, title=t, index=0, text=t) for s, t in specs]


class FakeGen:
    """Echoes any planted codename + its source tag from the prompt, so the
    needle scoring path runs end-to-end deterministically. Latency contexts have
    no planted fact, so they get a generic answer."""

    def __init__(self) -> None:
        self.closed = False
        self.calls = 0

    def stream(self, *, system: str, user: str, max_tokens: int) -> StreamTiming:
        self.calls += 1
        token_match = re.search(r"codename .*? is (\w+)", user)
        stem_match = re.search(r"\[(needle-\d+)\]", user)
        if token_match and stem_match:
            text = f"The codename is {token_match.group(1)}, per [{stem_match.group(1)}]."
        else:
            text = "Several decisions and a couple of action items were discussed."
        return StreamTiming(
            ttft_sec=0.5,
            total_sec=1.0,
            text=text,
            prompt_tokens=max(1, len(user) // 4),
            completion_tokens=max(1, len(text) // 4),
        )

    def close(self) -> None:
        self.closed = True


# ----- pack_context -----


def test_pack_context_marks_citations_and_respects_budget() -> None:
    chunks = _chunks(("m1", "alpha topic"), ("m2", "beta topic"), ("m3", "gamma topic"))
    context, stems = pack_context(chunks, target_chars=40)
    assert "[m1]" in context
    assert stems[0] == "m1"
    # budget caps how many blocks land; not all three fit in 40 chars.
    assert len(context) <= 80
    assert len(stems) < 3


def test_pack_context_always_includes_at_least_one_block() -> None:
    chunks = _chunks(("m1", "a very long single block of text that exceeds the tiny budget"))
    context, stems = pack_context(chunks, target_chars=5)
    assert stems == ["m1"]  # first block always admitted even when over budget


# ----- needle probes -----


def test_build_needle_context_inserts_fact_and_tag() -> None:
    probe = make_needle_probe(0)
    distractors = _chunks(("d1", "distractor one"), ("d2", "distractor two"))
    ctx = build_needle_context(probe, distractors, target_chars=400, position=1)
    assert f"[{probe.expected_stem}]" in ctx
    assert probe.answer_token in ctx


def test_score_citation_combinations() -> None:
    probe = make_needle_probe(2)
    good = f"The codename is {probe.answer_token}, see [{probe.expected_stem}]."
    assert score_citation(good, probe) == {"faithful": True, "cited": True}
    assert score_citation(f"The codename is {probe.answer_token}.", probe)["cited"] is False
    assert score_citation("I could not find a codename.", probe) == {"faithful": False, "cited": False}


# ----- recommend -----


def _size(tokens: int, ttft: float, faith: float) -> SizeResult:
    return SizeResult(
        target_tokens=tokens,
        actual_prompt_tokens=tokens,
        prompt_tokens_estimated=False,
        median_ttft_sec=ttft,
        median_total_sec=ttft + 2,
        median_prefill_tok_s=tokens / ttft if ttft else 0.0,
        median_decode_tok_s=20.0,
        faithfulness=faith,
        citation_accuracy=faith,
        probe_count=3,
    )


def test_recommend_interactive_when_all_sizes_clear_bars() -> None:
    rec = recommend([_size(4000, 1.0, 1.0), _size(8000, 2.0, 1.0), _size(16000, 4.0, 0.9)])
    assert rec.verdict == "interactive"
    assert rec.recommended_context_tokens == 16000


def test_recommend_bounded_when_large_context_is_slow() -> None:
    rec = recommend([_size(4000, 2.0, 1.0), _size(8000, 8.0, 1.0), _size(16000, 25.0, 1.0)])
    assert rec.verdict == "interactive-bounded"
    assert rec.recommended_context_tokens == 8000


def test_recommend_async_when_nothing_clears() -> None:
    rec = recommend([_size(4000, 14.0, 1.0), _size(8000, 30.0, 1.0)])
    assert rec.verdict == "async-only"
    assert rec.recommended_context_tokens == 0


def test_recommend_faithfulness_gate_blocks_fast_but_unfaithful() -> None:
    # Fast TTFT but the small model is not faithful at the larger size.
    rec = recommend([_size(4000, 1.0, 1.0), _size(8000, 2.0, 0.3)])
    assert rec.verdict == "interactive-bounded"
    assert rec.recommended_context_tokens == 4000


# ----- main() plumbing -----


def _meeting(root: Path, stem: str, *, title: str, transcript: str) -> None:
    root.mkdir(parents=True, exist_ok=True)
    (root / f"{stem}.md").write_text(transcript, encoding="utf-8")
    (root / f"{stem}.summary.json").write_text(json.dumps({"title": title}), encoding="utf-8")
    (root / f"{stem}.summary.md").write_text(f"# {title}\n", encoding="utf-8")


def test_main_runs_end_to_end_with_fake_client(tmp_path: Path, monkeypatch, capsys) -> None:
    lib = tmp_path / "lib"
    _meeting(lib, "m1", title="Budget", transcript="A: budget cut and a Q3 forecast review.\n")
    _meeting(lib, "m2", title="Hiring", transcript="A: interview loop, offers, headcount plan.\n")

    fake = FakeGen()
    monkeypatch.setattr(ai2_spike, "_make_client", lambda model: fake)

    out = tmp_path / "results.json"
    index_dir = tmp_path / "index"
    rc = ai2_spike.main(
        [
            "--dir", str(lib),
            "--sizes", "100,200",
            "--repeats", "1",
            "--probes", "2",
            "--index-dir", str(index_dir),
            "--out", str(out),
        ]
    )
    assert rc == 0
    assert fake.closed  # client lifecycle closed in the finally

    payload = json.loads(out.read_text())
    assert len(payload["sizes"]) == 2
    assert {s["target_tokens"] for s in payload["sizes"]} == {100, 200}
    for s in payload["sizes"]:
        assert "median_ttft_sec" in s and "median_total_sec" in s
        assert s["faithfulness"] == 1.0  # FakeGen echoes the planted needle
        assert s["citation_accuracy"] == 1.0
    # 0.5s TTFT + perfect faithfulness -> interactive
    assert payload["recommendation"]["verdict"] == "interactive"
    assert "VERDICT: interactive" in capsys.readouterr().out


def test_main_index_only_builds_and_stops(tmp_path: Path, monkeypatch) -> None:
    lib = tmp_path / "lib"
    _meeting(lib, "m1", title="Budget", transcript="A: budget cut.\n")

    # If a client were constructed, this would blow up -> proves --index-only skips it.
    monkeypatch.setattr(ai2_spike, "_make_client", lambda model: (_ for _ in ()).throw(AssertionError("no client")))

    index_dir = tmp_path / "index"
    rc = ai2_spike.main(["--dir", str(lib), "--index-only", "--index-dir", str(index_dir)])
    assert rc == 0
    assert (index_dir / "manifest.json").exists()


def test_main_empty_library_exits_nonzero(tmp_path: Path) -> None:
    rc = ai2_spike.main(["--dir", str(tmp_path / "empty"), "--index-dir", str(tmp_path / "ix")])
    assert rc == 1
