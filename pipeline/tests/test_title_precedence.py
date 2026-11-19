"""PIPE55: the title every sink publishes, pinned against the cross-tree golden.

`Fixtures/title-precedence-golden.json` is read by Swift's `TitlePrecedenceTests`
(against `Meeting.displayTitle`) and here (against `apply_meeting_title` and the
router's fanout), so the Library and the sinks cannot disagree again.
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import pytest

from mp.config import Config
from mp.publish_notion import apply_meeting_title
from mp.publish_router import fanout
from mp.schemas import MeetingSummary

GOLDEN = (
    Path(__file__).resolve().parents[2]
    / "daemon" / "Tests" / "MeetingPipeTests" / "Fixtures" / "title-precedence-golden.json"
)


def _cases() -> list[dict]:
    return json.loads(GOLDEN.read_text(encoding="utf-8"))["cases"]


def _summary(title: str) -> MeetingSummary:
    # An empty title still loads (PIPE43 bounds model output, not stored files), which is
    # what the golden's empty-title rows need.
    return MeetingSummary(
        title=title, summary=["a"], decisions=[], actions=[], questions=[],
        attendees=[], detected_language="en",
    )


def _meta(case: dict) -> dict[str, Any]:
    return {k: case[k] for k in ("user_title", "meeting_title") if case[k] is not None}


@pytest.mark.parametrize("case", _cases(), ids=lambda c: c["name"])
def test_apply_meeting_title_matches_the_golden(case: dict, tmp_path: Path) -> None:
    summary_json = tmp_path / "20261118-1000.summary.json"
    meta = _meta(case)
    if meta:
        (tmp_path / "20261118-1000.meta.json").write_text(json.dumps(meta), encoding="utf-8")
    summary = _summary(case["summary_title"] or "")
    assert apply_meeting_title(summary, summary_json).title == (case["expected"] or "")


class _TitleSpy:
    name = "spy"

    def __init__(self) -> None:
        self.titles: list[str] = []

    def upsert(self, *, summary, transcript_md, sidecar_path, transcript_text=None) -> dict:
        self.titles.append(summary.title)
        return {"page_id": "x", "page_url": "u", "idempotent": False}


def test_fanout_hands_every_sink_the_user_title(tmp_path: Path) -> None:
    summary_json = tmp_path / "20261118-1000.summary.json"
    summary_json.write_text(_summary("Generated title").model_dump_json(), encoding="utf-8")
    (tmp_path / "20261118-1000.meta.json").write_text(
        json.dumps({"meeting_title": "Captured topic", "user_title": "My rename"}), encoding="utf-8")
    a, b = _TitleSpy(), _TitleSpy()
    fanout(summary_json=summary_json, cfg=Config(), transcript_md=None, publishers=[a, b])
    assert a.titles == b.titles == ["My rename"]


def test_fanout_without_user_title_is_unchanged_from_before(tmp_path: Path) -> None:
    summary_json = tmp_path / "20261118-1000.summary.json"
    summary_json.write_text(_summary("Generated title").model_dump_json(), encoding="utf-8")
    (tmp_path / "20261118-1000.meta.json").write_text(
        json.dumps({"meeting_title": "Captured topic"}), encoding="utf-8")
    spy = _TitleSpy()
    fanout(summary_json=summary_json, cfg=Config(), transcript_md=None, publishers=[spy])
    assert spy.titles == ["Captured topic"]


def test_user_title_is_cut_and_scrubbed_like_the_captured_one(tmp_path: Path) -> None:
    summary_json = tmp_path / "x.summary.json"
    (tmp_path / "x.meta.json").write_text(
        json.dumps({"user_title": "![hostile](http://evil.example/p.png) " + "a" * 200}), encoding="utf-8")
    out = apply_meeting_title(_summary("Generated"), summary_json).title
    assert len(out) <= 120 and "![" not in out and "](" not in out  # no live image or link survives
