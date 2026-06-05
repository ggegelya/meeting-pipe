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
    publish_state,
)
from mp.schemas import MeetingSummary


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


def test_build_publishers_notion_in_regulated_mode_is_dropped() -> None:
    # regulated_mode is a hard zero-egress guarantee. Notion is the one sink
    # that transmits off-device, so build_publishers must DROP it entirely
    # rather than build a token-less placeholder that would still POST to
    # api.notion.com at upsert time (TECH-SEC2).
    cfg = Config.model_validate({
        "output": {"sinks": ["notion"]},
        "modes": {"regulated_mode": True},
    })
    pubs = build_publishers(cfg)
    assert pubs == [], "notion sink must be dropped under regulated_mode"


def test_build_publishers_regulated_drops_notion_keeps_local_sinks(tmp_path: Path) -> None:
    # The clamp is surgical: only the egressing sink (notion) is dropped; the
    # local-only sinks (obsidian, filesystem) still build and run.
    cfg = Config.model_validate({
        "output": {"sinks": ["notion", "obsidian", "filesystem"]},
        "obsidian": {"vault_path": str(tmp_path / "vault")},
        "filesystem": {"output_dir": str(tmp_path / "out")},
        "modes": {"regulated_mode": True},
    })
    pubs = build_publishers(cfg)
    assert [p.name for p in pubs] == ["obsidian", "filesystem"]


def test_build_publishers_workflow_nda_mode_drops_notion(tmp_path: Path) -> None:
    # The egress clamp now lives in config.effective_sinks (TECH-ARCH1) and
    # fires under workflow_nda_mode too, not only regulated_mode. Before this,
    # _build_one checked regulated_mode alone; NDA reached the same outcome
    # only because the workflow overlay rewrote sinks upstream. Routing through
    # effective_sinks makes the clamp robust at the build site itself.
    cfg = Config.model_validate({
        "output": {"sinks": ["notion", "filesystem"]},
        "filesystem": {"output_dir": str(tmp_path / "out")},
        "modes": {"workflow_nda_mode": True},
    })
    pubs = build_publishers(cfg)
    assert [p.name for p in pubs] == ["filesystem"]


def test_fanout_regulated_mode_issues_no_request(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    # End-to-end zero-egress: driving fanout under regulated_mode with the
    # default notion sink must not issue any request at all. We arm httpx's
    # transport to fail on every request, then assert fanout completes with
    # an empty sink map (notion dropped at build time). A regression that
    # rebuilt the token-less Notion publisher would POST to api.notion.com
    # and trip the transport. (TECH-SEC2)
    import httpx

    def _blocking_handle(self: httpx.HTTPTransport, request: httpx.Request) -> httpx.Response:  # noqa: ARG001
        raise AssertionError(f"unexpected egress under regulated_mode: {request.url}")

    monkeypatch.setattr(httpx.HTTPTransport, "handle_request", _blocking_handle)

    cfg = Config.model_validate({
        "output": {"sinks": ["notion"]},
        "modes": {"regulated_mode": True},
    })
    summary_json = tmp_path / "20260506-1500.summary.json"
    _write_summary_json(summary_json)
    res = fanout(summary_json=summary_json, cfg=cfg, transcript_md=None)
    assert res["sinks"] == {}, "notion must be dropped, leaving no sinks to run"


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


def test_publish_state_classifies_fanout_result() -> None:
    # TECH-I6: full when all sinks succeed, partial when mixed, none when all
    # fail or nothing ran.
    assert publish_state({"sinks": {}}) == "none"
    assert publish_state({}) == "none"
    assert publish_state(
        {"sinks": {"notion": {"page_id": "x"}, "filesystem": {"ok": True}}}
    ) == "full"
    assert publish_state(
        {"sinks": {"notion": {"error": "boom"}, "filesystem": {"ok": True}}}
    ) == "partial"
    assert publish_state({"sinks": {"notion": {"error": "boom"}}}) == "none"
