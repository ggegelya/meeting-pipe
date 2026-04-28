"""Tests for summarize.py — mock the Anthropic client to avoid network calls."""
from __future__ import annotations

import json
from pathlib import Path
from unittest.mock import MagicMock, patch

import anthropic
import httpx
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


def _rate_limit_error() -> anthropic.RateLimitError:
    """Construct a RateLimitError without hitting the network.

    The anthropic SDK constructor takes (message, response, body); we pass a
    minimal httpx.Response with the right status code.
    """
    response = httpx.Response(status_code=429, request=httpx.Request("POST", "https://api.anthropic.com/v1/messages"))
    return anthropic.RateLimitError(
        message="rate limited",
        response=response,
        body={"type": "error", "error": {"type": "rate_limit_error", "message": "x"}},
    )


def test_summarize_retries_on_rate_limit(tmp_path: Path, monkeypatch):
    """Tenacity should retry RateLimitError and succeed once the API recovers."""
    transcript = tmp_path / "x.md"
    transcript.write_text("# Transcript\n\n**A**: Hi.\n", encoding="utf-8")
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")

    # Make tenacity's wait near-zero so the test runs in milliseconds.
    monkeypatch.setattr("mp.summarize._create_message.retry.wait", lambda *_a, **_k: 0)

    good_block = MagicMock(type="tool_use", input=_make_summary().model_dump())
    good_response = MagicMock(content=[good_block], stop_reason="tool_use")

    fake_client = MagicMock()
    fake_client.messages.create.side_effect = [
        _rate_limit_error(),
        _rate_limit_error(),
        good_response,
    ]

    with patch("mp.summarize.anthropic.Anthropic", return_value=fake_client):
        summarize(transcript, cfg=Config())

    # 2 rate-limited attempts + 1 success = 3 total
    assert fake_client.messages.create.call_count == 3


def test_summarize_does_not_retry_on_bad_request(tmp_path: Path, monkeypatch):
    """4xx (other than 429) is a caller bug — fail fast, don't retry."""
    transcript = tmp_path / "x.md"
    transcript.write_text("# Transcript\n\n**A**: Hi.\n", encoding="utf-8")
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")

    response = httpx.Response(
        status_code=400,
        request=httpx.Request("POST", "https://api.anthropic.com/v1/messages"),
    )
    bad_request = anthropic.BadRequestError(
        message="bad",
        response=response,
        body={"type": "error", "error": {"type": "invalid_request_error", "message": "x"}},
    )

    fake_client = MagicMock()
    fake_client.messages.create.side_effect = bad_request

    with patch("mp.summarize.anthropic.Anthropic", return_value=fake_client):
        with pytest.raises(anthropic.BadRequestError):
            summarize(transcript, cfg=Config())

    # Single call, no retries.
    assert fake_client.messages.create.call_count == 1
