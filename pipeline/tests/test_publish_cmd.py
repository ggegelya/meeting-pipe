"""Tests for `mp publish <summary.json>` (TECH-SUM1-APPLE publish hand-off)."""
from __future__ import annotations

import json
from pathlib import Path
from unittest.mock import patch

import pytest
from pydantic import ValidationError

from mp.publish_cmd import main
from mp.publish_router import EXIT_PUBLISH_FAILED

_SUMMARY = (
    '{"title":"T","summary":["s"],"decisions":[],"actions":[],'
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


# --------------------------------------------------------------------------
# PIPE54: a summary the schema rejects is a publish-stage failure naming the field
# --------------------------------------------------------------------------


class _RecordingSink:
    name = "filesystem"

    def __init__(self) -> None:
        self.calls = 0

    def upsert(self, **_kw):
        self.calls += 1
        return {"page_url": None}


def _summary_with(**over) -> str:
    base = json.loads(_SUMMARY)
    base.update(over)
    return json.dumps(base)


def test_an_over_limit_summary_exits_3_names_the_limit_and_runs_no_sink(tmp_path: Path, capsys) -> None:
    summary = tmp_path / "20260516-0900.summary.json"
    summary.write_text(_summary_with(summary=[f"b{i}" for i in range(11)]), encoding="utf-8")
    sink = _RecordingSink()

    with patch("mp.publish_cmd.build_publishers", return_value=[sink]):
        rc = main([str(summary)])

    assert rc == EXIT_PUBLISH_FAILED
    assert sink.calls == 0
    err = capsys.readouterr().err
    assert "[FAIL] The summary has 11 bullets; the limit is 10. Edit the summary, then Republish." in err
    sidecar = json.loads((tmp_path / "20260516-0900.publish.json").read_text(encoding="utf-8"))
    assert sidecar["state"] == "none"
    assert sidecar["sinks"]["filesystem"]["ok"] is False
    assert "the limit is 10" in sidecar["sinks"]["filesystem"]["error"]


def test_an_over_long_title_and_an_off_enum_confidence_are_named(tmp_path: Path, capsys) -> None:
    summary = tmp_path / "20260516-0900.summary.json"
    summary.write_text(_summary_with(title="t" * 130), encoding="utf-8")
    with patch("mp.publish_cmd.build_publishers", return_value=[_RecordingSink()]):
        assert main([str(summary)]) == EXIT_PUBLISH_FAILED
    assert "The title is 130 characters; the limit is 120." in capsys.readouterr().err

    summary.write_text(_summary_with(actions=[{"task": "x", "confidence": "Very high"}]), encoding="utf-8")
    with patch("mp.publish_cmd.build_publishers", return_value=[_RecordingSink()]):
        assert main([str(summary)]) == EXIT_PUBLISH_FAILED
    err = capsys.readouterr().err
    assert "Action 1's confidence must be low, medium or high." in err
    assert "Very high" not in err  # summary content stays out of the failure line


def test_a_file_that_is_not_json_stays_an_ordinary_failure(tmp_path: Path) -> None:
    # Not a shape problem, so not reclassified: Retry may regenerate a corrupt file.
    summary = tmp_path / "20260516-0900.summary.json"
    summary.write_text("{not json", encoding="utf-8")
    with patch("mp.publish_cmd.build_publishers", return_value=[_RecordingSink()]):
        with pytest.raises(ValidationError):
            main([str(summary)])


def test_a_valid_summary_still_publishes(tmp_path: Path) -> None:
    summary = tmp_path / "20260516-0900.summary.json"
    summary.write_text(_SUMMARY, encoding="utf-8")
    sink = _RecordingSink()
    with patch("mp.publish_cmd.build_publishers", return_value=[sink]):
        assert main([str(summary)]) == 0
    assert sink.calls == 1


def test_an_unreadable_overlay_exits_3_names_the_file_and_runs_no_sink(tmp_path: Path, caplog) -> None:
    # PIPE51 amendment: `mp publish` (Republish, a publish-stage Retry) refuses the way summarize
    # does, as a publish-stage outcome so Retry republishes rather than re-summarizes.
    summary = tmp_path / "20260516-0900.summary.json"
    summary.write_text(_SUMMARY, encoding="utf-8")
    (tmp_path / "20260516-0900.md").write_text("# Transcript\n", encoding="utf-8")
    (tmp_path / "20260516-0900.speaker_labels.json").write_text("{not json", encoding="utf-8")
    sink = _RecordingSink()

    with patch("mp.publish_cmd.build_publishers", return_value=[sink]):
        assert main([str(summary)]) == EXIT_PUBLISH_FAILED

    assert sink.calls == 0
    lines = [r.getMessage() for r in caplog.records if "file can't be read" in r.getMessage()]
    assert lines and "This meeting's speaker names file can't be read" in lines[0]
    assert "fix or remove 20260516-0900.speaker_labels.json" in lines[0]
    sidecar = json.loads((tmp_path / "20260516-0900.publish.json").read_text(encoding="utf-8"))
    assert sidecar["state"] == "none"
