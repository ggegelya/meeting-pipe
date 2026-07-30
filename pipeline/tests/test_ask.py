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

from mp import ask, events
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


# ----- AI11: an honest, clamped context budget -----


def _local_cfg(backend: str = "local") -> Config:
    return Config.model_validate({"summarization": {"backend": backend, "local_model": "fake"}})


def test_chars_per_token_tracks_the_script_mix() -> None:
    # LOCAL13 measured EN at ~0.25 tok/char and UK at ~0.49, i.e. 4 and 2 chars
    # per token. A pure-Latin text keeps exactly the old constant.
    assert ask.chars_per_token("the budget was cut in Q3") == pytest.approx(ask.LATIN_CHARS_PER_TOKEN)
    assert ask.chars_per_token("бюджет скоротили у кварталі") == pytest.approx(ask.CYRILLIC_CHARS_PER_TOKEN)
    mixed = ask.chars_per_token("budget бюджет")
    assert ask.CYRILLIC_CHARS_PER_TOKEN < mixed < ask.LATIN_CHARS_PER_TOKEN
    # Digits and punctuation cost the same either way, so they must not dilute
    # a genuinely Cyrillic pack back toward the Latin rate.
    assert ask.chars_per_token("1234!!! ...") == pytest.approx(ask.LATIN_CHARS_PER_TOKEN)


def test_context_tokens_clamp_to_this_machines_ceiling(monkeypatch, caplog) -> None:
    monkeypatch.setattr(ask.resource_guard, "physical_ram_gb", lambda: 16.0)
    cfg = _local_cfg()
    with caplog.at_level("WARNING"):
        assert ask.clamp_context_tokens(cfg, 100_000) == 4000
    # ... and says so, rather than silently answering a different question.
    assert "100000" in caplog.text and "4000" in caplog.text
    assert ask.clamp_context_tokens(cfg, 2000) == 2000  # under the ceiling, untouched


def test_the_clamp_follows_the_ram_tier(monkeypatch) -> None:
    cfg = _local_cfg()
    monkeypatch.setattr(ask.resource_guard, "physical_ram_gb", lambda: 32.0)
    assert ask.clamp_context_tokens(cfg, 100_000) == 8000
    monkeypatch.setattr(ask.resource_guard, "physical_ram_gb", lambda: 8.0)
    assert ask.clamp_context_tokens(cfg, 100_000) == 2000


def test_a_cloud_answer_is_not_clamped_by_this_macs_ram(monkeypatch) -> None:
    monkeypatch.setattr(ask.resource_guard, "physical_ram_gb", lambda: 16.0)
    cfg = Config.model_validate({"summarization": {"backend": "anthropic"}})
    assert ask.clamp_context_tokens(cfg, 100_000) == 100_000


def test_auto_is_clamped_because_its_fallback_leg_is_local(monkeypatch) -> None:
    monkeypatch.setattr(ask.resource_guard, "physical_ram_gb", lambda: 16.0)
    assert ask.clamp_context_tokens(_local_cfg("auto"), 100_000) == 4000


def test_unreadable_ram_does_not_clamp(monkeypatch) -> None:
    # A guard that cannot measure must not invent a limit (the LOCAL16 rule).
    monkeypatch.setattr(ask.resource_guard, "physical_ram_gb", lambda: None)
    assert ask.clamp_context_tokens(_local_cfg(), 100_000) == 100_000


def _packed_context_len(monkeypatch: pytest.MonkeyPatch, root: Path, tokens: int) -> int:
    captured: list[str] = []

    def _capture(cfg, *, system_prompt, user_message, max_tokens, model=None):
        captured.append(user_message)
        return EngineResult(text="ok", backend="local", model="fake")

    monkeypatch.setattr(ask.engine, "complete_text", _capture)
    monkeypatch.setattr(ask.resource_guard, "physical_ram_gb", lambda: 32.0)
    answer_question(_local_cfg(), _index(root), "питання budget question", context_tokens=tokens)
    return len(captured[0])


