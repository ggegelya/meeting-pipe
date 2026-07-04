"""Tests for `mp ask` engine-backed cited answers (AI3).

CI-safe: retrieval runs on the numpy `HashingEmbedder` (no MLX), and the engine
is faked (no model, no socket). The real path under test is retrieve -> pack ->
synthesize -> verify-citations -> emit.
"""
from __future__ import annotations

import json
import re
from pathlib import Path

import pytest

from mp import ask
from mp.ask import Answer, answer_question
from mp.config import Config
from mp.embed_index import EmbeddingIndex, HashingEmbedder
from mp.engine import EngineError, EngineResult


def _meeting(root: Path, stem: str, *, title: str, transcript: str, summary: str = "") -> None:
    root.mkdir(parents=True, exist_ok=True)
    (root / f"{stem}.md").write_text(transcript, encoding="utf-8")
    (root / f"{stem}.summary.json").write_text(json.dumps({"title": title}), encoding="utf-8")
    (root / f"{stem}.summary.md").write_text(summary or f"# {title}\n", encoding="utf-8")


def _index(root: Path) -> EmbeddingIndex:
    return EmbeddingIndex.build(root, HashingEmbedder(dim=256))


def _cfg() -> Config:
    return Config.model_validate({"summarization": {"backend": "local", "local_model": "fake"}})


def _echo_first_stem_engine(cfg, *, system_prompt, user_message, max_tokens, model=None):
    """Fake engine that cites the first [stem] present in the packed context, i.e.
    behaves like a well-behaved model, so the verify path passes."""
    m = re.search(r"\[([\w-]+)\]", user_message)
    stem = m.group(1) if m else "none"
    return EngineResult(text=f"The answer to your question. [{stem}]", backend="local", model="fake")


def test_answer_question_cites_a_retrieved_meeting(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    _meeting(tmp_path, "20260101-0900", title="Budget review", transcript="A: we cut the budget hard.")
    _meeting(tmp_path, "20260102-1000", title="Hiring sync", transcript="A: interview loop and offers.")
    monkeypatch.setattr(ask.engine, "complete_text", _echo_first_stem_engine)

    ans = answer_question(_cfg(), _index(tmp_path), "what happened with the budget?")
    assert ans.answer
    assert ans.verified
    assert ans.citations, "an answer must carry at least one citation"
    assert ans.citations[0].stem in ans.sources_considered
    assert ans.citations[0].title  # title resolved from the chunk


def test_falls_back_to_top_source_when_model_cites_nothing_valid(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    _meeting(tmp_path, "20260101-0900", title="Budget", transcript="A: budget budget cut spend.")

    def _hallucinating_engine(cfg, *, system_prompt, user_message, max_tokens, model=None):
        return EngineResult(text="Answer with a made-up [99999999-9999] source.", backend="local", model="fake")

    monkeypatch.setattr(ask.engine, "complete_text", _hallucinating_engine)
    ans = answer_question(_cfg(), _index(tmp_path), "budget?")
    assert not ans.verified            # the invented citation did not verify
    assert len(ans.citations) == 1     # fell back to the top retrieved meeting
    assert ans.citations[0].stem == "20260101-0900"


def test_main_writes_out_file(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    root = tmp_path / "raw"
    _meeting(root, "20260101-0900", title="Budget review", transcript="A: we cut the budget.")
    monkeypatch.setattr(ask.Config, "load", classmethod(lambda cls: _cfg()))
    monkeypatch.setattr(ask.engine, "complete_text", _echo_first_stem_engine)

    out = tmp_path / "answer.json"
    rc = ask.main(["what about the", "budget", "--dir", str(root),
                   "--index-dir", str(tmp_path / "idx"), "--out", str(out)])
    assert rc == 0
    payload = json.loads(out.read_text(encoding="utf-8"))
    assert payload["answer"]
    assert payload["citations"][0]["stem"] == "20260101-0900"
    assert payload["backend"] == "local"


def test_main_empty_library_is_clean_exit(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    monkeypatch.setattr(ask.Config, "load", classmethod(lambda cls: _cfg()))
    out = tmp_path / "answer.json"
    rc = ask.main(["anything", "--dir", str(tmp_path / "empty"),
                   "--index-dir", str(tmp_path / "idx"), "--out", str(out)])
    assert rc == 0
    payload = json.loads(out.read_text(encoding="utf-8"))
    assert payload["empty"] is True
    assert payload["citations"] == []


def test_main_engine_error_returns_1_and_records_it(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    root = tmp_path / "raw"
    _meeting(root, "20260101-0900", title="Budget", transcript="A: budget cut.")
    monkeypatch.setattr(ask.Config, "load", classmethod(lambda cls: _cfg()))

    def _boom(cfg, **kwargs):
        raise EngineError("local model not installed")

    monkeypatch.setattr(ask.engine, "complete_text", _boom)
    out = tmp_path / "answer.json"
    rc = ask.main(["budget", "--dir", str(root), "--index-dir", str(tmp_path / "idx"), "--out", str(out)])
    assert rc == 1
    payload = json.loads(out.read_text(encoding="utf-8"))
    assert "not installed" in payload["error"]


def test_main_json_stdout(monkeypatch: pytest.MonkeyPatch, tmp_path: Path, capsys) -> None:
    root = tmp_path / "raw"
    _meeting(root, "20260101-0900", title="Budget", transcript="A: budget cut deep.")
    monkeypatch.setattr(ask.Config, "load", classmethod(lambda cls: _cfg()))
    monkeypatch.setattr(ask.engine, "complete_text", _echo_first_stem_engine)

    rc = ask.main(["budget", "--dir", str(root), "--index-dir", str(tmp_path / "idx"), "--json"])
    assert rc == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload["answer"]
    assert payload["citations"]


def test_answer_dataclass_json_roundtrips() -> None:
    ans = Answer(question="q", answer="a", backend="local", model="m")
    assert ans.to_json()["question"] == "q"
