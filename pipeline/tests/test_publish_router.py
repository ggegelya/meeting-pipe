"""Tests for the multi-sink publish router."""
from __future__ import annotations

from pathlib import Path
from typing import Any

import pytest

from mp.config import Config
from mp.publish_router import (
    PublisherBuildError,
    build_publishers,
    fanout,
)
from mp.schemas import ActionItem, MeetingSummary


def _summary() -> MeetingSummary:
    return MeetingSummary(
        title="Standup", summary=["a"], decisions=[], actions=[],
        questions=[], attendees=[], detected_language="en",
    )


class _RecordingPublisher:
    """In-memory MeetingPublisher for tests."""

    def __init__(self, name: str, *, fail: bool = False) -> None:
        self.name = name
        self.fail = fail
        self.calls: list[Path] = []

    def upsert(self, *, summary: MeetingSummary, transcript_md: Path | None,
                sidecar_path: Path) -> dict[str, Any]:
        self.calls.append(sidecar_path)
        if self.fail:
            raise RuntimeError(f"sink {self.name} blew up")
        return {"page_id": f"id-{self.name}", "page_url": f"u://{self.name}", "idempotent": False}


# ----- fanout -----

def _write_summary_json(path: Path) -> None:
    path.write_text(_summary().model_dump_json(), encoding="utf-8")


def test_fanout_runs_all_sinks_in_order(tmp_path: Path) -> None:
    cfg = Config()
    summary_json = tmp_path / "20260506-1500.summary.json"
    _write_summary_json(summary_json)
    pubs = [_RecordingPublisher("notion"),
            _RecordingPublisher("obsidian"),
            _RecordingPublisher("filesystem")]
    res = fanout(summary_json=summary_json, cfg=cfg, transcript_md=None,
                  publishers=pubs)
    assert list(res["sinks"].keys()) == ["notion", "obsidian", "filesystem"]
    # Sidecars per sink, named per protocol contract.
    assert pubs[0].calls[0].name == "20260506-1500.notion.json"
    assert pubs[1].calls[0].name == "20260506-1500.obsidian.json"
    assert pubs[2].calls[0].name == "20260506-1500.filesystem.json"
    # Top-level fields mirror the first sink's result for back-compat.
    assert res["page_id"] == "id-notion"
    assert res["failures"] == []


def test_fanout_continues_after_a_failing_sink(tmp_path: Path) -> None:
    cfg = Config()
    summary_json = tmp_path / "x.summary.json"
    _write_summary_json(summary_json)
    pubs = [_RecordingPublisher("notion", fail=True),
            _RecordingPublisher("obsidian"),
            _RecordingPublisher("filesystem")]
    res = fanout(summary_json=summary_json, cfg=cfg, transcript_md=None,
                  publishers=pubs)
    # Failing sink recorded as such.
    assert res["sinks"]["notion"].get("error_type") == "RuntimeError"
    assert res["sinks"]["obsidian"]["page_id"] == "id-obsidian"
    assert res["sinks"]["filesystem"]["page_id"] == "id-filesystem"
    assert res["failures"] == [("notion", "sink notion blew up")]


def test_fanout_empty_publisher_list_returns_local_only(tmp_path: Path) -> None:
    cfg = Config()
    summary_json = tmp_path / "x.summary.json"
    # No need to write a valid summary: the parse only happens when
    # there is at least one publisher to feed.
    summary_json.write_text("{}", encoding="utf-8")
    res = fanout(summary_json=summary_json, cfg=cfg, transcript_md=None,
                  publishers=[])
    assert res["page_id"] is None
    assert res["sinks"] == {}


# ----- build_publishers -----

def test_build_publishers_unknown_name_raises() -> None:
    # Unknown sink first so the error fires before any other sink's
    # construction reads env (e.g. notion requires NOTION_TOKEN). The
    # raise-on-unknown contract is what's under test, not env handling.
    cfg = Config.model_validate({"output": {"sinks": ["made-up"]}})
    with pytest.raises(PublisherBuildError):
        build_publishers(cfg)


def test_build_publishers_notion_in_regulated_mode_no_token_needed() -> None:
    # regulated_mode causes the Notion publisher to short-circuit at
    # upsert time, so build_publishers must not require NOTION_TOKEN
    # for regulated installs that use the Notion sink as a placeholder.
    cfg = Config.model_validate({
        "output": {"sinks": ["notion"]},
        "modes": {"regulated_mode": True},
    })
    pubs = build_publishers(cfg)
    assert len(pubs) == 1
    assert pubs[0].name == "notion"


def test_build_publishers_obsidian_without_vault_path_skips() -> None:
    cfg = Config.model_validate({
        "output": {"sinks": ["obsidian"]},
        "obsidian": {"vault_path": ""},
    })
    pubs = build_publishers(cfg)
    assert pubs == [], "missing vault_path should skip the sink rather than raise"


def test_build_publishers_obsidian_with_vault_path_constructs(tmp_path: Path) -> None:
    cfg = Config.model_validate({
        "output": {"sinks": ["obsidian"]},
        "obsidian": {"vault_path": str(tmp_path / "vault")},
    })
    pubs = build_publishers(cfg)
    assert len(pubs) == 1
    assert pubs[0].name == "obsidian"


def test_build_publishers_filesystem_constructs(tmp_path: Path) -> None:
    cfg = Config.model_validate({
        "output": {"sinks": ["filesystem"]},
        "filesystem": {"output_dir": str(tmp_path / "out")},
    })
    pubs = build_publishers(cfg)
    assert len(pubs) == 1
    assert pubs[0].name == "filesystem"


def test_default_output_sinks_is_notion_only() -> None:
    # Back-compat: existing installs see no behavioural change unless
    # they edit `output.sinks`.
    cfg = Config()
    assert cfg.output.sinks == ["notion"]
