"""Pydantic models for the summary JSON.

ADR 0014 (typed summary model) is the rationale; these models are the lock.
Field names and types are locked-in; Notion publishing assumes this exact shape.
"""
from __future__ import annotations

import json
from typing import Any, Literal

from pydantic import AliasChoices, BaseModel, Field, field_validator, model_validator

from .prompt_safety import clean_person

# Named so consumers that coerce a free-form string onto this field (digest's
# `_clamp_confidence`) can say so in their signature rather than returning `str`.
Confidence = Literal["low", "medium", "high"]

# FEAT10. The string sections whose anchors ride in the index-aligned
# `MeetingSummary.evidence` map rather than inline (actions carry theirs on the
# item). Order is the render order, so a caller can iterate this tuple.
EVIDENCE_SECTIONS = ("summary", "decisions", "questions")
# At most two anchors per point: enough to corroborate, few enough that the chip
# row stays quiet and the output-token bump stays small. A constant, not a config
# knob (FEAT10 explicitly ships none).
MAX_EVIDENCE_PER_ITEM = 2

# PIPE15. The list-valued fields a model has actually been observed handing back
# as a JSON-encoded string instead of a list. `attendees` sits beside the three
# evidence sections because it is the other bare `list[str]` the tool schema asks
# for; `actions` and `extra_sections` are lists of objects and have never arrived
# stringified, so they stay out rather than being added speculatively.
STRINGIFIED_LIST_FIELDS = (*EVIDENCE_SECTIONS, "attendees")


class Evidence(BaseModel):
    """FEAT10: one anchor from a summary point back into the transcript.

    `quote` is a short verbatim phrase; `t` is seconds into the recording. Both
    fields default rather than being required, because an anchor is untrusted
    model output arriving on the same call as the summary: a malformed one must
    cost its own anchor, never the whole summary. `evidence.verify` is what
    decides an anchor is real, so nothing reaches disk unresolved.

    `t` decodes tolerantly from the `[mm:ss]` marker the timestamped transcript
    render puts in front of each turn, so the model can copy what it saw instead
    of converting to seconds and getting the arithmetic wrong. The stored shape
    is always float seconds.
    """

    quote: str = ""
    t: float = 0.0

    @field_validator("t", mode="before")
    @classmethod
    def _coerce_time(cls, v: Any) -> Any:
        # `bool` is an `int` subclass; a JSON `true` must not become a timestamp.
        if isinstance(v, bool):
            return 0.0
        if isinstance(v, (int, float)):
            return float(v)
        if not isinstance(v, str):
            return 0.0
        text = v.strip().lstrip("[").rstrip("]").strip()
        if not text:
            return 0.0
        parts = text.split(":")
        if len(parts) == 1:
            try:
                return float(parts[0])
            except ValueError:
                return 0.0
        # "mm:ss" or "h:mm:ss", the two forms the render emits.
        try:
            numbers = [float(p) for p in parts]
        except ValueError:
            return 0.0
        seconds = 0.0
        for n in numbers:
            seconds = seconds * 60 + n
        return seconds


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
    # AI10: the grouping key of a roll-up that gathers actions from many
    # meetings - the workflow the action's meeting belongs to, or that meeting's
    # title when it is untagged. Only `mp digest` sets it (inside one meeting's
    # summary every action shares one source, so the field would say nothing),
    # and it is deliberately absent from SUMMARY_TOOL below: no model ever fills
    # it, the digest assembles it from facts already on disk.
    group: str | None = None
    # FEAT10: verified anchors back into the transcript, inline because an action
    # is already an object (the string sections need the parallel `evidence` map
    # below instead). Absent on every legacy summary, so it defaults empty.
    evidence: list[Evidence] = Field(default_factory=list)

    model_config = {"populate_by_name": True}

    @field_validator("owner", mode="after")
    @classmethod
    def _scrub_owner(cls, v: str | None) -> str | None:
        # The owner is model-extracted from an untrusted transcript and flows to
        # Notion to-dos / Obsidian / the correction corpus. Drop it if it carries
        # an email, URL, @-mention, or control char rather than forward it. (TECH-SEC6)
        return clean_person(v)

    @field_validator("evidence", mode="after")
    @classmethod
    def _cap_evidence(cls, v: list[Evidence]) -> list[Evidence]:
        return v[:MAX_EVIDENCE_PER_ITEM]


