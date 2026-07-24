"""Tests for `mp prep <workflow>`, the pre-meeting prep card (CAL2)."""
from __future__ import annotations

import json
from datetime import date, datetime
from pathlib import Path

from mp.prep import (
    build_card,
    candidates,
    main,
    parse_stem,
    prep,
    relative_day,
    render,
    resolve_workflow,
    workflow_names,
)


def _meeting(root: Path, stem: str, workflow: str | None, summary: dict | None) -> None:
    root.mkdir(parents=True, exist_ok=True)
    meta: dict = {"source_bundle_id": "com.microsoft.teams2"}
    if workflow is not None:
        meta["workflow_name"] = workflow
    (root / f"{stem}.meta.json").write_text(json.dumps(meta), encoding="utf-8")
    if summary is not None:
        (root / f"{stem}.summary.json").write_text(json.dumps(summary), encoding="utf-8")


def _summary(title: str, points: list[str], actions: list[dict] | None = None) -> dict:
    return {"title": title, "summary": points, "decisions": [], "actions": actions or []}


# --- stem parsing ------------------------------------------------------------


def test_parse_stem_round_trips_and_rejects_short_input() -> None:
    assert parse_stem("20260720-143000") == datetime(2026, 7, 20, 14, 30, 0)
    # The length guard is the point: a short string must not parse into an
    # epoch-anchored date (the trap Swift's parseStem documents).
    assert parse_stem("20260720") is None
    assert parse_stem("not-a-stem-1234") is None


# --- candidate discovery -----------------------------------------------------


def test_candidates_are_newest_first_and_need_both_sidecars(tmp_path: Path) -> None:
    _meeting(tmp_path, "20260701-090000", "Client work", _summary("Kickoff", ["a"]))
    _meeting(tmp_path, "20260715-090000", "Client work", _summary("Review", ["b"]))
    _meeting(tmp_path, "20260716-090000", "Client work", None)      # no summary yet
    _meeting(tmp_path, "20260717-090000", None, _summary("Manual", ["c"]))  # no workflow
    (tmp_path / "20260718-090000.meta.json").write_text("nope", encoding="utf-8")

    found = candidates(tmp_path)
    assert [c.stem for c in found] == ["20260715-090000", "20260701-090000"]
    assert workflow_names(found) == ["Client work"]


def test_candidates_on_a_missing_directory(tmp_path: Path) -> None:
    assert candidates(tmp_path / "nope") == []


# --- workflow resolution -----------------------------------------------------


def test_resolve_prefers_exact_then_unique_substring() -> None:
    names = ["Client work", "Client work (legacy)", "Personal"]
    assert resolve_workflow(names, "client work") == "Client work"
    assert resolve_workflow(names, "person") == "Personal"
    # Ambiguous substring refuses rather than picking one (the WF9 duplicate case).
    assert resolve_workflow(names, "client") is None
    assert resolve_workflow(names, "nothing") is None
    assert resolve_workflow(names, "  ") is None


# --- card projection ---------------------------------------------------------


def test_build_card_caps_points_and_actions_and_counts_the_rest() -> None:
    summary = _summary(
        "Weekly sync",
        ["one", "two", "three", "four"],
        [
            {"task": "Send SOW", "owner": "Georgy", "due": "2026-07-25"},
            {"task": "Book room"},
            {"task": "Draft plan"},
            {"task": "Chase invoice"},
            {"task": "Already done", "resolved": True},
            {"task": "Legacy done", "done": True},
            {"task": "   "},
        ],
    )
    card = build_card("Client work", "20260720-143000", datetime(2026, 7, 20, 14, 30), summary)
    assert card is not None
    assert card.title == "Weekly sync"
    assert card.points == ["one", "two", "three"]
    assert [a.task for a in card.actions] == ["Send SOW", "Book room", "Draft plan"]
    assert card.actions[0].owner == "Georgy"
    assert card.actions[0].due == "2026-07-25"
    assert card.actions[1].owner is None
    # Resolved, legacy-done and blank rows are not open actions, so "more" is 1.
    assert card.more_actions == 1


def test_build_card_falls_back_to_decisions_when_the_recap_is_empty() -> None:
    summary = {"title": "Design call", "summary": [], "decisions": ["Ship on Friday"],
               "actions": []}
    card = build_card("Client work", "20260720-143000", datetime(2026, 7, 20, 14, 30), summary)
    assert card is not None
    assert card.points == ["Ship on Friday"]


def test_build_card_is_none_when_there_is_nothing_to_say() -> None:
    empty = {"title": "Standup", "summary": [], "decisions": [],
             "actions": [{"task": "Done thing", "resolved": True}]}
    assert build_card("W", "20260720-143000", datetime(2026, 7, 20, 14, 30), empty) is None


def test_build_card_tolerates_a_partial_summary() -> None:
    card = build_card("W", "20260720-143000", datetime(2026, 7, 20, 14, 30),
                      {"summary": ["only this"]})
    assert card is not None
    # No title on disk -> the stem, never an empty heading.
    assert card.title == "20260720-143000"
    assert card.actions == []


