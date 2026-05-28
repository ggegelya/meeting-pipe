"""Tests for `mp publish <summary.json>` (TECH-SUM1-APPLE publish hand-off)."""
from __future__ import annotations

from pathlib import Path
from unittest.mock import patch

from mp.publish_cmd import main

_SUMMARY = (
    '{"title":"T","summary":[],"decisions":[],"actions":[],'
    '"questions":[],"attendees":[],"detected_language":"en"}'
)


def test_publish_runs_fanout_with_transcript(tmp_path: Path) -> None:
    summary = tmp_path / "20260516-0900.summary.json"
    summary.write_text(_SUMMARY, encoding="utf-8")
    md = tmp_path / "20260516-0900.md"
    md.write_text("# transcript", encoding="utf-8")

    captured: dict = {}

    def fake_fanout(*, summary_json, cfg, transcript_md, publishers=None):
        captured["summary_json"] = summary_json
        captured["transcript_md"] = transcript_md
        return {"page_url": "https://notion/x", "failures": []}

    with patch("mp.publish_cmd.fanout", side_effect=fake_fanout):
        rc = main([str(summary)])

    assert rc == 0
    assert captured["summary_json"].name == "20260516-0900.summary.json"
    assert captured["transcript_md"].name == "20260516-0900.md"


def test_publish_passes_none_when_transcript_missing(tmp_path: Path) -> None:
    summary = tmp_path / "20260516-0900.summary.json"
    summary.write_text(_SUMMARY, encoding="utf-8")

    captured: dict = {}

    def fake_fanout(*, summary_json, cfg, transcript_md, publishers=None):
        captured["transcript_md"] = transcript_md
        return {"page_url": None, "failures": []}

    with patch("mp.publish_cmd.fanout", side_effect=fake_fanout):
        rc = main([str(summary)])

    assert rc == 0
    assert captured["transcript_md"] is None


def test_publish_missing_file_returns_1(tmp_path: Path) -> None:
    assert main([str(tmp_path / "nope.summary.json")]) == 1


def test_publish_no_args_returns_2() -> None:
    assert main([]) == 2
