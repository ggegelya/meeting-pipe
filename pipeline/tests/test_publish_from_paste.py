"""Tests for the BYO-summary parser + publish flow.

The Markdown parser is the critical surface — once a hand-written
summary parses into a valid MeetingSummary, the rest of the publish
path is the same code already covered by test_publish_notion.py.
"""
from __future__ import annotations

import httpx
import pytest

from mp.config import Config
from mp.publish_from_paste import main as paste_main
from mp.publish_from_paste import parse_summary_md, publish_from_paste
from mp.publish_router import EXIT_PUBLISH_FAILED
from mp.schemas import MeetingSummary


def _summary_md_canonical() -> str:
    return """\
# Phase 6 Sync

**Attendees:** Alice, Bob, Carol

_Language: en_

## Summary
- Reviewed Notion publishing schema
- Confirmed regulated mode behaviour
- Decided to ship Friday

## Decisions
1. Cap transcripts at 80 000 chars
2. Roll forward on Sonnet 4.6

## Action Items
- [ ] **Alice**: Update SOP — due 2026-05-01
- [ ] **Bob**: Investigate UA diarization
- [ ] Decide on icon style

## Open Questions
- Should we add per-app auto-record?
- Do we need an audit log?
"""


def test_parse_extracts_title_and_bullets():
    s = parse_summary_md(_summary_md_canonical())
    assert s.title == "Phase 6 Sync"
    assert "Reviewed Notion publishing schema" in s.summary
    assert len(s.summary) == 3


def test_parse_extracts_attendees_from_inline_label():
    s = parse_summary_md(_summary_md_canonical())
    assert s.attendees == ["Alice", "Bob", "Carol"]


def test_parse_extracts_decisions_numbered_list():
    s = parse_summary_md(_summary_md_canonical())
    assert "Cap transcripts at 80 000 chars" in s.decisions
    assert "Roll forward on Sonnet 4.6" in s.decisions


def test_parse_extracts_actions_with_owner_and_due():
    s = parse_summary_md(_summary_md_canonical())
    by_owner = {a.owner: a for a in s.actions}
    assert "Alice" in by_owner
    assert by_owner["Alice"].due == "2026-05-01"
    assert by_owner["Alice"].task == "Update SOP"
    # Bob has no due date.
    assert by_owner["Bob"].due is None
    # Owner-less action survives with owner=None.
    unowned = [a for a in s.actions if a.owner is None]
    assert len(unowned) == 1
    assert unowned[0].task == "Decide on icon style"


def test_parse_extracts_open_questions():
    s = parse_summary_md(_summary_md_canonical())
    assert any("auto-record" in q for q in s.questions)
    assert any("audit log" in q for q in s.questions)


def test_parse_handles_minimal_markdown():
    """LLMs sometimes return barebones output. Don't crash on missing sections."""
    raw = "# Quick chat\n\nNothing structured here.\n"
    s = parse_summary_md(raw)
    assert s.title == "Quick chat"
    # Schema requires summary; we synthesize a placeholder.
    assert s.summary  # not empty
    assert s.decisions == []
    assert s.actions == []


def test_parse_truncates_long_title():
    raw = "# " + ("X" * 200) + "\n## Summary\n- bullet"
    s = parse_summary_md(raw)
    assert len(s.title) == 120


def test_parse_caps_summary_bullets_at_ten():
    bullets = "\n".join(f"- bullet {i}" for i in range(20))
    raw = f"# Title\n## Summary\n{bullets}\n"
    s = parse_summary_md(raw)
    assert len(s.summary) == 10


def test_parse_picks_up_language_hint():
    raw = "# T\n_Language detected: uk_\n## Summary\n- bullet"
    s = parse_summary_md(raw)
    assert s.detected_language == "uk"


def test_parse_accepts_checked_todos():
    """Some LLMs emit `[x]` for action items the meeting already resolved.
    They should land in actions, not vanish silently, and AI1 maps the
    checked box onto the resolved flag."""
    raw = (
        "# Quick chat\n## Summary\n- bullet\n## Action Items\n"
        "- [x] **Alice**: Done before the meeting\n"
        "- [X] Also already done\n"
        "- [ ] **Bob**: Pending\n"
    )
    s = parse_summary_md(raw)
    by_task = {a.task: a for a in s.actions}
    assert set(by_task) == {"Done before the meeting", "Also already done", "Pending"}
    # AI1: `[x]`/`[X]` -> resolved, `[ ]` -> open.
    assert by_task["Done before the meeting"].resolved is True
    assert by_task["Also already done"].resolved is True
    assert by_task["Pending"].resolved is False


