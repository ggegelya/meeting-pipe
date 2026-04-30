"""Unit tests for `mp doctor` log-parsing helpers.

The live HTTP probes (Anthropic / Notion / HuggingFace) aren't exercised
here — those are covered by `mp doctor` against real keys when the user
runs it. What's worth testing is the pure-string TCC log parser, since
that's the surface whose regression would silently regress the
"speaker recognition broken" diagnosis we just landed.
"""
from __future__ import annotations

from pathlib import Path

from mp.doctor import _scan_recorder_log_for_tcc


def _write_log(tmp_path: Path, lines: list[str]) -> Path:
    p = tmp_path / "recorder.log"
    p.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return p


def test_returns_none_when_log_missing(tmp_path: Path) -> None:
    assert _scan_recorder_log_for_tcc(tmp_path / "absent.log") is None


def test_returns_none_when_log_has_no_scstream_lines(tmp_path: Path) -> None:
    p = _write_log(tmp_path, [
        "[2026-04-30T13:30:50.650Z] start: final=meet.wav mic=meet.mic.wav",
        "[2026-04-30T13:30:54.027Z] engine started",
    ])
    assert _scan_recorder_log_for_tcc(p) is None


def test_detects_prewarm_denial(tmp_path: Path) -> None:
    line = (
        "[2026-04-30T12:41:05.150Z] WARN: SCShareableContent prewarm failed: "
        "The user declined TCCs for application, window, display capture"
    )
    p = _write_log(tmp_path, [line])
    out = _scan_recorder_log_for_tcc(p)
    assert out is not None
    assert "declined TCCs" in out


def test_detects_stream_start_denial(tmp_path: Path) -> None:
    line = (
        "[2026-04-30T13:30:54.146Z] WARN: SCStream start failed: "
        "The user declined TCCs for application, window, display capture — recording mic-only"
    )
    p = _write_log(tmp_path, [line])
    out = _scan_recorder_log_for_tcc(p)
    assert out is not None
    assert "SCStream start failed" in out


def test_returns_most_recent_when_status_changed(tmp_path: Path) -> None:
    """When the user fixed permission between runs, the newest line wins."""
    p = _write_log(tmp_path, [
        "[2026-04-30T12:41:05.150Z] WARN: SCShareableContent prewarm failed: declined TCCs",
        "[2026-04-30T13:00:00.000Z] some unrelated line",
        "[2026-04-30T14:00:00.000Z] SCStream start ok",
    ])
    out = _scan_recorder_log_for_tcc(p)
    assert out is not None
    # Newest first — the OK line is what surfaces.
    assert "SCStream start ok" in out
    assert "declined TCCs" not in out


def test_handles_unreadable_log_gracefully(tmp_path: Path, monkeypatch) -> None:
    p = tmp_path / "recorder.log"
    p.write_text("placeholder", encoding="utf-8")

    def raise_oserror(*args, **kwargs):
        raise OSError("simulated read failure")

    monkeypatch.setattr(Path, "read_text", raise_oserror)
    assert _scan_recorder_log_for_tcc(p) is None
