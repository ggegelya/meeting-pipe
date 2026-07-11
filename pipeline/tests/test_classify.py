"""AI5 spike: meeting-type classification. Pins the pure heuristic and the
library discovery; the LLM path is exercised with a fake engine (no live model)."""
from __future__ import annotations

import json
import types

from mp import classify


def test_heuristic_keyword_matches():
    assert classify.classify_heuristic("Sprint planning", "", 5)[0] == "planning"
    assert classify.classify_heuristic("Daily standup", "", 5)[0] == "standup"
    assert classify.classify_heuristic("Q3 retro", "", 6)[0] == "retro"
    assert classify.classify_heuristic("Candidate interview", "", 3)[0] == "interview"
    assert classify.classify_heuristic("Design review", "", 4)[0] == "review"
    # workflow name also feeds the haystack
    assert classify.classify_heuristic("Weekly", "Client account", 4)[0] == "client"


def test_heuristic_attendee_fallbacks():
    assert classify.classify_heuristic("Weekly chat", "", 2) == ("one_on_one", "attendees=2")
    assert classify.classify_heuristic("Company update", "", 12)[0] == "all_hands"
    assert classify.classify_heuristic("Some meeting", "", 4) == ("other", "no match")


def test_meeting_day_parses_stem():
    assert classify.meeting_day("20260711-150057") == "2026-07-11"
    assert classify.meeting_day("no-date-here") == ""


def test_discover_reads_summary_and_meta(tmp_path):
    (tmp_path / "20260711-100000.summary.json").write_text(
        json.dumps({"title": "Sprint planning", "attendees": ["a", "b", "c"]}), encoding="utf-8"
    )
    (tmp_path / "20260711-100000.meta.json").write_text(
        json.dumps({"workflow_name": "Eng"}), encoding="utf-8"
    )
    meetings = classify.discover(tmp_path)
    assert len(meetings) == 1
    m = meetings[0]
    assert m.title == "Sprint planning"
    assert m.date == "2026-07-11"
    assert m.attendees == 3
    assert m.heuristic_type == "planning"


def test_discover_tolerates_missing_meta_and_bad_json(tmp_path):
    (tmp_path / "20260101-090000.summary.json").write_text(
        json.dumps({"title": "One on one", "attendees": ["x", "y"]}), encoding="utf-8"
    )
    (tmp_path / "20260102-090000.summary.json").write_text("{bad json", encoding="utf-8")
    meetings = classify.discover(tmp_path)
    assert [m.stem for m in meetings] == ["20260101-090000"]
    assert meetings[0].heuristic_type == "one_on_one"  # attendees=2, no keyword


def test_classify_llm_snaps_to_taxonomy(monkeypatch):
    monkeypatch.setattr(
        classify.engine, "complete_text",
        lambda *a, **k: types.SimpleNamespace(text="I think this is a standup meeting."),
    )
    m = classify.Meeting("s", "t", "d", 5, "w", "other", "no match")
    assert classify.classify_llm(object(), m) == "standup"


def test_classify_llm_error_is_soft(monkeypatch):
    def boom(*a, **k):
        raise classify.engine.EngineError("no model")
    monkeypatch.setattr(classify.engine, "complete_text", boom)
    m = classify.Meeting("s", "t", "d", 5, "w", "other", "no match")
    assert classify.classify_llm(object(), m) == "error"


def test_render_report_empty_and_populated():
    assert "No meetings found" in classify.render_report([], use_llm=False)
    m = classify.Meeting("20260711-100000", "Sprint planning", "2026-07-11", 3, "Eng", "planning", "keyword:planning")
    report = classify.render_report([m], use_llm=False)
    assert "planning: 1" in report
    assert "Sprint planning" in report