def test_resolved_round_trips_through_rendered_markdown():
    """AI1: render -> re-parse preserves the resolved flag, so a paste re-run
    (which rewrites summary.json from the markdown) does not reopen closed
    actions. The order is stable, so the resolved action stays resolved and the
    open one stays open. (The parser keeps the confidence suffix in the task
    text; that is a pre-existing BYO quirk and not what this test pins.)"""
    from mp.markdown import render_summary_md
    from mp.schemas import ActionItem, MeetingSummary

    s = MeetingSummary(
        title="Recap",
        summary=["x"],
        actions=[
            ActionItem(task="Closed item", owner="Alice", due="2026-05-01",
                       confidence="high", resolved=True),
            ActionItem(task="Open item", owner="Bob", due=None, confidence="high"),
        ],
        detected_language="en",
    )
    reparsed = parse_summary_md(render_summary_md(s))
    assert len(reparsed.actions) == 2
    closed, openn = reparsed.actions
    assert closed.task.startswith("Closed item")
    assert closed.resolved is True
    assert closed.due == "2026-05-01"  # due survives the trailer strip
    assert openn.task.startswith("Open item")
    assert openn.resolved is False


def test_parse_accepts_plain_attendees_label():
    """Different LLM frontends emit `Attendees:` with or without bold.
    Both forms should populate attendees."""
    raw = "# T\nAttendees: Alice, Bob\n## Summary\n- bullet"
    s = parse_summary_md(raw)
    assert s.attendees == ["Alice", "Bob"]


# --- End-to-end publish_from_paste ----------------------------------------


def _install_mock_transport(monkeypatch, handler):
    real_init = httpx.Client.__init__

    def patched_init(self, *args, **kwargs):
        kwargs["transport"] = httpx.MockTransport(handler)
        real_init(self, *args, **kwargs)

    monkeypatch.setattr(httpx.Client, "__init__", patched_init)


def test_publish_from_paste_round_trip(tmp_path, monkeypatch):
    """Hand-written .summary.md should result in the same Notion page
    shape as the auto path. We verify the wire calls, not Notion."""
    transcript = tmp_path / "20260430-1500.md"
    transcript.write_text("# Transcript\n\n**A**: hi\n\n**B**: hi\n", encoding="utf-8")
    summary_md = tmp_path / "20260430-1500.summary.md"
    summary_md.write_text(_summary_md_canonical(), encoding="utf-8")

    monkeypatch.setenv("NOTION_TOKEN", "ntn-test")
    cfg = Config()
    cfg.notion.database_id = "db-from-paste"

    posted: dict = {}

    def handler(request: httpx.Request) -> httpx.Response:
        if request.method == "POST" and request.url.path == "/v1/pages":
            posted["payload"] = request.read()
            return httpx.Response(
                200,
                json={"id": "page-byo-1", "url": "https://www.notion.so/page-byo-1"},
            )
        return httpx.Response(404, json={"message": "unexpected"})

    _install_mock_transport(monkeypatch, handler)

    result = publish_from_paste(transcript, cfg=cfg)
    assert result["page_id"] == "page-byo-1"

    # Side effect: canonical .summary.json now sits next to the transcript.
    assert (tmp_path / "20260430-1500.summary.json").exists()
    # PIPE50: the pasted .summary.md is exactly what was pasted, never re-rendered.
    assert summary_md.read_text(encoding="utf-8") == _summary_md_canonical()


def test_publish_from_paste_missing_file_raises(tmp_path):
    transcript = tmp_path / "x.md"
    transcript.write_text("anything", encoding="utf-8")
    with pytest.raises(FileNotFoundError):
        publish_from_paste(transcript, cfg=Config())


def test_publish_from_paste_regulated_mode_preserves_user_md(tmp_path, monkeypatch):
    """In regulated mode the user's hand-written .summary.md must survive
    untouched — overwriting it with our canonical render before short-
    circuiting the publish would silently destroy editorial content."""
    transcript = tmp_path / "20260430-1500.md"
    transcript.write_text("# Transcript\n", encoding="utf-8")
    user_md = "# Confidential\n\nDo not rewrite this body. Custom layout matters.\n"
    summary_md = tmp_path / "20260430-1500.summary.md"
    summary_md.write_text(user_md, encoding="utf-8")

    cfg = Config()
    cfg.modes.regulated_mode = True

    # No mock transport — regulated_mode must short-circuit before any
    # network call. If we hit Notion the test fails on the missing token.
    monkeypatch.delenv("NOTION_TOKEN", raising=False)

    result = publish_from_paste(transcript, cfg=cfg)
    assert result.get("regulated") is True
    assert result["page_id"] is None

    # User's .summary.md untouched — same bytes back.
    assert summary_md.read_text(encoding="utf-8") == user_md
    # And no .summary.json sidecar got written either; regulated_mode
    # means "nothing on disk gets rewritten without an explicit user
    # action".
    assert not (tmp_path / "20260430-1500.summary.json").exists()