class ExtraSection(BaseModel):
    """A workflow-defined extra summary section (WF7). The workflow names the
    section and gives the model an instruction; the model fills `content` as
    bullets. Optional and tolerant: absent on every legacy summary and on any
    summary from a workflow that defines no extra sections."""
    name: str = Field(..., max_length=80)
    content: list[str] = Field(default_factory=list)


def _decode_stringified_lists(payload: dict[str, Any]) -> dict[str, Any]:
    """PIPE15: accept a `list[str]` field that arrived as a JSON-encoded string.

    Observed three times on the owner's real corpus (2026-05-22 `summary`,
    2026-06-10 `questions`, 2026-07-20 `summary`), and it is the whole failure:
    the content is right, the model just wrapped it in quotes, and pydantic's
    strict `list[str]` rejects it with `list_type`. Two of the three recovered
    only because the blind attempt-2 re-roll happened to come back well-formed,
    at the cost of a second paid call; the third killed a run.

    Deliberately narrow. Only a string that `json.loads` to a **list** is
    replaced, so `"we talked about X"` on a list field still fails validation
    rather than being silently wrapped into a one-item list: that shape is the
    model answering a different question, and accepting it would ship a summary
    whose section is one run-on sentence. A non-string, a non-JSON string, and a
    string decoding to a scalar or a dict are all left exactly as they were, which
    is what keeps this a no-op on the stored shape and idempotent on re-validation.
    """
    out: dict[str, Any] | None = None
    for field in STRINGIFIED_LIST_FIELDS:
        raw = payload.get(field)
        if not isinstance(raw, str):
            continue
        try:
            decoded = json.loads(raw)
        except ValueError:
            continue
        if not isinstance(decoded, list):
            continue
        if out is None:
            out = dict(payload)
        out[field] = decoded
    return out if out is not None else payload


def normalize_model_summary(payload: Any) -> Any:
    """FEAT10: flatten the model-facing section shape into the stored one.

    `SUMMARY_TOOL` asks for `summary` / `decisions` / `questions` as
    `{text, evidence[]}` objects, so an anchor attaches at generation and can
    never drift out of alignment with the point it backs. On disk those sections
    stay plain `list[str]` (ADR 0014 stays intact, every publisher and the whole
    Facts / actions / embedding surface keeps reading strings), with the anchors
    in an index-aligned `evidence` map beside them.

    One normalizer rather than one per backend: it is wired as a `mode="before"`
    model validator, so every path that validates a `MeetingSummary` gets it, the
    Anthropic tool call and the JSON-recovery paths in `summarize_local`,
    `provider_claude_cli`, and `provider_openai` alike. A new backend inherits it
    instead of having to remember it.

    A no-op on the stored shape (entries already strings) and on anything that is
    not a dict, so a legacy `<stem>.summary.json` round-trips unchanged and
    re-validating an already-normalized payload is idempotent.

    PIPE15 added a second transform in front of the flattening, for the same
    reason FEAT10's lives here rather than at four call sites: a section handed
    back as a JSON-encoded string is a malformation every backend can receive, so
    the repair belongs where every backend inherits it. It runs first so a
    stringified list of `{text, evidence}` objects gets both treatments.
    """
    if not isinstance(payload, dict):
        return payload
    payload = _decode_stringified_lists(payload)
    raw_sections = {s: payload.get(s) for s in EVIDENCE_SECTIONS}
    if not any(
        isinstance(items, list) and any(isinstance(i, dict) for i in items)
        for items in raw_sections.values()
    ):
        return payload

    out = dict(payload)
    existing = out.get("evidence")
    evidence: dict[str, Any] = dict(existing) if isinstance(existing, dict) else {}
    for section, items in raw_sections.items():
        if not isinstance(items, list):
            continue
        if not any(isinstance(i, dict) for i in items):
            continue
        texts: list[Any] = []
        anchors: list[list[Any]] = []
        for item in items:
            if isinstance(item, dict):
                text = item.get("text")
                texts.append(text if isinstance(text, str) else "")
                raw = item.get("evidence")
                anchors.append(list(raw[:MAX_EVIDENCE_PER_ITEM]) if isinstance(raw, list) else [])
            else:
                texts.append(item)
                anchors.append([])
        out[section] = texts
        # Only claim the section when something actually cited; an all-empty list
        # would write a map that says nothing.
        if any(anchors):
            evidence[section] = anchors
    if evidence:
        out["evidence"] = evidence
    return out


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
    # FEAT10: anchors for the string sections, keyed by section name and
    # index-aligned with it (`evidence["summary"][2]` backs `summary[2]`). A
    # parallel map rather than an inline field because turning `summary` into a
    # list of objects would break the ADR 0014 lock and every publisher. Absent
    # on legacy files and on any backend that emits no evidence.
    evidence: dict[str, list[list[Evidence]]] = Field(default_factory=dict)

    @model_validator(mode="before")
    @classmethod
    def _normalize_sections(cls, data: Any) -> Any:
        return normalize_model_summary(data)

    @field_validator("attendees", mode="after")
    @classmethod
    def _scrub_attendees(cls, v: list[str]) -> list[str]:
        # Same untrusted-field scrub as owner: keep only safe display names. (TECH-SEC6)
        return [cleaned for a in v if (cleaned := clean_person(a)) is not None]

    @model_validator(mode="after")
    def _align_evidence(self) -> "MeetingSummary":
        """Keep each section's anchor list exactly as long as the section it
        indexes, and drop keys that are not one of the three string sections.

        Alignment is the whole contract of this field, so it is repaired here
        rather than defended at every read site: a hand-edited file, a model that
        returned four bullets and five anchor slots, or a Swift edit that added a
        row would otherwise hand consumers an off-by-one citation, which is worse
        than none at all.
        """
        aligned: dict[str, list[list[Evidence]]] = {}
        for section in EVIDENCE_SECTIONS:
            anchors = self.evidence.get(section)
            if not anchors:
                continue
            width = len(getattr(self, section))
            trimmed = [a[:MAX_EVIDENCE_PER_ITEM] for a in anchors[:width]]
            trimmed += [[] for _ in range(width - len(trimmed))]
            if any(trimmed):
                aligned[section] = trimmed
        self.evidence = aligned
        return self


