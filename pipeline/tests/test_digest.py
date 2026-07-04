"""Tests for `mp digest` weekly review (AI4).

CI-safe: the engine is faked (no model, no socket) and fanout is monkeypatched.
The facts (decisions + open actions) are deterministic reads off summary.json, so
those are tested against real files; only the narrative goes through the engine.
"""
from __future__ import annotations

import json
from datetime import date, timedelta
from pathlib import Path

import pytest

from mp import digest
from mp.config import Config
from mp.engine import EngineError, EngineResult


def _meeting(root: Path, stem: str, *, title: str, decisions=None, actions=None) -> None:
    root.mkdir(parents=True, exist_ok=True)
    payload = {
        "title": title,
        "summary": ["s"],
        "decisions": decisions or [],
        "actions": actions or [],
        "questions": [],
        "attendees": [],
        "detected_language": "en",
    }
    (root / f"{stem}.summary.json").write_text(json.dumps(payload), encoding="utf-8")


def _cfg() -> Config:
    return Config.model_validate({"summarization": {"backend": "local", "local_model": "fake"}})


def _stem(day: date, hhmmss: str = "120000") -> str:
    return f"{day.strftime('%Y%m%d')}-{hhmmss}"


TODAY = date(2026, 7, 4)


# ----- fact collection (deterministic) -----


def test_meeting_day_parses_and_rejects() -> None:
    assert digest._meeting_day("20260704-120000") == date(2026, 7, 4)
    assert digest._meeting_day("digest-20260704") is None  # no leading date
    assert digest._meeting_day("notadate") is None


def test_collect_open_actions_returns_open_sorted_overdue_first(tmp_path: Path) -> None:
    _meeting(tmp_path, _stem(TODAY), title="M", actions=[
        {"task": "later", "owner": "A", "due": "2026-07-20", "confidence": "high", "resolved": False},
        {"task": "overdue", "owner": "B", "due": "2026-06-01", "confidence": "high", "resolved": False},
        {"task": "done", "owner": "C", "due": "2026-06-01", "confidence": "high", "resolved": True},
        {"task": "undated", "owner": "D", "due": None, "confidence": "medium", "resolved": False},
    ])
    opens = digest.collect_open_actions(tmp_path, TODAY)
    tasks = [a.task for a in opens]
    assert "done" not in tasks                    # resolved dropped
    assert tasks[0] == "overdue"                   # earliest due first
    assert tasks[-1] == "undated"                  # undated last


def test_collect_recent_decisions_filters_window_and_orders_newest_first(tmp_path: Path) -> None:
    recent = TODAY - timedelta(days=2)
    old = TODAY - timedelta(days=30)
    _meeting(tmp_path, _stem(recent), title="Recent", decisions=["ship on Friday"])
    _meeting(tmp_path, _stem(old), title="Old", decisions=["ancient call"])
    _meeting(tmp_path, _stem(TODAY), title="Today", decisions=["approve budget"])

    got = digest.collect_recent_decisions(tmp_path, TODAY, since_days=7)
    texts = [d.text for d in got]
    assert "ancient call" not in texts             # outside the 7-day window
    assert texts[0] == "approve budget"            # newest first
    assert set(texts) == {"approve budget", "ship on Friday"}


# ----- narration -----


def _engine_ok(text: str):
    def fn(cfg, *, system_prompt, user_message, max_tokens, model=None):
        return EngineResult(text=text, backend="local", model="fake")
    return fn


