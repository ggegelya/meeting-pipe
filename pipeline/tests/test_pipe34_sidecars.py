"""PIPE34: a failed write of the run or publish sidecar never leaves the previous run's file
looking like this run's outcome, and a leftover Apple handoff sentinel never hijacks a later run."""
from __future__ import annotations

import errno
import json
import os
from pathlib import Path
from typing import Any
from unittest.mock import patch

import pytest

from mp import corrections, publish_cmd, publish_router, storage, summarize
from mp.config import Config
from mp.orchestrate import run_all
from mp.publish_router import EXIT_PUBLISH_FAILED, fanout, publish_failed
from mp.schemas import MeetingSummary

from .test_orchestrate import _write_fluidaudio_sidecar

STEM = "20260516-0900"


@pytest.fixture
def emitted(monkeypatch) -> list[tuple[str, str, dict[str, Any]]]:
    rows: list[tuple[str, str, dict[str, Any]]] = []
    monkeypatch.setattr("mp.corrections.events.emit",
                        lambda cat, action, **attrs: rows.append((cat, action, attrs)))
    return rows


def _refuse_replace_of(name_suffix: str):
    """`os.replace` that fails for one target suffix and works for everything else."""
    real = os.replace

    def fake(src, dst, *a, **k):
        if str(dst).endswith(name_suffix):
            raise OSError(errno.ENOSPC, "No space left on device")
        return real(src, dst, *a, **k)
    return fake


def _no_temps(directory: Path) -> list[str]:
    return [p.name for p in directory.iterdir() if storage.TEMP_MARK in p.name]


# ---------- run sidecar ----------------------------------------------------------------


def _old_run_sidecar(tmp_path: Path) -> Path:
    path = tmp_path / f"{STEM}.run.json"
    path.write_text(json.dumps({"backend": "local", "model": "old", "ts": "2026-01-01T00:00:00Z"}))
    return path


def test_a_failed_run_sidecar_write_leaves_no_run_json(tmp_path: Path, emitted) -> None:
    old = _old_run_sidecar(tmp_path)
    with patch("mp.storage.os.replace", _refuse_replace_of(".run.json")), pytest.raises(OSError):
        corrections.write_run_sidecar(
            recordings_dir=tmp_path, stem=STEM, transcript_path=tmp_path / f"{STEM}.md",
            transcript_chars=10, summary_json_path=tmp_path / f"{STEM}.summary.json",
            backend="anthropic", model="new",
        )
    assert not old.exists(), "the previous run's engine must not stay on disk as this run's"
    assert _no_temps(tmp_path) == []
    row = next(attrs for _, action, attrs in emitted if action == "sidecar_write_failed")
    assert row == {"file": "run", "error": "OSError", "errno": errno.ENOSPC}


def test_a_failed_rewrite_after_a_re_summarize_leaves_no_old_backend(tmp_path: Path, emitted) -> None:
    _old_run_sidecar(tmp_path)
    md = tmp_path / f"{STEM}.md"
    md.write_text("# t\n", encoding="utf-8")
    out = {"json": tmp_path / f"{STEM}.summary.json", "md": tmp_path / f"{STEM}.summary.md",
           "backend": "anthropic", "model": "claude", "adapter_path": ""}
    with patch("mp.storage.os.replace", _refuse_replace_of(".run.json")):
        summarize.rewrite_run_sidecar(md, out)  # type: ignore[arg-type]  # non-fatal by design
    assert not (tmp_path / f"{STEM}.run.json").exists()
    assert _no_temps(tmp_path) == []
    assert any(action == "sidecar_write_failed" for _, action, _ in emitted)


def test_set_publish_state_warns_on_a_present_unreadable_sidecar(tmp_path: Path, caplog) -> None:
    sidecar = tmp_path / f"{STEM}.run.json"
    sidecar.write_text("{not json")
    corrections.set_publish_state(sidecar, "full")
    assert "present but unreadable" in caplog.text
    corrections.set_publish_state(tmp_path / "absent.run.json", "full")  # missing stays silent


