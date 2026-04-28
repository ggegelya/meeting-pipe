"""Tests for summarize.py — mock the Anthropic client to avoid network calls."""
from __future__ import annotations

import json
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

from mp.config import Config
from mp.summarize import _render_summary_md, summarize
from mp.schemas import ActionItem, MeetingSummary


def _make_summary() -> MeetingSummary:
    return MeetingSummary(
        title="Phase 6 sync",
        summary=["Reviewed Notion publishing schema", "Confirmed regulated mode"],
        decisions=["We will ship Friday."],
        actions=[
            ActionItem(task="Update SOP", owner="Alice", due="2026-05-01", confidence="high"),
            ActionItem(task="Investigate diarization for UA", owner=None, confidence="low"),
        ],
        questions=["Should we cap transcript size?"],
        attendees=["Alice", "Bob"],
        detected_language="en",
    )


def test_render_summary_md_has_all_sections():
    md = _render_summary_md(_make_summary())
    assert "# Phase 6 sync" in md
    assert "**Attendees:** Alice, Bob" in md
    assert "## Summary" in md
    assert "## Decisions" in md
    assert "## Action Items" in md
    assert "## Open Questions" in md
    assert "_unassigned_" in md
    assert "due 2026-05-01" in md


def test_summarize_calls_anthropic_and_writes_outputs(tmp_path: Path, monkeypatch):
    transcript = tmp_path / "20260428-1200.md"
    transcript.write_text(
        "# Transcript\n\n**A**: Hi.\n\n**B**: We will ship Friday.\n",
        encoding="utf-8",
    )

    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")

    fake_summary = _make_summary()

    # Mock the SDK response so the test doesn't hit the network.
    fake_tool_block = MagicMock()
    fake_tool_block.type = "tool_use"
    fake_tool_block.input = fake_summary.model_dump()

    fake_response = MagicMock()
    fake_response.content = [fake_tool_block]
    fake_response.stop_reason = "tool_use"

    fake_client = MagicMock()
    fake_client.messages.create.return_value = fake_response

    cfg = Config()  # defaults

    with patch("mp.summarize.anthropic.Anthropic", return_value=fake_client):
        out = summarize(transcript, cfg=cfg)

    assert out["json"].exists()
    assert out["md"].exists()

    parsed = MeetingSummary.model_validate_json(out["json"].read_text(encoding="utf-8"))
    assert parsed.title == "Phase 6 sync"
    assert parsed.actions[0].owner == "Alice"

    # Confirm the API was called with tool_choice forcing the schema.
    call = fake_client.messages.create.call_args
    assert call.kwargs["tool_choice"]["name"] == "emit_meeting_summary"
    assert call.kwargs["tools"][0]["name"] == "emit_meeting_summary"


def test_summarize_retries_on_schema_violation(tmp_path: Path, monkeypatch):
    transcript = tmp_path / "x.md"
    transcript.write_text("# Transcript\n\n**A**: Hi.\n", encoding="utf-8")
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")

    bad_block = MagicMock()
    bad_block.type = "tool_use"
    bad_block.input = {"title": "incomplete"}  # missing required fields

    good_block = MagicMock()
    good_block.type = "tool_use"
    good_block.input = _make_summary().model_dump()

    bad = MagicMock(content=[bad_block], stop_reason="tool_use")
    good = MagicMock(content=[good_block], stop_reason="tool_use")

    fake_client = MagicMock()
    fake_client.messages.create.side_effect = [bad, good]

    with patch("mp.summarize.anthropic.Anthropic", return_value=fake_client):
        summarize(transcript, cfg=Config())

    assert fake_client.messages.create.call_count == 2
