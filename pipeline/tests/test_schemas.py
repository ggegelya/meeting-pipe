"""Smoke tests for the structured-output schema."""
from __future__ import annotations

import json

import pytest
from pydantic import ValidationError

from mp.schemas import SUMMARY_TOOL, ActionItem, MeetingSummary


def test_summary_minimal():
    s = MeetingSummary(
        title="Sync",
        summary=["a", "b"],
        decisions=[],
        actions=[],
        questions=[],
        attendees=["Alice"],
        detected_language="en",
    )
    assert s.detected_language == "en"


def test_action_item_owner_optional():
    a = ActionItem(task="Send SOP", owner=None, due=None, confidence="low")
    assert a.owner is None
    assert a.confidence == "low"


def test_action_item_rejects_invalid_confidence():
    with pytest.raises(ValidationError):
        ActionItem(task="x", confidence="maybe")  # type: ignore[arg-type]


def test_tool_schema_serializes():
    # The tool schema is what we ship to Anthropic; make sure it round-trips.
    encoded = json.dumps(SUMMARY_TOOL)
    decoded = json.loads(encoded)
    assert decoded["name"] == "emit_meeting_summary"
    assert "input_schema" in decoded
    required = decoded["input_schema"]["required"]
    assert "actions" in required
    assert "detected_language" in required


def test_round_trip_through_schema():
    payload = {
        "title": "Q1 review",
        "summary": ["bullet 1", "bullet 2"],
        "decisions": ["We will ship Friday."],
        "actions": [
            {
                "task": "Update validation plan",
                "owner": "Bob",
                "due": "2026-05-01",
                "confidence": "high",
            }
        ],
        "questions": ["Is the QMS export green?"],
        "attendees": ["Alice", "Bob"],
        "detected_language": "en",
    }
    s = MeetingSummary.model_validate(payload)
    assert s.actions[0].due == "2026-05-01"