# --- selection ---------------------------------------------------------------


def test_prep_picks_the_newest_meeting_of_that_workflow(tmp_path: Path) -> None:
    _meeting(tmp_path, "20260701-090000", "Client work", _summary("Kickoff", ["old"]))
    _meeting(tmp_path, "20260715-090000", "Client work", _summary("Review", ["new"]))
    _meeting(tmp_path, "20260716-090000", "Personal", _summary("Dentist", ["other"]))

    card = prep(tmp_path, "Client work")
    assert card is not None
    assert card.stem == "20260715-090000"
    assert card.points == ["new"]


def test_prep_falls_through_an_empty_last_meeting(tmp_path: Path) -> None:
    _meeting(tmp_path, "20260701-090000", "Client work", _summary("Kickoff", ["real content"]))
    _meeting(tmp_path, "20260715-090000", "Client work",
             {"title": "No speech", "summary": [], "decisions": [], "actions": []})
    card = prep(tmp_path, "Client work")
    assert card is not None
    assert card.stem == "20260701-090000"


def test_prep_is_none_for_a_workflow_with_no_meetings(tmp_path: Path) -> None:
    _meeting(tmp_path, "20260701-090000", "Client work", _summary("Kickoff", ["a"]))
    assert prep(tmp_path, "Personal") is None


# --- rendering ---------------------------------------------------------------


def test_relative_day_phrases() -> None:
    d = datetime(2026, 7, 20, 9, 0)
    assert relative_day(d, date(2026, 7, 20)) == "today"
    assert relative_day(d, date(2026, 7, 21)) == "yesterday"
    assert relative_day(d, date(2026, 7, 23)) == "3 days ago"
    assert relative_day(d, date(2026, 8, 10)) == "3 weeks ago"
    assert relative_day(d, date(2026, 11, 20)) == "4 months ago"
    # A clock skew (stem in the future) reads as today, never "-1 days ago".
    assert relative_day(d, date(2026, 7, 19)) == "today"


def test_render_shows_the_recap_the_actions_and_the_truncation(tmp_path: Path) -> None:
    _meeting(tmp_path, "20260720-143000", "Client work", _summary(
        "Weekly sync", ["Scoped the pilot", "Agreed on timing"],
        [{"task": "Send SOW", "owner": "Georgy", "due": "2026-07-25"},
         {"task": "Book room"}, {"task": "Draft plan"}, {"task": "Chase invoice"}],
    ))
    card = prep(tmp_path, "Client work")
    assert card is not None
    text = render(card, date(2026, 7, 23))
    assert "Last time in Client work" in text
    assert "Weekly sync  ·  3 days ago (2026-07-20)" in text
    assert "- Scoped the pilot" in text
    assert "Open actions (4):" in text
    assert "- [ ] Send SOW  (Georgy, due 2026-07-25)" in text
    assert "1 more in the Library" in text
    assert "[20260720-143000]" in text


# --- CLI ---------------------------------------------------------------------


def test_main_text_output(tmp_path: Path, capsys) -> None:
    _meeting(tmp_path, "20260720-143000", "Client work", _summary("Weekly sync", ["Scoped it"]))
    assert main(["client", "--dir", str(tmp_path)]) == 0
    out = capsys.readouterr().out
    assert "Last time in Client work" in out
    assert "Scoped it" in out


def test_main_json_output(tmp_path: Path, capsys) -> None:
    _meeting(tmp_path, "20260720-143000", "Client work", _summary(
        "Weekly sync", ["Scoped it"], [{"task": "Send SOW", "owner": "Georgy"}]))
    assert main(["Client work", "--dir", str(tmp_path), "--json"]) == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload["workflow"] == "Client work"
    assert payload["card"]["stem"] == "20260720-143000"
    assert payload["card"]["actions"] == [
        {"task": "Send SOW", "owner": "Georgy", "due": None}
    ]


def test_main_unknown_workflow_names_the_alternatives(tmp_path: Path, capsys) -> None:
    _meeting(tmp_path, "20260720-143000", "Client work", _summary("Weekly sync", ["a"]))
    assert main(["Nope", "--dir", str(tmp_path)]) == 2
    err = capsys.readouterr().err
    assert "No workflow matches 'Nope'" in err
    assert "Client work" in err


def test_main_workflow_with_no_summarized_meeting(tmp_path: Path, capsys) -> None:
    # Present in the library (so it resolves), but its only meeting is empty.
    _meeting(tmp_path, "20260720-143000", "Client work",
             {"title": "No speech", "summary": [], "decisions": [], "actions": []})
    assert main(["Client work", "--dir", str(tmp_path)]) == 0
    assert "No summarized meeting yet in Client work." in capsys.readouterr().out
    assert main(["Client work", "--dir", str(tmp_path), "--json"]) == 0
    assert json.loads(capsys.readouterr().out)["card"] is None