def test_narrate_uses_engine_bullets(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    _meeting(tmp_path, _stem(TODAY), title="M", actions=[
        {"task": "x", "owner": "A", "due": "2026-06-01", "confidence": "high", "resolved": False},
    ])
    opens = digest.collect_open_actions(tmp_path, TODAY)
    monkeypatch.setattr(digest.engine, "complete_text", _engine_ok("- one overdue thing\n- a theme"))
    bullets, backend = digest.narrate(_cfg(), opens, [], TODAY, 7)
    assert bullets == ["one overdue thing", "a theme"]
    assert backend == "local"


def test_narrate_falls_back_when_engine_unavailable(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    _meeting(tmp_path, _stem(TODAY), title="M", actions=[
        {"task": "x", "owner": "A", "due": "2026-06-01", "confidence": "high", "resolved": False},
    ])
    opens = digest.collect_open_actions(tmp_path, TODAY)

    def _boom(cfg, **kwargs):
        raise EngineError("local model not installed")

    monkeypatch.setattr(digest.engine, "complete_text", _boom)
    bullets, backend = digest.narrate(_cfg(), opens, [], TODAY, 7)
    assert backend == "none"
    assert any("overdue" in b.lower() for b in bullets)  # deterministic summary still names it


def test_narrate_empty_library() -> None:
    bullets, backend = digest.narrate(_cfg(), [], [], TODAY, 7)
    assert backend == "none"
    assert bullets and "No open actions" in bullets[0]


# ----- assembly + generate -----


def test_build_digest_summary_grounds_facts(tmp_path: Path) -> None:
    _meeting(tmp_path, _stem(TODAY), title="Planning", decisions=["approve budget"], actions=[
        {"task": "email vendor", "owner": "Alice", "due": "2026-06-01", "confidence": "high", "resolved": False},
    ])
    opens = digest.collect_open_actions(tmp_path, TODAY)
    decisions = digest.collect_recent_decisions(tmp_path, TODAY, 7)
    summary = digest.build_digest_summary(opens, decisions, ["narrative"], today=TODAY, since_days=7)
    assert summary.title.startswith("Weekly review")
    assert summary.summary == ["narrative"]
    assert summary.actions[0].task == "email vendor"
    assert summary.actions[0].resolved is False
    assert "approve budget (Planning)" in summary.decisions  # decision keeps its source


def test_generate_end_to_end(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    _meeting(tmp_path, _stem(TODAY), title="M", decisions=["ship it"], actions=[
        {"task": "do thing", "owner": "A", "due": "2026-06-01", "confidence": "high", "resolved": False},
    ])
    monkeypatch.setattr(digest.engine, "complete_text", _engine_ok("- summary bullet"))
    summary, backend = digest.generate(_cfg(), tmp_path, since_days=7, today=TODAY)
    assert backend == "local"
    assert summary.summary == ["summary bullet"]
    assert len(summary.actions) == 1
    assert len(summary.decisions) == 1


# ----- main -----


def test_main_writes_digest_to_out_dir_not_library(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    root = tmp_path / "raw"
    out = tmp_path / "digests"
    _meeting(root, _stem(date.today()), title="M", decisions=["a call"], actions=[
        {"task": "t", "owner": "A", "due": None, "confidence": "medium", "resolved": False},
    ])
    monkeypatch.setattr(digest.Config, "load", classmethod(lambda cls: _cfg()))
    monkeypatch.setattr(digest.engine, "complete_text", _engine_ok("- bullet"))

    rc = digest.main(["--dir", str(root), "--out-dir", str(out)])
    assert rc == 0
    written = list(out.glob("digest-*.summary.json"))
    assert len(written) == 1
    # The digest must NOT be written into the scanned library (it would pollute
    # Facts / actions / ask by double-counting the rolled-up facts).
    assert not list(root.glob("digest-*.summary.json"))
    payload = json.loads(written[0].read_text(encoding="utf-8"))
    assert payload["title"].startswith("Weekly review")
    assert (out / written[0].name.replace(".json", ".md")).exists()


def test_main_publish_calls_fanout(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    root = tmp_path / "raw"
    _meeting(root, _stem(date.today()), title="M", decisions=["d"], actions=[])
    monkeypatch.setattr(digest.Config, "load", classmethod(lambda cls: _cfg()))
    monkeypatch.setattr(digest.engine, "complete_text", _engine_ok("- b"))

    calls: list[Path] = []
    from mp import publish_router
    monkeypatch.setattr(publish_router, "fanout",
                        lambda *, summary_json, cfg, transcript_md: calls.append(summary_json) or {"sinks": {}})

    rc = digest.main(["--dir", str(root), "--out-dir", str(tmp_path / "digests"), "--publish", "--json"])
    assert rc == 0
    assert len(calls) == 1
    assert calls[0].name.endswith(".summary.json")


def test_main_without_publish_does_not_fanout(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    root = tmp_path / "raw"
    _meeting(root, _stem(date.today()), title="M", decisions=["d"], actions=[])
    monkeypatch.setattr(digest.Config, "load", classmethod(lambda cls: _cfg()))
    monkeypatch.setattr(digest.engine, "complete_text", _engine_ok("- b"))

    from mp import publish_router

    def _fail(**kwargs):
        raise AssertionError("fanout must not run without --publish")

    monkeypatch.setattr(publish_router, "fanout", _fail)
    assert digest.main(["--dir", str(root), "--out-dir", str(tmp_path / "digests")]) == 0
