"""WF7: per-workflow summary sections, across the schema, overlay, prompt,
publishers, and the BYO paste round-trip."""
from __future__ import annotations

import json
from pathlib import Path

from mp.config import Config, ExtraSectionSpec
from mp.markdown import render_summary_md
from mp.publish_from_paste import parse_summary_md
from mp.publish_notion import _build_blocks
from mp.publish_obsidian import ObsidianPublisher
from mp.schemas import SUMMARY_TOOL, ExtraSection, MeetingSummary
from mp.summarize import _extra_sections_directive, _load_system_prompt
from mp.workflow import apply_overrides


def _summary(**over) -> MeetingSummary:
    base = dict(
        title="Sync", summary=["a"], decisions=[], actions=[],
        questions=[], attendees=[], detected_language="en",
    )
    base.update(over)
    return MeetingSummary(**base)


# --- schema: tolerant + optional ------------------------------------------

def test_meeting_summary_defaults_extra_sections_empty():
    assert _summary().extra_sections == []


def test_legacy_summary_json_without_extra_sections_still_loads():
    legacy = json.dumps({
        "title": "Old", "summary": ["x"], "decisions": [], "actions": [],
        "questions": [], "attendees": [], "detected_language": "en",
    })
    s = MeetingSummary.model_validate_json(legacy)
    assert s.extra_sections == []


def test_summary_tool_has_optional_extra_sections():
    props = SUMMARY_TOOL["input_schema"]["properties"]
    assert "extra_sections" in props
    # Not required: a backend that fills nothing still validates.
    assert "extra_sections" not in SUMMARY_TOOL["input_schema"]["required"]


# --- overlay: workflow_extra_sections -> cfg ------------------------------

def test_overlay_reads_extra_sections_from_sidecar(tmp_path: Path):
    (tmp_path / "m.meta.json").write_text(json.dumps({
        "workflow_id": "wf1",
        "workflow_extra_sections": [
            {"name": "Feedback", "instruction": "Note feedback given or received."},
            {"name": "  ", "instruction": "dropped: no name"},
            {"name": "Blank", "instruction": ""},
        ],
    }), encoding="utf-8")
    out = apply_overrides(Config(), tmp_path / "m.wav")
    specs = out.summarization.extra_sections
    assert [s.name for s in specs] == ["Feedback"]
    assert specs[0].instruction == "Note feedback given or received."


def test_overlay_no_sections_leaves_default_empty(tmp_path: Path):
    (tmp_path / "m.meta.json").write_text(
        json.dumps({"workflow_id": "wf1"}), encoding="utf-8")
    out = apply_overrides(Config(), tmp_path / "m.wav")
    assert out.summarization.extra_sections == []


# --- prompt directive ------------------------------------------------------

def test_directive_empty_tells_model_to_leave_empty():
    assert "leave" in _extra_sections_directive([]).lower()


def test_directive_lists_requested_sections():
    specs = [ExtraSectionSpec(name="Billable follow-ups", instruction="List billable items.")]
    d = _extra_sections_directive(specs)
    assert "Billable follow-ups" in d
    assert "List billable items." in d


def test_system_prompt_injects_the_directive():
    specs = [ExtraSectionSpec(name="Risks", instruction="Call out risks.")]
    prompt = _load_system_prompt("ctx", "auto", extra_sections=specs)
    assert "Risks" in prompt
    assert "Call out risks." in prompt


# --- rendering: every publisher -------------------------------------------

def test_render_summary_md_renders_extra_sections():
    s = _summary(extra_sections=[ExtraSection(name="Risks", content=["late API", "no owner"])])
    md = render_summary_md(s)
    assert "## Risks" in md
    assert "- late API" in md


def test_render_summary_md_skips_empty_extra_section():
    s = _summary(extra_sections=[ExtraSection(name="Empty", content=[])])
    assert "## Empty" not in render_summary_md(s)


def test_notion_blocks_include_extra_sections():
    s = _summary(extra_sections=[ExtraSection(name="Risks", content=["late API"])])
    blocks = _build_blocks(s, transcript_md=None, include_transcript=False)
    texts = json.dumps(blocks)
    assert "Risks" in texts
    assert "late API" in texts


def test_obsidian_note_includes_extra_sections(tmp_path: Path):
    pub = ObsidianPublisher(vault_path=tmp_path)
    s = _summary(extra_sections=[ExtraSection(name="Billable follow-ups", content=["invoice Acme"])])
    note = pub._render_note(s, transcript_md=None, date="2026-07-12", generated="2026-07-12")
    assert "## Billable follow-ups" in note
    assert "- invoice Acme" in note


# --- BYO paste round-trip --------------------------------------------------

def test_paste_captures_unknown_h2_as_extra_section():
    md = (
        "# My meeting\n\n"
        "## Summary\n\n- did things\n\n"
        "## Billable follow-ups\n\n- invoice Acme\n- send SOW\n\n"
        "## Open Questions\n\n- when to ship?\n"
    )
    parsed = parse_summary_md(md)
    assert [s.name for s in parsed.extra_sections] == ["Billable follow-ups"]
    assert parsed.extra_sections[0].content == ["invoice Acme", "send SOW"]
    # Standard sections are NOT duplicated into extra_sections.
    assert parsed.summary == ["did things"]
    assert parsed.questions == ["when to ship?"]
