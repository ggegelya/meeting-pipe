"""Tests for `mp publish <summary.json>` (TECH-SUM1-APPLE publish hand-off)."""
from __future__ import annotations

from pathlib import Path
from unittest.mock import patch

from mp.publish_cmd import main
from mp.publish_router import EXIT_PUBLISH_FAILED

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


# ----- PIPE1: an all-sinks-failed publish must not exit 0 -----


def test_publish_exits_publish_failed_when_every_sink_failed(tmp_path: Path) -> None:
    """AUD-30: the Apple Intelligence completion path runs `mp publish` directly and
    reads the page-URL sidecar on a zero exit, so a silent success here announced a
    meeting that never landed anywhere."""
    summary = tmp_path / "20260516-0900.summary.json"
    summary.write_text(_SUMMARY, encoding="utf-8")

    def fake_fanout(*, summary_json, cfg, transcript_md, publishers=None):
        return {
            "page_url": None,
            "sinks": {"notion": {"error": "503 from api.notion.com"}},
            "failures": [("notion", "503 from api.notion.com")],
        }

    with patch("mp.publish_cmd.fanout", side_effect=fake_fanout):
        rc = main([str(summary)])

    assert rc == EXIT_PUBLISH_FAILED


def test_publish_exits_zero_on_a_partial_publish(tmp_path: Path) -> None:
    """One sink surviving means the summary reached the user somewhere. The Library
    badges it partial (TECH-I6); the run is not a failure."""
    summary = tmp_path / "20260516-0900.summary.json"
    summary.write_text(_SUMMARY, encoding="utf-8")

    def fake_fanout(*, summary_json, cfg, transcript_md, publishers=None):
        return {
            "page_url": None,
            "sinks": {"notion": {"error": "boom"}, "obsidian": {"idempotent": False}},
            "failures": [("notion", "boom")],
        }

    with patch("mp.publish_cmd.fanout", side_effect=fake_fanout):
        rc = main([str(summary)])

    assert rc == 0


def test_publish_exits_zero_when_no_sink_was_configured(tmp_path: Path) -> None:
    """A regulated run whose only configured sink was Notion publishes nothing and
    fails at nothing."""
    summary = tmp_path / "20260516-0900.summary.json"
    summary.write_text(_SUMMARY, encoding="utf-8")

    def fake_fanout(*, summary_json, cfg, transcript_md, publishers=None):
        return {"page_url": None, "sinks": {}, "failures": [], "regulated": True}

    with patch("mp.publish_cmd.fanout", side_effect=fake_fanout):
        rc = main([str(summary)])

    assert rc == 0
