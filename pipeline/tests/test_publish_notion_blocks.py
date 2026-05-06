"""Tests for the redesigned Notion block builders (P4.3).

The publish-side end-to-end is exercised by tests/test_publish_notion.py.
These cases pin the *shape* of each block so a reader of the resulting
page sees the deliberate layout the design pass is asking for.
"""
from __future__ import annotations

from pathlib import Path

from mp.publish_notion import (
    _action_block,
    _build_blocks,
    _callout,
    _numbered_with_bold_opener,
    _questions_toggle,
    _split_opening_clause,
)
from mp.schemas import ActionItem, MeetingSummary


def _summary(**overrides) -> MeetingSummary:
    base = dict(
        title="Sprint Planning",
        summary=["Reviewed Q3 milestones.", "Aligned on staffing."],
        decisions=["Ship: deploy beta on 2026-05-20.", "Owner. Alice will handle docs."],
        actions=[
            ActionItem(task="Send recap", owner="Alice", due="2026-05-07", confidence="high"),
            ActionItem(task="Reach out to design", owner=None, due=None, confidence="low"),
        ],
        questions=["Who owns the rollout?", "Stakeholder list final?"],
        attendees=["Alice", "Bob"],
        detected_language="en",
    )
    base.update(overrides)
    return MeetingSummary.model_validate(base)


# ----- callout -----

def test_summary_renders_as_callout_block() -> None:
    blocks = _build_blocks(_summary(), transcript_md=None, include_transcript=False)
    callouts = [b for b in blocks if b["type"] == "callout"]
    assert len(callouts) == 1
    assert callouts[0]["callout"]["icon"] == {"type": "emoji", "emoji": "🎯"}
    text = callouts[0]["callout"]["rich_text"][0]["text"]["content"]
    assert "Reviewed Q3 milestones." in text
    assert "Aligned on staffing." in text


def test_callout_has_blue_background() -> None:
    block = _callout("hi", emoji="x")
    assert block["callout"]["color"] == "blue_background"


# ----- numbered with bold opener -----

def test_numbered_decision_bolds_the_opener_at_colon() -> None:
    block = _numbered_with_bold_opener("Ship: deploy beta on 2026-05-20.")
    runs = block["numbered_list_item"]["rich_text"]
    assert len(runs) == 2
    assert runs[0]["text"]["content"] == "Ship:"
    assert runs[0]["annotations"]["bold"] is True
    assert runs[1]["text"]["content"] == " deploy beta on 2026-05-20."


def test_numbered_decision_bolds_the_opener_at_period() -> None:
    block = _numbered_with_bold_opener("Owner. Alice will handle docs.")
    runs = block["numbered_list_item"]["rich_text"]
    assert runs[0]["text"]["content"] == "Owner."
    assert runs[0]["annotations"]["bold"] is True


def test_numbered_decision_falls_back_to_plain_when_no_clause() -> None:
    long = "we never reach a delimiter so the whole thing is one bold span"
    block = _numbered_with_bold_opener(long)
    runs = block["numbered_list_item"]["rich_text"]
    assert len(runs) == 1
    assert runs[0]["text"]["content"] == long


def test_split_opening_clause_caps_at_60_chars() -> None:
    long_lede = "x" * 70 + ": tail"
    head, _ = _split_opening_clause(long_lede)
    # No delimiter found in first 60 -> no split, head is the whole text.
    assert head == long_lede


# ----- action block -----

def test_action_block_owner_pill_when_owner_set() -> None:
    block = _action_block(task="Send recap", owner="Alice",
                           due="2026-05-07", confidence="high")
    assert block["type"] == "to_do"
    runs = block["to_do"]["rich_text"]
    # First run is the owner pill.
    assert runs[0]["text"]["content"] == "@Alice"
    assert runs[0]["annotations"]["bold"] is True
    assert runs[0]["annotations"]["color"] == "blue"
    # Some run carries the task content.
    assert any(r["text"]["content"] == "Send recap" for r in runs)
    # Due-date run uses brown for the inline date chip.
    due_run = next(r for r in runs if "2026-05-07" in r["text"]["content"])
    assert due_run["annotations"]["color"] == "brown"
    # Confidence chip styled per level: "high" -> blue + bold.
    chip = next(r for r in runs if r["text"]["content"] == "[high]")
    assert chip["annotations"]["color"] == "blue"
    assert chip["annotations"]["bold"] is True


def test_action_block_unassigned_owner_pill_is_gray() -> None:
    block = _action_block(task="Send recap", owner=None,
                           due=None, confidence="low")
    runs = block["to_do"]["rich_text"]
    assert runs[0]["text"]["content"] == "@unassigned"
    assert runs[0]["annotations"]["color"] == "gray"
    chip = next(r for r in runs if r["text"]["content"] == "[low]")
    assert chip["annotations"]["color"] == "gray"
    # No bold for low-confidence chips: don't draw the eye to the
    # weakest signal.
    assert chip.get("annotations", {}).get("bold") is not True


# ----- questions toggle -----

def test_open_questions_render_inside_a_collapsed_toggle() -> None:
    blocks = _build_blocks(_summary(), transcript_md=None, include_transcript=False)
    toggles = [b for b in blocks if b["type"] == "toggle"]
    assert len(toggles) == 1, "questions section must collapse to a single toggle"
    summary_label = toggles[0]["toggle"]["rich_text"][0]["text"]["content"]
    assert summary_label == "2 unresolved"
    children = toggles[0]["toggle"]["children"]
    assert {c["bulleted_list_item"]["rich_text"][0]["text"]["content"] for c in children} == {
        "Who owns the rollout?", "Stakeholder list final?"
    }


def test_no_open_questions_means_no_toggle() -> None:
    blocks = _build_blocks(_summary(questions=[]), transcript_md=None, include_transcript=False)
    assert all(b["type"] != "toggle" for b in blocks)


# ----- end-to-end shape -----

def test_block_order_matches_design_pass() -> None:
    blocks = _build_blocks(_summary(), transcript_md=None, include_transcript=False)
    # Section order: Summary heading -> Summary callout -> Decisions
    # heading -> N numbered -> Action items heading -> N to-dos ->
    # Open Questions heading -> 1 toggle.
    types = [b["type"] for b in blocks]
    expected_prefix = [
        "heading_2", "callout",
        "heading_2", "numbered_list_item", "numbered_list_item",
        "heading_2", "to_do", "to_do",
        "heading_2", "toggle",
    ]
    assert types == expected_prefix
