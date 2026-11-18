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


def test_action_item_defaults_to_open():
    # AI1: a legacy summary has no resolved field; it must decode as open.
    a = ActionItem.model_validate({"task": "x", "owner": None, "due": None, "confidence": "high"})
    assert a.resolved is False


def test_action_item_accepts_resolved_and_done_aliases():
    # Both the canonical `resolved` key and the legacy `done` spelling decode.
    assert ActionItem.model_validate({"task": "x", "resolved": True}).resolved is True
    assert ActionItem.model_validate({"task": "x", "done": True}).resolved is True


def test_action_item_serializes_as_resolved():
    # On write the key is always `resolved` (the daemon mirror reads that name).
    dumped = ActionItem(task="x", resolved=True).model_dump(mode="json")
    assert dumped["resolved"] is True
    assert "done" not in dumped
    round_tripped = ActionItem.model_validate(dumped)
    assert round_tripped.resolved is True


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
    # AI1: `resolved` is an optional action property (not required, so the LLM
    # may omit it and the tolerant decoder defaults it to open).
    action_props = decoded["input_schema"]["properties"]["actions"]["items"]
    assert "resolved" in action_props["properties"]
    assert "resolved" not in action_props["required"]


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


# ----- PIPE43 (F176): lower bounds, so an empty answer is not a summary -----


def _base(**overrides) -> dict:
    payload = {"title": "Sync", "summary": ["We shipped it."], "decisions": [], "actions": [],
               "questions": [], "attendees": [], "detected_language": "en"}
    payload.update(overrides)
    return payload


@pytest.mark.parametrize(
    "overrides",
    [{"title": ""}, {"title": "   "}, {"summary": []}, {"summary": ["", "  ", "\n"]}],
    ids=["empty_title", "blank_title", "no_bullets", "only_blank_bullets"],
)
def test_an_empty_answer_fails_validation(overrides):
    with pytest.raises(ValidationError):
        MeetingSummary.model_validate(_base(**overrides))


def test_blank_entries_are_dropped_and_their_anchors_with_them():
    anchor = [{"t": 3.0, "quote": "we shipped"}]
    s = MeetingSummary.model_validate(_base(
        summary=["  ", "We shipped it."],
        decisions=["", "Ship Friday", "   "],
        questions=["  "],
        evidence={"summary": [[], anchor]},
    ))
    assert s.summary == ["We shipped it."]
    assert s.decisions == ["Ship Friday"]
    assert s.questions == []
    # The surviving bullet keeps its own anchor: the blank one's slot went with it.
    assert [e.quote for e in s.evidence["summary"][0]] == ["we shipped"]


def test_a_stored_summary_revalidates_to_itself():
    s = MeetingSummary.model_validate(_base(decisions=["  ", "Ship"]))
    assert MeetingSummary.model_validate(json.loads(s.model_dump_json())) == s
