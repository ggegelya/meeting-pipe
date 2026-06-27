"""Tests for FilesystemPublisher."""
from __future__ import annotations

import json
from pathlib import Path

from mp.publish_fs import FilesystemPublisher
from mp.schemas import ActionItem, MeetingSummary


def _summary() -> MeetingSummary:
    return MeetingSummary(
        title="Standup",
        summary=["a"],
        decisions=[],
        actions=[
            ActionItem(task="Reply to email", owner="Bob", due=None, confidence="medium"),
        ],
        questions=[],
        attendees=["Bob"],
        detected_language="en",
    )


def test_writes_summary_actions_transcript(tmp_path: Path) -> None:
    transcript = tmp_path / "20260506-1500.md"
    transcript.write_text("# Transcript\nA: hi.\n", encoding="utf-8")
    sidecar = tmp_path / "20260506-1500.filesystem.json"
    out = tmp_path / "out"
    pub = FilesystemPublisher(output_dir=out)
    res = pub.upsert(summary=_summary(), transcript_md=transcript, sidecar_path=sidecar)
    assert res["idempotent"] is False
    assert res["local"] is True
    assert (out / "20260506-1500.summary.md").exists()
    assert (out / "20260506-1500.actions.json").exists()
    assert (out / "20260506-1500.transcript.md").exists()
    actions = json.loads((out / "20260506-1500.actions.json").read_text(encoding="utf-8"))
    assert actions[0]["owner"] == "Bob"


def test_idempotent_on_repeat_call(tmp_path: Path) -> None:
    transcript = tmp_path / "x.md"
    transcript.write_text("hi", encoding="utf-8")
    sidecar = tmp_path / "x.filesystem.json"
    out = tmp_path / "out"
    pub = FilesystemPublisher(output_dir=out)
    pub.upsert(summary=_summary(), transcript_md=transcript, sidecar_path=sidecar)
    summary_path = out / "x.summary.md"
    mtime = summary_path.stat().st_mtime_ns
    res = pub.upsert(summary=_summary(), transcript_md=transcript, sidecar_path=sidecar)
    assert res["idempotent"] is True
    assert summary_path.stat().st_mtime_ns == mtime


def test_skips_transcript_when_missing(tmp_path: Path) -> None:
    sidecar = tmp_path / "y.filesystem.json"
    out = tmp_path / "out"
    pub = FilesystemPublisher(output_dir=out)
    res = pub.upsert(summary=_summary(), transcript_md=None, sidecar_path=sidecar)
    # No transcript_md was provided; the summary still writes, no
    # transcript file appears. Idempotency depends only on what got
    # written.
    assert res["idempotent"] is False
    files = sorted(p.name for p in out.iterdir())
    assert all(not f.endswith(".transcript.md") for f in files)


def test_overwrite_when_summary_changes(tmp_path: Path) -> None:
    transcript = tmp_path / "z.md"
    transcript.write_text("hi", encoding="utf-8")
    sidecar = tmp_path / "z.filesystem.json"
    out = tmp_path / "out"
    pub = FilesystemPublisher(output_dir=out)
    pub.upsert(summary=_summary(), transcript_md=transcript, sidecar_path=sidecar)
    changed = _summary().model_copy(update={"title": "New title"})
    res = pub.upsert(summary=changed, transcript_md=transcript, sidecar_path=sidecar)
    assert res["idempotent"] is False
    body = (out / "z.summary.md").read_text(encoding="utf-8")
    assert "New title" in body


def test_actions_dumped_as_array(tmp_path: Path) -> None:
    transcript = tmp_path / "a.md"
    transcript.write_text("", encoding="utf-8")
    sidecar = tmp_path / "a.filesystem.json"
    out = tmp_path / "out"
    summary = _summary().model_copy(update={"actions": [
        ActionItem(task="One", owner="A", due="2026-05-10", confidence="high"),
        ActionItem(task="Two", owner=None, due=None, confidence="low"),
    ]})
    pub = FilesystemPublisher(output_dir=out)
    pub.upsert(summary=summary, transcript_md=transcript, sidecar_path=sidecar)
    actions = json.loads((out / "a.actions.json").read_text(encoding="utf-8"))
    assert len(actions) == 2
    assert actions[0]["task"] == "One"
    assert actions[1]["owner"] is None


def test_resolved_flag_round_trips_to_actions_json_and_markdown(tmp_path: Path) -> None:
    # AI1: a resolved action lands in actions.json with resolved=true and
    # renders the markdown checkbox ticked; an open one stays unchecked.
    transcript = tmp_path / "b.md"
    transcript.write_text("", encoding="utf-8")
    sidecar = tmp_path / "b.filesystem.json"
    out = tmp_path / "out"
    summary = _summary().model_copy(update={"actions": [
        ActionItem(task="Wrapped", owner="A", due=None, confidence="high", resolved=True),
        ActionItem(task="Pending", owner="B", due=None, confidence="high"),
    ]})
    FilesystemPublisher(output_dir=out).upsert(
        summary=summary, transcript_md=transcript, sidecar_path=sidecar
    )
    actions = json.loads((out / "b.actions.json").read_text(encoding="utf-8"))
    by_task = {a["task"]: a for a in actions}
    assert by_task["Wrapped"]["resolved"] is True
    assert by_task["Pending"]["resolved"] is False
    body = (out / "b.summary.md").read_text(encoding="utf-8")
    assert "- [x] **A**: Wrapped" in body
    assert "- [ ] **B**: Pending" in body