def test_a_cyrillic_pack_is_sized_to_its_measured_budget(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """The same token budget has to buy about half as many characters in
    Ukrainian. Sizing both at 4 chars/token is what put a nominal 4K pack at
    ~7.8K real tokens, past where AI2 measured the 14B OOM-crashing."""
    en, uk = tmp_path / "en", tmp_path / "uk"
    # Long enough that the budget actually binds, so the comparison is about the
    # rate rather than about how much text happened to exist.
    _meeting(en, "20260101-0900", title="Budget", transcript="the budget was cut again " * 1200)
    _meeting(uk, "20260101-0900", title="Бюджет", transcript="бюджет знову скоротили тут " * 1100)

    en_chars = _packed_context_len(monkeypatch, en, 4000)
    uk_chars = _packed_context_len(monkeypatch, uk, 4000)
    assert uk_chars < en_chars
    # Roughly the measured 2x, not an arbitrary shrink. The bounds are loose
    # because packing is block-granular: a pack lands just under its budget.
    assert 1.7 < en_chars / uk_chars < 2.4


# ----- AI11: memory bounds on the ask path -----


def test_the_embedder_is_released_before_the_answer_model_spawns(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    _meeting(tmp_path, "20260101-0900", title="Budget", transcript="A: we cut the budget.")
    released: list[int] = []

    class _Watched(HashingEmbedder):
        def release(self) -> None:
            released.append(1)

    index = EmbeddingIndex.build(tmp_path, _Watched(dim=256))

    def _engine(cfg, *, system_prompt, user_message, max_tokens, model=None):
        assert released, "the retrieval model must be gone before a second model loads"
        return EngineResult(text="answer [20260101-0900]", backend="local", model="fake")

    monkeypatch.setattr(ask.engine, "complete_text", _engine)
    ans = answer_question(_cfg(), index, "budget?")
    assert ans.verified


def test_main_surfaces_a_memory_abort_as_the_answers_error(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    from mp.resource_guard import LOW_MEMORY_MARKER, LowMemoryError

    root = tmp_path / "raw"
    _meeting(root, "20260101-0900", title="Budget", transcript="A: budget cut.")
    monkeypatch.setattr(ask.Config, "load", classmethod(lambda cls: _cfg()))

    def _boom(*a, **k):
        raise LowMemoryError(f"{LOW_MEMORY_MARKER}: free RAM fell to 4% during ask index embed")

    monkeypatch.setattr(ask.embed_index, "load_or_build", _boom)
    out = tmp_path / "answer.json"
    rc = ask.main(["budget", "--dir", str(root), "--index-dir", str(tmp_path / "idx"), "--out", str(out)])
    assert rc == 1
    payload = json.loads(out.read_text(encoding="utf-8"))
    # The marker Swift matches to stamp the failure stage as `memory` survives verbatim.
    assert LOW_MEMORY_MARKER in payload["error"]


def test_main_surfaces_an_uncached_embedder_as_an_actionable_message(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    root = tmp_path / "raw"
    _meeting(root, "20260101-0900", title="Budget", transcript="A: budget cut.")
    monkeypatch.setattr(ask.Config, "load", classmethod(lambda cls: _cfg()))

    def _boom(*a, **k):
        raise ask.embed_index.EmbedderUnavailableError(
            "Embedding model 'e5' is not in the local HuggingFace cache ... mp prefetch-model e5"
        )

    monkeypatch.setattr(ask.embed_index, "load_or_build", _boom)
    out = tmp_path / "answer.json"
    rc = ask.main(["budget", "--dir", str(root), "--index-dir", str(tmp_path / "idx"), "--out", str(out)])
    assert rc == 1
    assert "mp prefetch-model" in json.loads(out.read_text(encoding="utf-8"))["error"]


# ----- AI11: observability -----


def test_main_prints_a_progress_heartbeat_the_daemon_can_parse(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path, capsys
) -> None:
    root = tmp_path / "raw"
    _meeting(root, "20260101-0900", title="Budget", transcript="A: we cut the budget.")
    monkeypatch.setattr(ask.Config, "load", classmethod(lambda cls: _cfg()))
    monkeypatch.setattr(ask.engine, "complete_text", _echo_first_stem_engine)

    rc = ask.main(["budget", "--dir", str(root), "--index-dir", str(tmp_path / "idx"),
                   "--out", str(tmp_path / "a.json")])
    assert rc == 0
    beats = [
        json.loads(line[len(events.PROGRESS_SENTINEL):])
        for line in capsys.readouterr().out.splitlines()
        if line.startswith(events.PROGRESS_SENTINEL)
    ]
    assert beats, "UX38 renders this; an ask with no heartbeat shows a bare spinner"
    # `PipelineLauncher.parseProgress` needs exactly these two and ignores the rest.
    assert all("stage" in b and isinstance(b["elapsed_s"], int) for b in beats)
    indexing = [b for b in beats if b["stage"] == "indexing"]
    assert indexing and indexing[-1]["stems_done"] == indexing[-1]["stems_total"] == 1
    assert any(b["stage"] == "answering" for b in beats)


def test_ask_emits_its_index_and_answer_events(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setenv("MEETINGPIPE_LOGS_DIR", str(tmp_path / "logs"))
    root = tmp_path / "raw"
    _meeting(root, "20260101-0900", title="Budget", transcript="A: we cut the budget.")
    monkeypatch.setattr(ask.Config, "load", classmethod(lambda cls: _cfg()))
    monkeypatch.setattr(ask.engine, "complete_text", _echo_first_stem_engine)

    ask.main(["budget", "--dir", str(root), "--index-dir", str(tmp_path / "idx"),
              "--out", str(tmp_path / "a.json")])
    rows = [
        json.loads(line)
        for line in (tmp_path / "logs" / "pipeline_events.jsonl").read_text(encoding="utf-8").splitlines()
    ]
    by_action = {r["action"]: r for r in rows}
    assert by_action["ask_index_refresh_started"]["stems_stale"] == 1
    assert by_action["ask_index_refresh_done"]["stems_embedded"] == 1
    assert by_action["ask_index_refresh_done"]["chunks_total"] >= 1
    answered = by_action["ask_answered"]
    assert answered["backend"] == "local"
    assert answered["retrieved_stems"] == 1
    assert answered["packed_tokens"] > 0
    assert all(r["category"] == "pipeline" for r in rows)


def test_a_second_ask_reuses_the_index_and_says_nothing_new(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setenv("MEETINGPIPE_LOGS_DIR", str(tmp_path / "logs"))
    root, idx = tmp_path / "raw", tmp_path / "idx"
    _meeting(root, "20260101-0900", title="Budget", transcript="A: we cut the budget.")
    monkeypatch.setattr(ask.Config, "load", classmethod(lambda cls: _cfg()))
    monkeypatch.setattr(ask.engine, "complete_text", _echo_first_stem_engine)

    args = ["budget", "--dir", str(root), "--index-dir", str(idx), "--out", str(tmp_path / "a.json")]
    ask.main(args)
    ask.main(args)
    rows = [
        json.loads(line)
        for line in (tmp_path / "logs" / "pipeline_events.jsonl").read_text(encoding="utf-8").splitlines()
    ]
    refreshes = [r for r in rows if r["action"] == "ask_index_refresh_started"]
    assert len(refreshes) == 1, "an unchanged library must not re-enter the embed path"
