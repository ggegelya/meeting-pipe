"""Tests for the orchestrator's short-circuit paths.

ASR + diarization run in Swift (FluidAudio) before `run_all` is invoked,
so every test pre-writes a `<stem>.json` sidecar with `backend:
"fluidaudio"`. We exercise: the FluidAudio short-circuit (skip the
finalize fallback when segments are already labelled), the BYO toggle,
the long-meeting guard, the no-speech short-circuit, and the
missing-sidecar error path.
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Iterable
from unittest.mock import patch

import pytest

from mp.config import Config
from mp.orchestrate import run_all


def _write_fluidaudio_sidecar(
    tmp_path: Path,
    *,
    stem: str = "20260516-0900",
    segments: Iterable[dict] | None = None,
    diarization: bool = True,
    diarization_failed: bool = False,
) -> Path:
    """Write a FluidAudio-style sidecar at `<tmp_path>/<stem>.json` so the
    orchestrator's daemon-transcript path is followed without spinning up
    any real ASR."""
    segs = list(segments) if segments is not None else [
        {"start": 0.0, "end": 1.0, "text": "Hi.", "speaker": "speaker_0"},
        {"start": 1.0, "end": 2.0, "text": "World.", "speaker": "speaker_1"},
    ]
    json_path = tmp_path / f"{stem}.json"
    json_path.write_text(
        json.dumps(
            {
                "language": "en",
                "segments": segs,
                "audio_path": str(tmp_path / f"{stem}.wav"),
                "audio_seconds": 2.0,
                "model": "parakeet-tdt-0.6b-v3",
                "backend": "fluidaudio",
                "diarization": diarization,
                "diarization_failed": diarization_failed,
                "streaming": False,
                "finalized": True,
            }
        ),
        encoding="utf-8",
    )
    return json_path


def test_force_byo_skips_summarize_and_publish(tmp_path: Path, monkeypatch):
    monkeypatch.delenv("MP_FORCE_BYO", raising=False)
    stem = "20260430-1500"
    wav = tmp_path / f"{stem}.wav"
    wav.write_bytes(b"")
    _write_fluidaudio_sidecar(tmp_path, stem=stem)
    cfg = Config()

    summarize_called = []
    publish_called = []

    with patch("mp.orchestrate.summarize", side_effect=lambda *a, **k: summarize_called.append(1) or {}), \
         patch("mp.orchestrate.publish_fanout", side_effect=lambda *a, **k: publish_called.append(1) or {}):
        result = run_all(wav, cfg=cfg, force_byo=True)

    assert summarize_called == []
    assert publish_called == []
    assert result["skipped"] == "byo"
    assert result["page_id"] is None
    assert "manual_bundle" in result
    bundle = Path(result["manual_bundle"])
    assert bundle.exists()
    assert "Manual processing required" in bundle.read_text(encoding="utf-8")


def test_env_var_triggers_byo(tmp_path: Path, monkeypatch):
    """MP_FORCE_BYO=1 in the environment is equivalent to force_byo=True.
    That's how the Swift launcher signals the per-meeting toggle."""
    monkeypatch.setenv("MP_FORCE_BYO", "1")
    stem = "20260430-1500"
    wav = tmp_path / f"{stem}.wav"
    wav.write_bytes(b"")
    _write_fluidaudio_sidecar(tmp_path, stem=stem)
    cfg = Config()

    with patch("mp.orchestrate.summarize") as s, \
         patch("mp.orchestrate.publish_fanout") as p:
        result = run_all(wav, cfg=cfg)

    s.assert_not_called()
    p.assert_not_called()
    assert result["skipped"] == "byo"


def test_fluidaudio_sidecar_skips_finalize_diarization(tmp_path: Path, monkeypatch):
    """The daemon writes `<stem>.json` with FluidAudio segments already
    speaker-labelled. The orchestrator should trust those labels and
    write `finalized: true` without touching the channel-aware fallback."""
    monkeypatch.delenv("MP_FORCE_BYO", raising=False)
    stem = "20260516-0900"
    wav = tmp_path / f"{stem}.wav"
    wav.write_bytes(b"")
    json_path = _write_fluidaudio_sidecar(tmp_path, stem=stem)

    cfg = Config()
    summary_json = tmp_path / f"{stem}.summary.json"
    summary_json.write_text("{}", encoding="utf-8")

    with patch("mp.orchestrate.summarize", return_value={"json": summary_json, "md": tmp_path / "x.md"}), \
         patch("mp.orchestrate.publish_fanout", return_value={"page_id": "p", "page_url": "u", "idempotent": False}):
        result = run_all(wav, cfg=cfg)

    assert result["page_id"] == "p"

    data = json.loads(json_path.read_text(encoding="utf-8"))
    assert data["finalized"] is True
    assert data["segments"][0]["speaker"] == "speaker_0"


