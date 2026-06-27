"""Tests for `mp actions` cross-meeting action tracking (TECH-FEAT4 + AI1)."""
from __future__ import annotations

import json
from datetime import date
from pathlib import Path

from mp.actions import OpenAction, discover, filter_actions, main


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
    assert "No action items" in capsys.readouterr().out


# --- AI1: resolved lifecycle + aging --------------------------------------


def test_discover_reads_resolved_flag(tmp_path: Path) -> None:
    _summary(tmp_path, "m1", "M1", [
        {"task": "Open one", "confidence": "high"},  # no field -> open
        {"task": "Done one", "confidence": "high", "resolved": True},
        {"task": "Legacy done", "confidence": "high", "done": True},  # legacy spelling
    ])
    by_task = {a.task: a for a in discover(tmp_path)}
    assert by_task["Open one"].resolved is False
    assert by_task["Done one"].resolved is True
    assert by_task["Legacy done"].resolved is True


def test_open_closed_overdue_filters() -> None:
    today = date(2026, 6, 27)
    items = [
        OpenAction("m1", "M1", "Open dated past", None, "2026-06-01", "high", resolved=False),
        OpenAction("m1", "M1", "Open dated future", None, "2026-07-10", "high", resolved=False),
        OpenAction("m1", "M1", "Open undated", None, None, "high", resolved=False),
        OpenAction("m1", "M1", "Closed past", None, "2026-05-01", "high", resolved=True),
    ]
    openn = {a.task for a in filter_actions(items, lifecycle="open", today=today)}
    assert openn == {"Open dated past", "Open dated future", "Open undated"}
    closed = {a.task for a in filter_actions(items, lifecycle="closed", today=today)}
    assert closed == {"Closed past"}
    # Overdue = open AND dated in the past. A past-due CLOSED item is not overdue.
    overdue = {a.task for a in filter_actions(items, lifecycle="overdue", today=today)}
    assert overdue == {"Open dated past"}


def test_age_days_and_overdue_off_due_date() -> None:
    today = date(2026, 6, 27)
    past = OpenAction("m", "M", "t", None, "2026-06-20", "high")
    future = OpenAction("m", "M", "t", None, "2026-06-30", "high")
    undated = OpenAction("m", "M", "t", None, None, "high")
    assert past.age_days(today) == 7  # 7 days overdue
    assert past.is_overdue(today) is True
    assert future.age_days(today) == -3  # due in 3 days
    assert future.is_overdue(today) is False
    assert undated.age_days(today) is None
    assert undated.is_overdue(today) is False


def test_main_open_closed_json(tmp_path: Path, capsys) -> None:
    _summary(tmp_path, "m1", "M1", [
        {"task": "Still open", "due": "2026-01-01", "confidence": "high"},
        {"task": "Wrapped", "confidence": "high", "resolved": True},
    ])
    assert main(["--dir", str(tmp_path), "--open", "--json"]) == 0
    out = json.loads(capsys.readouterr().out)
    assert [o["task"] for o in out] == ["Still open"]
    assert out[0]["resolved"] is False
    assert out[0]["age_days"] is not None  # dated open action carries an age

    assert main(["--dir", str(tmp_path), "--closed", "--json"]) == 0
    out = json.loads(capsys.readouterr().out)
    assert [o["task"] for o in out] == ["Wrapped"]
    assert out[0]["resolved"] is True


def test_main_overdue_text_shows_age(tmp_path: Path, capsys) -> None:
    # A long-past due date guarantees the overdue branch fires regardless of run date.
    _summary(tmp_path, "m1", "M1", [
        {"task": "Way overdue", "due": "2000-01-01", "confidence": "high"},
        {"task": "No deadline", "confidence": "high"},
    ])
    assert main(["--dir", str(tmp_path), "--overdue"]) == 0
    out = capsys.readouterr().out
    assert "Way overdue" in out
    assert "No deadline" not in out  # undated is never overdue
    assert "overdue)" in out  # the age phrase is rendered
