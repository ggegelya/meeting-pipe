"""Pydantic models for the summary JSON.

§10 of SPEC.md is the source of truth. Field names and types are locked-in:
Notion publishing assumes this exact shape.
"""
from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field


class ActionItem(BaseModel):
    task: str
    owner: str | None = None
    due: str | None = None  # ISO 8601 date if extractable
    confidence: Literal["low", "medium", "high"] = "medium"


class MeetingSummary(BaseModel):
    title: str = Field(..., max_length=120)
    summary: list[str] = Field(..., max_length=10)
    decisions: list[str] = Field(default_factory=list)
    actions: list[ActionItem] = Field(default_factory=list)
    questions: list[str] = Field(default_factory=list)
    attendees: list[str] = Field(default_factory=list)
    detected_language: str = "en"


# JSON schema delivered to Anthropic's `tools` parameter for structured output.
# Keep aligned with MeetingSummary above. Anthropic's tool_choice forces the
# model to emit a single tool call whose input matches this schema.
SUMMARY_TOOL = {
    "name": "emit_meeting_summary",
    "description": (
        "Emit the structured meeting summary. Call exactly once. "
        "Do not invent action items: if no clear owner is stated, set owner to null "
        "and confidence to \"low\"."
    ),
    "input_schema": {
        "type": "object",
        "properties": {
            "title": {
                "type": "string",
                "maxLength": 120,
                "description": "Short title derived from content (≤60 chars preferred).",
            },
            "summary": {
                "type": "array",
                "items": {"type": "string"},
                "maxItems": 5,
                "description": "≤5 bullets, ≤30 words each. Total under 150 words.",
            },
            "decisions": {
                "type": "array",
                "items": {"type": "string"},
                "description": "Only include statements with explicit commitment language (will/agreed/decided/approved).",
            },
            "actions": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "task": {"type": "string"},
                        "owner": {"type": ["string", "null"]},
                        "due": {"type": ["string", "null"], "description": "ISO 8601 date if extractable."},
                        "confidence": {"type": "string", "enum": ["low", "medium", "high"]},
                    },
                    "required": ["task", "owner", "due", "confidence"],
                    "additionalProperties": False,
                },
            },
            "questions": {
                "type": "array",
                "items": {"type": "string"},
                "description": "Unresolved questions raised during the meeting.",
            },
            "attendees": {
                "type": "array",
                "items": {"type": "string"},
                "description": "Inferred from speaker labels and content.",
            },
            "detected_language": {
                "type": "string",
                "description": "ISO 639-1 code, e.g. 'en' or 'uk'.",
            },
        },
        "required": [
            "title",
            "summary",
            "decisions",
            "actions",
            "questions",
            "attendees",
            "detected_language",
        ],
        "additionalProperties": False,
    },
}