def test_finalize_falls_back_to_channel_aware_when_labels_missing(tmp_path: Path, monkeypatch):
    """If FluidAudio diarization didn't land (no speaker labels on the
    segments), the orchestrator's finalize step labels by channel against
    the stereo WAV. We patch is_stereo_recording to True so we don't have
    to write a real WAV; assign_speakers_by_channel is patched to a
    deterministic stub."""
    monkeypatch.delenv("MP_FORCE_BYO", raising=False)
    stem = "20260430-1500"
    wav = tmp_path / f"{stem}.wav"
    wav.write_bytes(b"")
    json_path = _write_fluidaudio_sidecar(
        tmp_path,
        stem=stem,
        segments=[
            {"start": 0.0, "end": 1.0, "text": "Hi."},
            {"start": 1.0, "end": 2.0, "text": "Hello."},
        ],
    )

    cfg = Config()
    summary_json = tmp_path / f"{stem}.summary.json"
    summary_json.write_text("{}", encoding="utf-8")

    def fake_label_by_channel(segs, _wav):
        return [{**s, "speaker": "speaker_user"} for s in segs]

    with patch("mp.orchestrate.is_stereo_recording", return_value=True), \
         patch("mp.orchestrate.assign_speakers_by_channel", side_effect=fake_label_by_channel), \
         patch("mp.orchestrate.summarize", return_value={"json": summary_json, "md": tmp_path / "x.md"}), \
         patch("mp.orchestrate.publish_fanout", return_value={"page_id": "p", "page_url": "u", "idempotent": False}):
        run_all(wav, cfg=cfg)

    data = json.loads(json_path.read_text(encoding="utf-8"))
    assert data["finalized"] is True
    assert data["diarization"] is True
    assert data["diarization_failed"] is False
    assert all(s["speaker"] == "speaker_user" for s in data["segments"])


def test_finalize_marks_failed_when_mono_and_unlabelled(tmp_path: Path, monkeypatch):
    """Mono WAV with no FluidAudio labels: the finalize step has no way
    to assign speakers, so it surfaces the failure in the sidecar and
    stamps `Speaker?` on every segment."""
    monkeypatch.delenv("MP_FORCE_BYO", raising=False)
    stem = "20260430-1500"
    wav = tmp_path / f"{stem}.wav"
    wav.write_bytes(b"")
    json_path = _write_fluidaudio_sidecar(
        tmp_path,
        stem=stem,
        segments=[
            {"start": 0.0, "end": 1.0, "text": "Hi."},
        ],
    )

    cfg = Config()
    summary_json = tmp_path / f"{stem}.summary.json"
    summary_json.write_text("{}", encoding="utf-8")

    with patch("mp.orchestrate.is_stereo_recording", return_value=False), \
         patch("mp.orchestrate.summarize", return_value={"json": summary_json, "md": tmp_path / "x.md"}), \
         patch("mp.orchestrate.publish_fanout", return_value={"page_id": "p", "page_url": "u", "idempotent": False}):
        run_all(wav, cfg=cfg)

    data = json.loads(json_path.read_text(encoding="utf-8"))
    assert data["diarization_failed"] is True
    assert data["segments"][0]["speaker"] == "Speaker?"


def test_missing_sidecar_raises(tmp_path: Path, monkeypatch):
    """The Python pipeline no longer carries ASR. If the daemon didn't
    produce `<stem>.json`, `run_all` must fail loudly rather than
    silently falling back to something that doesn't exist."""
    monkeypatch.delenv("MP_FORCE_BYO", raising=False)
    wav = tmp_path / "20260430-1500.wav"
    wav.write_bytes(b"")
    cfg = Config()

    with pytest.raises(RuntimeError) as exc:
        run_all(wav, cfg=cfg)
    assert "FluidAudio" in str(exc.value)


def test_no_speech_short_circuits_before_byo(tmp_path: Path, monkeypatch):
    """Empty transcript short-circuits to `skipped: no_speech`. Doesn't
    even bother with the BYO bundle if there is nothing to summarise."""
    monkeypatch.setenv("MP_FORCE_BYO", "1")
    stem = "20260430-1500"
    wav = tmp_path / f"{stem}.wav"
    wav.write_bytes(b"")
    _write_fluidaudio_sidecar(tmp_path, stem=stem, segments=[])
    cfg = Config()

    with patch("mp.orchestrate.summarize") as s, \
         patch("mp.orchestrate.publish_fanout") as p:
        result = run_all(wav, cfg=cfg)
    s.assert_not_called()
    p.assert_not_called()
    assert result["skipped"] == "no_speech"
    assert "manual_bundle" not in result