def test_run_all_still_succeeds_when_the_run_sidecar_cannot_be_written(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.delenv("MP_FORCE_BYO", raising=False)
    wav = tmp_path / f"{STEM}.wav"
    wav.write_bytes(b"")
    _write_fluidaudio_sidecar(tmp_path, stem=STEM)
    old = _old_run_sidecar(tmp_path)
    summary_json = tmp_path / f"{STEM}.summary.json"
    summary_json.write_text("{}", encoding="utf-8")
    pub = {"page_id": None, "page_url": None, "sinks": {}, "failures": [], "no_sinks_configured": True}
    with patch("mp.orchestrate.summarize",
               return_value={"json": summary_json, "md": tmp_path / f"{STEM}.summary.md",
                             "backend": "anthropic", "model": "new"}), \
         patch("mp.orchestrate.publish_fanout", return_value=pub), \
         patch("mp.storage.os.replace", _refuse_replace_of(".run.json")):
        result = run_all(wav, cfg=Config())
    assert "publish_failed" not in result
    assert summary_json.exists()
    assert not old.exists()


# ---------- publish sidecar ------------------------------------------------------------


def _summary_json(tmp_path: Path) -> Path:
    path = tmp_path / f"{STEM}.summary.json"
    path.write_text(MeetingSummary(
        title="Standup", summary=["a"], decisions=[], actions=[], questions=[], attendees=[],
        detected_language="en",
    ).model_dump_json(), encoding="utf-8")
    return path


def _old_publish_sidecar(tmp_path: Path) -> Path:
    path = tmp_path / f"{STEM}.publish.json"
    path.write_text(json.dumps({"schema_version": 1, "state": "full", "page_url": "u://old",
                                "ts": "2026-01-01T00:00:00+00:00", "sinks": {}}))
    return path


class _Sink:
    def __init__(self, name: str, seen: list[dict[str, Any]], sidecar: Path) -> None:
        self.name = name
        self.seen = seen
        self.sidecar = sidecar

    def upsert(self, *, summary, transcript_md, sidecar_path, transcript_text=None) -> dict[str, Any]:
        self.seen.append(json.loads(self.sidecar.read_text()))
        return {"page_id": "id", "page_url": f"u://{self.name}"}


def test_the_pending_marker_is_on_disk_while_a_sink_runs(tmp_path: Path) -> None:
    summary_json = _summary_json(tmp_path)
    sidecar = _old_publish_sidecar(tmp_path)
    seen: list[dict[str, Any]] = []
    res = fanout(summary_json=summary_json, cfg=Config(), transcript_md=None,
                 publishers=[_Sink("notion", seen, sidecar)])
    assert seen[0]["state"] == "unknown"
    assert seen[0]["page_url"] is None
    assert set(seen[0]) == {"schema_version", "state", "page_url", "ts", "sinks"}
    assert json.loads(sidecar.read_text())["state"] == "full"
    assert not publish_failed(res)


def test_a_failed_final_write_leaves_the_marker_and_fails_the_publish(tmp_path: Path, emitted) -> None:
    summary_json = _summary_json(tmp_path)
    sidecar = _old_publish_sidecar(tmp_path)
    real = storage.atomic_write_text
    calls = {"n": 0}

    def second_write_fails(path, text, **kw):
        if str(path).endswith(".publish.json"):
            calls["n"] += 1
            if calls["n"] == 2:
                raise OSError(errno.EIO, "Input/output error")
        return real(path, text, **kw)

    with patch("mp.publish_router.storage.atomic_write_text", second_write_fails):
        res = fanout(summary_json=summary_json, cfg=Config(), transcript_md=None,
                     publishers=[_Sink("notion", [], sidecar)])
    on_disk = json.loads(sidecar.read_text())
    assert on_disk["state"] == "unknown", "the marker, never the previous run's outcome"
    assert on_disk["page_url"] is None
    assert res["sidecar_write_failed"] is True
    assert publish_failed(res)
    assert "could not be recorded" in publish_router.publish_failure_reason(res)
    assert any(a == "sidecar_write_failed" and attrs["file"] == "publish" for _, a, attrs in emitted)


def test_mp_publish_exits_3_when_the_outcome_cannot_be_recorded(tmp_path: Path, monkeypatch) -> None:
    summary_json = _summary_json(tmp_path)
    landed = {"page_id": "id", "page_url": "u://notion", "sinks": {"notion": {"page_url": "u://notion"}},
              "failures": [], "sidecar_write_failed": True}
    monkeypatch.setattr(publish_cmd, "fanout", lambda **_: landed)
    monkeypatch.setattr(publish_cmd.entry, "prepare", lambda **_: Config())
    assert publish_cmd.main([str(summary_json)]) == EXIT_PUBLISH_FAILED


def test_a_marker_that_cannot_be_written_or_unlinked_aborts_before_any_sink(tmp_path: Path) -> None:
    summary_json = _summary_json(tmp_path)
    _old_publish_sidecar(tmp_path)
    seen: list[dict[str, Any]] = []

    def refuse(*_a, **_k):
        raise OSError(errno.EACCES, "Permission denied")

    with patch("mp.publish_router.storage.atomic_write_text", refuse), \
         patch("pathlib.Path.unlink", refuse):
        res = fanout(summary_json=summary_json, cfg=Config(), transcript_md=None,
                     publishers=[_Sink("notion", seen, tmp_path / "x")])
    assert seen == [], "no sink may run when the outcome could not be recorded either way"
    assert publish_failed(res)
    assert res["sinks"] == {}


def test_a_marker_that_cannot_be_written_falls_back_to_removing_the_old_file(tmp_path: Path) -> None:
    summary_json = _summary_json(tmp_path)
    sidecar = _old_publish_sidecar(tmp_path)
    real = storage.atomic_write_text
    calls = {"n": 0}

    def first_write_fails(path, text, **kw):
        calls["n"] += 1
        if calls["n"] == 1:
            raise OSError(errno.EIO, "Input/output error")
        return real(path, text, **kw)

    seen: list[str] = []

    class _Look:
        name = "notion"

        def upsert(self, **_k):
            seen.append("present" if sidecar.exists() else "absent")
            return {"page_url": "u://notion"}

    with patch("mp.publish_router.storage.atomic_write_text", first_write_fails):
        res = fanout(summary_json=summary_json, cfg=Config(), transcript_md=None, publishers=[_Look()])
    assert seen == ["absent"]
    assert json.loads(sidecar.read_text())["state"] == "full"
    assert not publish_failed(res)


def test_unknown_is_part_of_the_publish_vocabulary() -> None:
    assert publish_router.PUBLISH_STATE_UNKNOWN == "unknown"


# ---------- F054: the Apple handoff sentinel ------------------------------------------


def _apple_run(tmp_path: Path, backend: str) -> dict:
    wav = tmp_path / f"{STEM}.wav"
    wav.write_bytes(b"")
    _write_fluidaudio_sidecar(tmp_path, stem=STEM)
    cfg = Config()
    cfg.summarization.backend = backend
    summary_json = tmp_path / f"{STEM}.summary.json"
    summary_json.write_text("{}", encoding="utf-8")
    pub = {"page_id": None, "page_url": None, "sinks": {}, "failures": [], "no_sinks_configured": True}
    with patch("mp.orchestrate.summarize",
               return_value={"json": summary_json, "md": tmp_path / f"{STEM}.summary.md",
                             "backend": backend, "model": "m"}), \
         patch("mp.orchestrate.publish_fanout", return_value=pub):
        return run_all(wav, cfg=cfg)


def test_a_leftover_apple_sentinel_is_cleared_by_a_run_on_another_backend(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.delenv("MP_FORCE_BYO", raising=False)
    sentinel = tmp_path / f"{STEM}.apple_pending.json"
    sentinel.write_text(json.dumps({"transcript": "an earlier run's"}))
    result = _apple_run(tmp_path, "anthropic")
    assert "skipped" not in result
    assert not sentinel.exists(), "the daemon would divert this run into an on-device re-summarize"


def test_an_apple_run_still_ends_with_exactly_its_own_sentinel(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.delenv("MP_FORCE_BYO", raising=False)
    sentinel = tmp_path / f"{STEM}.apple_pending.json"
    sentinel.write_text(json.dumps({"stale": True}))
    result = _apple_run(tmp_path, "apple_intelligence")
    assert result["skipped"] == "apple_pending"
    written = json.loads(sentinel.read_text())
    assert "stale" not in written
    assert [p.name for p in tmp_path.glob("*.apple_pending.json")] == [sentinel.name]
