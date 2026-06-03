"""Tests for the LAN sink (TECH-FEAT1)."""
from __future__ import annotations

import json
from pathlib import Path

import pytest

from mp.config import Config
from mp.publish_lan import LanPublisher, LanUnreachableError
from mp.publish_router import build_publishers
from mp.schemas import ActionItem, MeetingSummary


def _summary() -> MeetingSummary:
    return MeetingSummary(
        title="Standup",
        summary=["a"],
        decisions=[],
        actions=[ActionItem(task="Reply", owner="Bob", due=None, confidence="medium")],
        questions=[],
        attendees=["Bob"],
        detected_language="en",
    )


def test_writes_summary_actions_transcript(tmp_path: Path) -> None:
    transcript = tmp_path / "20260506-1500.md"
    transcript.write_text("# Transcript\nA: hi.\n", encoding="utf-8")
    sidecar = tmp_path / "20260506-1500.lan.json"
    share = tmp_path / "share"          # parent (tmp_path) exists + writable
    pub = LanPublisher(mount_path=share)
    res = pub.upsert(summary=_summary(), transcript_md=transcript, sidecar_path=sidecar)
    assert res["idempotent"] is False
    assert res["local"] is True
    assert (share / "20260506-1500.summary.md").exists()
    assert (share / "20260506-1500.actions.json").exists()
    assert (share / "20260506-1500.transcript.md").exists()
    actions = json.loads((share / "20260506-1500.actions.json").read_text(encoding="utf-8"))
    assert actions[0]["owner"] == "Bob"


def test_idempotent_on_repeat_call(tmp_path: Path) -> None:
    transcript = tmp_path / "x.md"
    transcript.write_text("hi", encoding="utf-8")
    sidecar = tmp_path / "x.lan.json"
    share = tmp_path / "share"
    pub = LanPublisher(mount_path=share)
    pub.upsert(summary=_summary(), transcript_md=transcript, sidecar_path=sidecar)
    summary_path = share / "x.summary.md"
    mtime = summary_path.stat().st_mtime_ns
    res = pub.upsert(summary=_summary(), transcript_md=transcript, sidecar_path=sidecar)
    assert res["idempotent"] is True
    assert summary_path.stat().st_mtime_ns == mtime


def test_unreachable_share_raises(tmp_path: Path) -> None:
    # Parent of the target does not exist -> the share is treated as not mounted,
    # and we refuse rather than create a local tree the user would never find.
    sidecar = tmp_path / "x.lan.json"
    missing = tmp_path / "not_mounted" / "meetings"
    pub = LanPublisher(mount_path=missing, host="nas.local")
    with pytest.raises(LanUnreachableError):
        pub.upsert(summary=_summary(), transcript_md=None, sidecar_path=sidecar)
    assert not missing.exists()         # nothing was created locally


def test_atomic_write_leaves_no_temp_files(tmp_path: Path) -> None:
    transcript = tmp_path / "y.md"
    transcript.write_text("hi", encoding="utf-8")
    sidecar = tmp_path / "y.lan.json"
    share = tmp_path / "share"
    pub = LanPublisher(mount_path=share)
    pub.upsert(summary=_summary(), transcript_md=transcript, sidecar_path=sidecar)
    leftovers = [p.name for p in share.iterdir() if ".tmp-" in p.name]
    assert leftovers == []


def test_router_builds_lan_publisher(tmp_path: Path) -> None:
    cfg = Config.model_validate({
        "lan": {"mount_path": str(tmp_path / "share")},
        "output": {"sinks": ["lan"]},
    })
    pubs = build_publishers(cfg)
    assert len(pubs) == 1
    assert pubs[0].name == "lan"


def test_lan_survives_regulated_mode(tmp_path: Path) -> None:
    # On-prem, no cloud egress: regulated mode clamps only the Notion sink, so
    # a LAN + Notion config keeps LAN.
    cfg = Config.model_validate({
        "lan": {"mount_path": str(tmp_path / "share")},
        "output": {"sinks": ["notion", "lan"]},
        "modes": {"regulated_mode": True},
    })
    pubs = build_publishers(cfg)
    names = [p.name for p in pubs]
    assert names == ["lan"]
