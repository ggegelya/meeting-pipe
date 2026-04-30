"""Tests for the BYO-summary parser + publish flow.

The Markdown parser is the critical surface — once a hand-written
summary parses into a valid MeetingSummary, the rest of the publish
path is the same code already covered by test_publish_notion.py.
"""
from __future__ import annotations

import httpx
import pytest

from mp.config import Config
from mp.publish_from_paste import parse_summary_md, publish_from_paste


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
    # And the .summary.md was re-rendered into our canonical shape.
    rendered = summary_md.read_text(encoding="utf-8")
    assert "## Summary" in rendered
    assert "## Action Items" in rendered


def test_publish_from_paste_missing_file_raises(tmp_path):
    transcript = tmp_path / "x.md"
    transcript.write_text("anything", encoding="utf-8")
    with pytest.raises(FileNotFoundError):
        publish_from_paste(transcript, cfg=Config())