# FEAT10: the anchor array every citable point carries. The transcript handed to
# the model prefixes each turn with its `[mm:ss]` marker, so `t` is something the
# model copies rather than computes; `Evidence._coerce_time` accepts either that
# marker or plain seconds. Every anchor is re-checked against the real segments
# after generation (`evidence.verify`), so a fabricated one is dropped rather
# than shipped: an empty list is always a better answer than a guess.
_EVIDENCE_ARRAY = {
    "type": "array",
    "maxItems": MAX_EVIDENCE_PER_ITEM,
    "description": (
        "Up to 2 anchors backing this point, or an empty list. Each is a phrase "
        "copied VERBATIM from the transcript plus the timestamp of the turn it "
        "came from. Never paraphrase a quote and never invent a timestamp: an "
        "anchor that does not match the transcript is discarded."
    ),
    "items": {
        "type": "object",
        "properties": {
            "quote": {
                "type": "string",
                "description": "Verbatim transcript phrase, at most 15 words, in the transcript's own language.",
            },
            "t": {
                "type": ["number", "string"],
                "description": (
                    "The cited turn's timestamp: the `[mm:ss]` marker copied from "
                    "the start of that transcript line, or the same value in seconds."
                ),
            },
        },
        "required": ["quote", "t"],
        "additionalProperties": False,
    },
}


def _evidenced_section(description: str, **extra: Any) -> dict[str, Any]:
    """A string section in its model-facing `{text, evidence}` shape (FEAT10).

    `normalize_model_summary` flattens it back to `list[str]` plus the aligned
    `evidence` map before validation, so the stored schema is unchanged.
    """
    return {
        "type": "array",
        "description": description,
        "items": {
            "type": "object",
            "properties": {
                "text": {"type": "string", "description": "The point itself."},
                "evidence": _EVIDENCE_ARRAY,
            },
            "required": ["text", "evidence"],
            "additionalProperties": False,
        },
        **extra,
    }


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
            "summary": _evidenced_section(
                "≤5 bullets, ≤30 words each. Total under 150 words.",
                maxItems=5,
            ),
            "decisions": _evidenced_section(
                "Only include statements with explicit commitment language (will/agreed/decided/approved).",
            ),
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
                        "evidence": _EVIDENCE_ARRAY,
                    },
                    "required": ["task", "owner", "due", "confidence", "evidence"],
                    "additionalProperties": False,
                },
            },
            "questions": _evidenced_section(
                "Unresolved questions raised during the meeting.",
            ),
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
