"""Tests for `mp actions` cross-meeting action tracking (TECH-FEAT4)."""
from __future__ import annotations

import json
from pathlib import Path

from mp.actions import discover, filter_actions, main


def _summary(root: Path, stem: str, title: str, acts: list[dict]) -> None:
    root.mkdir(parents=True, exist_ok=True)
    (root / f"{stem}.summary.json").write_text(
        json.dumps({"title": title, "summary": ["x"], "actions": acts}), encoding="utf-8"
    )


def test_discover_collects_actions_across_meetings(tmp_path: Path) -> None:
    _summary(tmp_path, "20260101-1000", "Kickoff", [
        {"task": "Send deck", "owner": "Sam", "due": "2026-01-05", "confidence": "high"},
    ])
    _summary(tmp_path, "20260102-1000", "Sync", [
        {"task": "Book room", "owner": None, "due": None, "confidence": "low"},
        {"task": "", "confidence": "high"},  # no task -> skipped
    ])
    found = discover(tmp_path)
    assert {a.task for a in found} == {"Send deck", "Book room"}
    assert next(a for a in found if a.task == "Send deck").title == "Kickoff"


def test_skips_malformed_and_missing(tmp_path: Path) -> None:
    (tmp_path / "bad.summary.json").write_text("not json", encoding="utf-8")
    (tmp_path / "20260103-0900.meta.json").write_text("{}", encoding="utf-8")  # no summary
    assert discover(tmp_path) == []


def test_filter_by_owner_confidence_and_due(tmp_path: Path) -> None:
    _summary(tmp_path, "m1", "M1", [
        {"task": "A", "owner": "Sam", "due": "2026-02-01", "confidence": "high"},
        {"task": "B", "owner": "Lee", "due": "2026-09-01", "confidence": "low"},
        {"task": "C", "owner": "Sam", "due": None, "confidence": "medium"},
    ])
    items = discover(tmp_path)
    assert {a.task for a in filter_actions(items, owner="sam")} == {"A", "C"}
    assert {a.task for a in filter_actions(items, min_conf="medium")} == {"A", "C"}
    # due_before excludes the undated (C) and the later one (B)
    assert {a.task for a in filter_actions(items, due_before="2026-03-01")} == {"A"}


def test_main_json_sorts_dated_first(tmp_path: Path, capsys) -> None:
    _summary(tmp_path, "m1", "M1", [
        {"task": "Soon", "owner": "Sam", "due": "2026-01-01", "confidence": "high"},
        {"task": "Undated", "owner": "Lee", "due": None, "confidence": "high"},
    ])
    assert main(["--dir", str(tmp_path), "--json"]) == 0
    out = json.loads(capsys.readouterr().out)
    assert [o["task"] for o in out] == ["Soon", "Undated"]
    assert out[0]["owner"] == "Sam"


def test_main_empty_library(tmp_path: Path, capsys) -> None:
    assert main(["--dir", str(tmp_path)]) == 0
    assert "No open action items" in capsys.readouterr().out
