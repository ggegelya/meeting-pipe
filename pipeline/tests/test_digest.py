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


def _meeting(root: Path, stem: str, *, title: str, decisions=None, actions=None,
             workflow: str | None = None) -> None:
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
    if workflow is not None:
        # AI7 reads the series key off the meeting's sidecar; AI10 groups on it.
        (root / f"{stem}.meta.json").write_text(
            json.dumps({"schema_version": 1, "workflow_name": workflow}), encoding="utf-8")


def _action(task: str, *, owner: str = "A", due: str | None = None,
            confidence: str = "medium", resolved: bool = False) -> dict:
    return {"task": task, "owner": owner, "due": due,
            "confidence": confidence, "resolved": resolved}


def _scope(root: Path, today: date | None = None, since_days: int = 7) -> digest.ActionScope:
    today = today or TODAY
    return digest.scope_actions(digest.collect_open_actions(root, today), today, since_days)


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
    _meeting(tmp_path, _stem(TODAY), title="M", actions=[_action("x", due="2026-06-01")])
    monkeypatch.setattr(digest.engine, "complete_text", _engine_ok("- one overdue thing\n- a theme"))
    bullets, backend = digest.narrate(_cfg(), _scope(tmp_path), [], TODAY, 7)
    assert bullets == ["one overdue thing", "a theme"]
    assert backend == "local"