def test_publish_from_paste_routes_through_fanout(tmp_path, monkeypatch):
    """PIPE2/AUD-15: a BYO paste must fan out to the configured sinks via
    publish_router.fanout, not call Notion directly, so an obsidian-only
    workflow reaches Obsidian instead of always getting a Notion page."""
    transcript = tmp_path / "20260430-1500.md"
    transcript.write_text("# Transcript\n", encoding="utf-8")
    summary_md = tmp_path / "20260430-1500.summary.md"
    summary_md.write_text(_summary_md_canonical(), encoding="utf-8")

    cfg = Config()
    cfg.output.sinks = ["obsidian"]  # deliberately not Notion

    calls: dict = {}

    def fake_fanout(*, summary_json, cfg, transcript_md):
        calls["summary_json"] = summary_json
        return {"page_id": None, "page_url": None, "sinks": {"obsidian": {"ok": True}}}

    monkeypatch.setattr("mp.publish_from_paste.fanout", fake_fanout)

    result = publish_from_paste(transcript, cfg=cfg)

    # Routed through the fanout (not publish_notion.publish) with the canonical
    # summary json the paste wrote.
    assert calls["summary_json"] == tmp_path / "20260430-1500.summary.json"
    assert result["sinks"]["obsidian"]["ok"] is True


# ----- PIPE1: the paste path shares the honest-failure contract -----


def test_main_exits_publish_failed_when_every_sink_failed(tmp_path, monkeypatch):
    """The daemon's in-app paste box (TECH-UX3) treats a zero exit as "published"
    and clears the failure sidecar, so this path lies the same way `run-all` did."""
    transcript = tmp_path / "20260516-0900.md"
    transcript.write_text("# transcript", encoding="utf-8")

    monkeypatch.setattr(
        "mp.publish_from_paste.publish_from_paste",
        lambda t: {"sinks": {"notion": {"error": "boom"}}, "failures": [("notion", "boom")]},
    )
    assert paste_main([str(transcript)]) == EXIT_PUBLISH_FAILED


def test_main_exits_zero_on_a_regulated_skip(tmp_path, monkeypatch):
    """A regulated paste writes nothing and publishes nothing. That is the
    documented behaviour, not a failure."""
    transcript = tmp_path / "20260516-0900.md"
    transcript.write_text("# transcript", encoding="utf-8")

    monkeypatch.setattr(
        "mp.publish_from_paste.publish_from_paste",
        lambda t: {"page_id": None, "page_url": None, "regulated": True},
    )
    assert paste_main([str(transcript)]) == 0


# ----- PIPE50: the pasted file is never rewritten, and a lossy parse is refused -----


_PROSE_SUMMARY = """\
# Planning sync

## Summary
We walked through the quarter's plan in some detail and agreed the scope
was too wide; most of the hour went on the migration.

## Decisions
- Ship the migration on Friday
"""


def _paste(tmp_path, text: str):
    transcript = tmp_path / "20260430-1500.md"
    transcript.write_text("# Transcript\n\n**A**: hi\n", encoding="utf-8")
    summary_md = tmp_path / "20260430-1500.summary.md"
    summary_md.write_text(text, encoding="utf-8")
    return transcript, summary_md


def _no_fanout(monkeypatch) -> list:
    calls: list = []
    monkeypatch.setattr("mp.publish_from_paste.fanout",
                        lambda **k: calls.append(k) or {"page_id": None, "page_url": None,
                                                         "sinks": {}})
    return calls


def test_prose_under_summary_is_refused_before_anything_is_written(tmp_path, monkeypatch):
    transcript, summary_md = _paste(tmp_path, _PROSE_SUMMARY)
    calls = _no_fanout(monkeypatch)
    with pytest.raises(ValueError, match=r"The `## Summary` section could not be read"):
        publish_from_paste(transcript, cfg=Config())
    assert summary_md.read_text(encoding="utf-8") == _PROSE_SUMMARY
    assert not (tmp_path / "20260430-1500.summary.json").exists()
    assert calls == []


