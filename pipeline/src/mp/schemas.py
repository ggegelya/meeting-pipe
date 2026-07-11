"""Pydantic models for the summary JSON.

ADR 0014 (typed summary model) is the rationale; these models are the lock.
Field names and types are locked-in; Notion publishing assumes this exact shape.
"""
from __future__ import annotations

from typing import Literal

from pydantic import AliasChoices, BaseModel, Field, field_validator

from .prompt_safety import clean_person

# Named so consumers that coerce a free-form string onto this field (digest's
# `_clamp_confidence`) can say so in their signature rather than returning `str`.
Confidence = Literal["low", "medium", "high"]


class ActionItem(BaseModel):
    task: str
    owner: str | None = None
    due: str | None = None  # ISO 8601 date if extractable
    confidence: Confidence = "medium"
    # AI1: an item is open until explicitly resolved. Absent on legacy
    # `<stem>.summary.json` files, so it defaults to open; `done` is accepted as
    # an alias on read so the older spelling round-trips. Aging is computed off
    # `due` in `mp actions`, not stored.
    resolved: bool = Field(
        default=False,
        validation_alias=AliasChoices("resolved", "done"),
        serialization_alias="resolved",
    )

    model_config = {"populate_by_name": True}

    @field_validator("owner", mode="after")
    @classmethod
    def _scrub_owner(cls, v: str | None) -> str | None:
        # The owner is model-extracted from an untrusted transcript and flows to
        # Notion to-dos / Obsidian / the correction corpus. Drop it if it carries
        # an email, URL, @-mention, or control char rather than forward it. (TECH-SEC6)
        return clean_person(v)


class ExtraSection(BaseModel):
    """A workflow-defined extra summary section (WF7). The workflow names the
    section and gives the model an instruction; the model fills `content` as
    bullets. Optional and tolerant: absent on every legacy summary and on any
    summary from a workflow that defines no extra sections."""
    name: str = Field(..., max_length=80)
    content: list[str] = Field(default_factory=list)


class MeetingSummary(BaseModel):
    title: str = Field(..., max_length=120)
    summary: list[str] = Field(..., max_length=10)
    decisions: list[str] = Field(default_factory=list)
    actions: list[ActionItem] = Field(default_factory=list)
    questions: list[str] = Field(default_factory=list)
    attendees: list[str] = Field(default_factory=list)
    detected_language: str = "en"
    # WF7: workflow-defined extra sections. Defaults empty so every existing
    # `<stem>.summary.json` and every non-configuring workflow round-trips
    # unchanged; a publisher renders these only when present.
    extra_sections: list[ExtraSection] = Field(default_factory=list)

    @field_validator("attendees", mode="after")
    @classmethod
    def _scrub_attendees(cls, v: list[str]) -> list[str]:
        # Same untrusted-field scrub as owner: keep only safe display names. (TECH-SEC6)
        return [cleaned for a in v if (cleaned := clean_person(a)) is not None]


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
                        "resolved": {
                            "type": "boolean",
                            "description": "True only if the meeting states the item is already done; default false (open).",
                        },
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
            "extra_sections": {
                "type": "array",
                "description": (
                    "Only the extra sections the system prompt explicitly requests, "
                    "each filled per its instruction. Omit or leave empty when none are requested."
                ),
                "items": {
                    "type": "object",
                    "properties": {
                        "name": {"type": "string", "description": "The requested section's exact name."},
                        "content": {"type": "array", "items": {"type": "string"}},
                    },
                    "required": ["name", "content"],
                    "additionalProperties": False,
                },
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