def test_narrate_falls_back_when_engine_unavailable(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    _meeting(tmp_path, _stem(TODAY), title="M", actions=[_action("x", due="2026-06-01")])

    def _boom(cfg, **kwargs):
        raise EngineError("local model not installed")

    monkeypatch.setattr(digest.engine, "complete_text", _boom)
    bullets, backend = digest.narrate(_cfg(), _scope(tmp_path), [], TODAY, 7)
    assert backend == "none"
    assert any("overdue" in b.lower() for b in bullets)  # deterministic summary still names it


def test_narrate_empty_library() -> None:
    empty = digest.ActionScope(groups=[], window_total=0, library_total=0, group_total=0)
    bullets, backend = digest.narrate(_cfg(), empty, [], TODAY, 7)
    assert backend == "none"
    assert bullets and "No open actions" in bullets[0]


def test_narrate_facts_tell_the_model_the_list_is_capped(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """AI10: a narrative written from a capped list must not assert the cap as the
    total, so the facts header carries the window's real counts."""
    _meeting(tmp_path, _stem(TODAY), title="M", workflow="Standup", actions=[
        _action(f"t{i}", due="2026-06-01") for i in range(9)
    ])
    seen: list[str] = []

    def _capture(cfg, *, system_prompt, user_message, max_tokens, model=None):
        seen.append(user_message)
        return EngineResult(text="- b", backend="local", model="fake")

    monkeypatch.setattr(digest.engine, "complete_text", _capture)
    scope = digest.scope_actions(digest.collect_open_actions(tmp_path, TODAY), TODAY, 7,
                                 max_total=3, max_per_group=3)
    digest.narrate(_cfg(), scope, [], TODAY, 7)
    assert "3 most pressing of 9" in seen[0]
    assert "9 of them overdue" in seen[0]


def test_fallback_bullets_count_the_window_not_the_shown_slice(tmp_path: Path) -> None:
    _meeting(tmp_path, _stem(TODAY), title="M", workflow="Standup", actions=[
        _action(f"t{i}", due="2026-06-01") for i in range(9)
    ])
    scope = digest.scope_actions(digest.collect_open_actions(tmp_path, TODAY), TODAY, 7,
                                 max_total=2, max_per_group=2)
    bullets = digest._fallback_bullets(scope, [], TODAY, 7)
    assert bullets[0].startswith("9 open action item(s)")  # not "2"
    assert "9 overdue" in bullets[0]


# ----- AI10: bounding the action list -----


def test_in_review_window_keeps_this_period_and_overdue_drops_dormant(tmp_path: Path) -> None:
    old = TODAY - timedelta(days=90)
    _meeting(tmp_path, _stem(TODAY - timedelta(days=2)), title="This week", actions=[
        _action("raised this week"),                      # undated but recent: in
    ])
    _meeting(tmp_path, _stem(old), title="Ancient", actions=[
        _action("still overdue", due="2026-05-01"),       # dated, past due: in
        _action("due next week", due=(TODAY + timedelta(days=3)).isoformat()),  # in
        _action("dormant", due=None),                     # old + undated: out
        _action("far future", due="2027-01-01"),          # beyond the window ahead: out
    ])
    scope = _scope(tmp_path)
    tasks = [a.task for a in scope.actions]
    assert "dormant" not in tasks
    assert "far future" not in tasks
    assert set(tasks) == {"raised this week", "still overdue", "due next week"}
    assert scope.window_total == 3
    assert scope.library_total == 5   # the dormant pair is counted, not carried
    assert scope.overdue_total == 1


def test_scope_ranks_overdue_first_then_soonest_then_confidence(tmp_path: Path) -> None:
    _meeting(tmp_path, _stem(TODAY), title="M", workflow="One", actions=[
        _action("undated"),
        _action("due in three days", due=(TODAY + timedelta(days=3)).isoformat()),
        _action("mildly overdue", due=(TODAY - timedelta(days=2)).isoformat()),
        _action("very overdue", due=(TODAY - timedelta(days=40)).isoformat()),
        _action("due today low", due=TODAY.isoformat(), confidence="low"),
        _action("due today high", due=TODAY.isoformat(), confidence="high"),
    ])
    scope = digest.scope_actions(digest.collect_open_actions(tmp_path, TODAY), TODAY, 7,
                                 max_per_group=10)
    assert [a.task for a in scope.actions] == [
        "very overdue", "mildly overdue", "due today high", "due today low",
        "due in three days", "undated",
    ]


def test_scope_groups_by_workflow_and_falls_back_to_the_meeting_title(tmp_path: Path) -> None:
    _meeting(tmp_path, _stem(TODAY, "090000"), title="Standup 12", workflow="Standup",
             actions=[_action("standup thing")])
    _meeting(tmp_path, _stem(TODAY, "100000"), title="Untagged chat",
             actions=[_action("untagged thing")])
    names = {g.name for g in _scope(tmp_path).groups}
    assert names == {"Standup", "Untagged chat"}


def test_scope_caps_per_group_and_in_total_and_counts_what_it_hid(tmp_path: Path) -> None:
    for i in range(4):
        _meeting(tmp_path, _stem(TODAY, f"1{i}0000"), title=f"M{i}", workflow=f"W{i}",
                 actions=[_action(f"w{i}-t{j}", due="2026-06-01") for j in range(6)])
    scope = digest.scope_actions(digest.collect_open_actions(tmp_path, TODAY), TODAY, 7,
                                 max_total=7, max_per_group=3)
    assert scope.shown == 7                       # 3 + 3 + 1, then the budget runs out
    assert [len(g.shown) for g in scope.groups] == [3, 3, 1]
    assert scope.group_total == 4                 # the fourth workflow never renders
    assert len(scope.groups) == 3
    assert all(g.total == 6 for g in scope.groups)
    assert [g.hidden for g in scope.groups] == [3, 3, 5]


def test_scope_section_names_the_residue_and_the_library_tail(tmp_path: Path) -> None:
    old = TODAY - timedelta(days=90)
    _meeting(tmp_path, _stem(old), title="Ancient", actions=[_action("dormant")])
    _meeting(tmp_path, _stem(TODAY), title="M", workflow="Standup",
             actions=[_action(f"t{i}", due="2026-06-01") for i in range(5)])
    scope = digest.scope_actions(digest.collect_open_actions(tmp_path, TODAY), TODAY, 7,
                                 max_total=2, max_per_group=2)
    note = digest.scope_section(scope, 7)
    assert note is not None and note.name == digest.SCOPE_SECTION
    assert note.content[0] == (
        "Showing 2 of 5 open action(s) from the last 7 day(s), across 1 of 1 group(s)."
    )
    assert "Standup: 2 of 5 shown" in note.content
    assert any("6 open action(s) library-wide" in line for line in note.content)


def test_scope_section_is_absent_when_nothing_was_hidden(tmp_path: Path) -> None:
    _meeting(tmp_path, _stem(TODAY), title="M", actions=[_action("only one")])
    assert digest.scope_section(_scope(tmp_path), 7) is None


# ----- assembly + generate -----


def test_build_digest_summary_grounds_facts(tmp_path: Path) -> None:
    _meeting(tmp_path, _stem(TODAY), title="Planning", workflow="Planning call",
             decisions=["approve budget"], actions=[
                 _action("email vendor", owner="Alice", due="2026-06-01", confidence="high"),
             ])
    decisions = digest.collect_recent_decisions(tmp_path, TODAY, 7)
    summary = digest.build_digest_summary(_scope(tmp_path), decisions, ["narrative"],
                                          today=TODAY, since_days=7)
    assert summary.title.startswith("Weekly review")
    assert summary.summary == ["narrative"]
    assert summary.actions[0].task == "email vendor"
    assert summary.actions[0].resolved is False
    assert summary.actions[0].group == "Planning call"  # AI10: carries its group
    assert "approve budget (Planning)" in summary.decisions  # decision keeps its source


def test_generate_end_to_end(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    _meeting(tmp_path, _stem(TODAY), title="M", decisions=["ship it"], actions=[
        _action("do thing", due="2026-06-01", confidence="high"),
    ])
    monkeypatch.setattr(digest.engine, "complete_text", _engine_ok("- summary bullet"))
    result = digest.generate(_cfg(), tmp_path, since_days=7, today=TODAY)
    assert result.backend == "local"
    assert result.summary.summary == ["summary bullet"]
    assert len(result.summary.actions) == 1
    assert len(result.summary.decisions) == 1
    assert result.scope.window_total == 1


def test_generate_bounds_a_library_sized_action_list(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """AI10 acceptance: a digest over a library whose open actions run into the
    hundreds renders a bounded, grouped list and says what it left out."""
    for w in range(8):
        _meeting(tmp_path, _stem(TODAY, f"1{w}0000"), title=f"M{w}", workflow=f"W{w}",
                 actions=[_action(f"w{w}-t{j}", due="2026-06-01") for j in range(30)])
    # Plus a dormant backlog the window must not pull in.
    _meeting(tmp_path, _stem(TODAY - timedelta(days=120)), title="Ancient",
             actions=[_action(f"old-{j}") for j in range(200)])
    monkeypatch.setattr(digest.engine, "complete_text", _engine_ok("- b"))

    result = digest.generate(_cfg(), tmp_path, since_days=7, today=TODAY)
    assert result.scope.library_total == 440
    assert result.scope.window_total == 240
    assert len(result.summary.actions) == digest.MAX_ACTIONS
    assert all(a.group for a in result.summary.actions)
    # Grouped, and the groups are contiguous so the renderer's runs are the groups.
    groups = [a.group for a in result.summary.actions]
    assert len(set(groups)) == digest.MAX_ACTIONS // digest.MAX_PER_GROUP
    assert groups == sorted(groups, key=groups.index)
    note = result.summary.extra_sections[0]
    assert note.name == digest.SCOPE_SECTION
    assert "Showing 25 of 240" in note.content[0]
    assert any("440 open action(s) library-wide" in line for line in note.content)


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


def test_main_publish_exits_3_when_all_sinks_fail(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    """PIPE8: a digest whose every configured sink failed exits 3, like every other
    fanout caller, rather than reporting success."""
    root = tmp_path / "raw"
    _meeting(root, _stem(date.today()), title="M", decisions=["d"], actions=[])
    monkeypatch.setattr(digest.Config, "load", classmethod(lambda cls: _cfg()))
    monkeypatch.setattr(digest.engine, "complete_text", _engine_ok("- b"))

    from mp import publish_router
    monkeypatch.setattr(
        publish_router, "fanout",
        lambda *, summary_json, cfg, transcript_md: {"sinks": {"notion": {"error": "boom"}}},
    )
    rc = digest.main(["--dir", str(root), "--out-dir", str(tmp_path / "digests"), "--publish", "--json"])
    assert rc == publish_router.EXIT_PUBLISH_FAILED


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