def test_untickable_action_lines_are_refused_with_the_expected_shape(tmp_path, monkeypatch):
    text = "# T\n\n## Summary\n- a point\n\n## Action Items\n- Alice sends the deck\n"
    transcript, _ = _paste(tmp_path, text)
    _no_fanout(monkeypatch)
    with pytest.raises(ValueError, match=r"- \[ \] \*\*Owner\*\*: task"):
        publish_from_paste(transcript, cfg=Config())


def test_well_formed_bullets_publish_and_leave_the_paste_byte_identical(tmp_path, monkeypatch):
    transcript, summary_md = _paste(tmp_path, _summary_md_canonical())
    before = summary_md.read_bytes()
    calls = _no_fanout(monkeypatch)
    publish_from_paste(transcript, cfg=Config())
    assert summary_md.read_bytes() == before
    assert summary_md.stat().st_mode & 0o777 == 0o600  # private, without a rewrite
    stored = MeetingSummary.model_validate_json(
        (tmp_path / "20260430-1500.summary.json").read_text(encoding="utf-8"))
    assert stored.summary[0] == "Reviewed Notion publishing schema"
    assert [a.owner for a in stored.actions][:2] == ["Alice", "Bob"]
    assert len(calls) == 1


def test_twelve_bullets_publish_ten_and_say_so(tmp_path, monkeypatch):
    bullets = "\n".join(f"- bullet {i}" for i in range(12))
    transcript, _ = _paste(tmp_path, f"# Title\n\n## Summary\n{bullets}\n")
    _no_fanout(monkeypatch)
    emitted: list[tuple[tuple, dict]] = []
    monkeypatch.setattr("mp.publish_from_paste.events.emit",
                        lambda *a, **k: emitted.append((a, k)))
    publish_from_paste(transcript, cfg=Config())
    stored = MeetingSummary.model_validate_json(
        (tmp_path / "20260430-1500.summary.json").read_text(encoding="utf-8"))
    assert len(stored.summary) == 10
    assert emitted == [(("pipeline", "paste_truncated"),
                        {"title_chars": 5, "title_limit": 120,
                         "summary_bullets": 12, "summary_limit": 10})]


def test_a_paste_with_no_summary_heading_keeps_the_placeholder(tmp_path, monkeypatch):
    transcript, summary_md = _paste(tmp_path, "# Quick chat\n\nNothing structured here.\n")
    _no_fanout(monkeypatch)
    publish_from_paste(transcript, cfg=Config())
    assert summary_md.read_text(encoding="utf-8") == "# Quick chat\n\nNothing structured here.\n"


def test_main_on_the_prose_case_exits_1_with_one_fail_line(tmp_path, monkeypatch, capsys):
    """The paste box reads its explanation from the last `[FAIL] <sentence>` stderr line, capped
    at 400 characters and refusing `{`, so the refusal has to be that line."""
    transcript, _ = _paste(tmp_path, _PROSE_SUMMARY)
    _no_fanout(monkeypatch)
    monkeypatch.setattr("mp.publish_from_paste.entry.prepare", lambda cfg, md: Config())
    assert paste_main([str(transcript)]) == 1
    fails = [line for line in capsys.readouterr().err.splitlines() if line.startswith("[FAIL] ")]
    assert len(fails) == 1
    assert "`## Summary`" in fails[0] and len(fails[0]) <= 407 and "{" not in fails[0]


def test_several_lossy_sections_still_fit_one_short_sentence():
    from mp.publish_from_paste import lossy_sections, refusal_message

    text = ("# T\n## Summary\nprose\n## Decisions\nNone.\n## Action Items\nAlice sends it\n"
            "## Open Questions\nnone yet\n")
    problems = lossy_sections(text)
    assert [h for h, _ in problems] == ["Summary", "Decisions", "Action Items", "Open Questions"]
    message = refusal_message(problems)
    assert len(message) <= 400 and "{" not in message


def test_the_apps_own_rendered_summary_is_never_refused():
    from mp.markdown import render_summary_md
    from mp.publish_from_paste import lossy_sections
    from mp.schemas import ActionItem

    full = MeetingSummary(title="T", summary=["a"], decisions=["d"], questions=["q?"],
                          actions=[ActionItem(task="x", owner="Al", due="2026-01-01"),
                                   ActionItem(task="y")], attendees=["A"])
    bare = MeetingSummary(title="T", summary=["a"])
    for s in (full, bare):
        assert lossy_sections(render_summary_md(s, "20260101-1000")) == []
