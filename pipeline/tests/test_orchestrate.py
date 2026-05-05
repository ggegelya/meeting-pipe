"""Tests for the orchestrator's short-circuit paths.

We don't run the real transcribe/summarize/publish stages here — those
are covered by their own modules. What's worth covering at this layer
is the BYO short-circuit (transcript exists, but we skip stages 2-3
and write the manual-paste bundle instead) and the long-meeting guard.
"""
from __future__ import annotations

import json
from pathlib import Path
from unittest.mock import patch

from mp.config import Config
from mp.orchestrate import run_all


def _stub_transcribe_output(tmp_path: Path, *, segments: int, char_count: int) -> dict:
    """Write the JSON + MD that `transcribe()` would produce, then return
    the dict shape `transcribe()` returns. Lets `run_all` short-circuit
    paths execute without invoking whisperx."""
    stem = "20260430-1500"
    json_path = tmp_path / f"{stem}.json"
    md_path = tmp_path / f"{stem}.md"
    json_path.write_text(
        json.dumps({
            "segments": [{"text": "x"}] * segments,
            "language": "en",
            "diarization": True,
        }),
        encoding="utf-8",
    )
    md_path.write_text("x" * char_count, encoding="utf-8")
    return {"json": json_path, "md": md_path}


def test_force_byo_skips_summarize_and_publish(tmp_path: Path, monkeypatch):
    monkeypatch.delenv("MP_FORCE_BYO", raising=False)
    wav = tmp_path / "x.wav"
    wav.write_bytes(b"")  # presence only
    cfg = Config()

    stubbed = _stub_transcribe_output(tmp_path, segments=3, char_count=500)

    summarize_called = []
    publish_called = []

    with patch("mp.orchestrate.transcribe", return_value=stubbed) as t, \
         patch("mp.orchestrate.summarize", side_effect=lambda *a, **k: summarize_called.append(1) or {}), \
         patch("mp.orchestrate.publish", side_effect=lambda *a, **k: publish_called.append(1) or {}):
        result = run_all(wav, cfg=cfg, force_byo=True)
        assert t.called

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
    wav = tmp_path / "x.wav"
    wav.write_bytes(b"")
    cfg = Config()

    stubbed = _stub_transcribe_output(tmp_path, segments=3, char_count=500)

    with patch("mp.orchestrate.transcribe", return_value=stubbed), \
         patch("mp.orchestrate.summarize") as s, \
         patch("mp.orchestrate.publish") as p:
        result = run_all(wav, cfg=cfg)

    s.assert_not_called()
    p.assert_not_called()
    assert result["skipped"] == "byo"


def _streamed_transcript(tmp_path: Path) -> Path:
    """Write a `<stem>.json` with the `streaming: true` marker the
    daemon's StreamingTranscriber leaves on disk during recording."""
    stem = "20260430-1500"
    json_path = tmp_path / f"{stem}.json"
    json_path.write_text(
        json.dumps(
            {
                "language": "en",
                "segments": [
                    {"start": 0.0, "end": 1.0, "text": "Hi.", "words": []},
                    {"start": 1.0, "end": 2.0, "text": "World.", "words": []},
                ],
                "audio_path": str(tmp_path / f"{stem}.wav"),
                "audio_seconds": 2.0,
                "model": "mlx-community/whisper-large-v3-turbo",
                "backend": "mlx-stream",
                "streaming": True,
            }
        ),
        encoding="utf-8",
    )
    return json_path


def test_streamed_transcript_skips_offline_transcribe(tmp_path: Path, monkeypatch):
    """When the daemon's streaming transcriber already wrote a
    `<stem>.json` with `streaming: true`, the orchestrator must NOT
    invoke the offline mlx-whisper path again — it should just diarize,
    summarize, and publish."""
    monkeypatch.delenv("MP_FORCE_BYO", raising=False)
    wav = tmp_path / "20260430-1500.wav"
    wav.write_bytes(b"")
    _streamed_transcript(tmp_path)

    cfg = Config()
    cfg.transcription.disable_diarization = True  # skip diarize work in this test

    summary_json = tmp_path / "20260430-1500.summary.json"
    summary_json.write_text("{}", encoding="utf-8")

    with patch("mp.orchestrate.transcribe") as t, \
         patch("mp.orchestrate.run_diarize") as d, \
         patch("mp.orchestrate.summarize", return_value={"json": summary_json, "md": tmp_path / "x.md"}), \
         patch("mp.orchestrate.publish", return_value={"page_id": "p", "page_url": "u", "idempotent": False}):
        result = run_all(wav, cfg=cfg)

    t.assert_not_called()  # offline transcribe skipped
    d.assert_not_called()  # diarization disabled by config in this test
    assert result["page_id"] == "p"


def test_streamed_transcript_with_speakers_skips_offline_diarize(tmp_path: Path, monkeypatch):
    """When the StreamDiarizer ran during recording and most segments
    already have a speaker label, the orchestrator must skip the offline
    diarize stage entirely (Tier 2.5 — the whole point is to avoid the
    re-run at finalization)."""
    monkeypatch.delenv("MP_FORCE_BYO", raising=False)
    wav = tmp_path / "20260430-1500.wav"
    wav.write_bytes(b"")
    json_path = tmp_path / "20260430-1500.json"
    json_path.write_text(
        json.dumps(
            {
                "language": "en",
                "segments": [
                    {"start": 0.0, "end": 1.0, "text": "Hi.", "speaker": "speaker_0"},
                    {"start": 1.0, "end": 2.0, "text": "Hello.", "speaker": "speaker_1"},
                ],
                "audio_path": str(wav),
                "audio_seconds": 2.0,
                "model": "mlx-community/whisper-large-v3-turbo",
                "backend": "mlx-stream",
                "diarization": True,
                "streaming": True,
            }
        ),
        encoding="utf-8",
    )

    cfg = Config()
    summary_json = tmp_path / "20260430-1500.summary.json"
    summary_json.write_text("{}", encoding="utf-8")

    with patch("mp.orchestrate.transcribe") as t, \
         patch("mp.orchestrate.run_diarize") as d, \
         patch("mp.orchestrate.summarize", return_value={"json": summary_json, "md": tmp_path / "x.md"}), \
         patch("mp.orchestrate.publish", return_value={"page_id": "p", "page_url": "u", "idempotent": False}):
        result = run_all(wav, cfg=cfg)

    t.assert_not_called()
    d.assert_not_called()
    assert result["page_id"] == "p"

    # The finalized JSON should retain the streaming-diarizer labels.
    data = json.loads(json_path.read_text(encoding="utf-8"))
    assert data.get("finalized") is True
    assert data["segments"][0]["speaker"] == "speaker_0"


def test_streamed_transcript_without_speakers_runs_offline_diarize(tmp_path: Path, monkeypatch):
    """When streaming was on but the diarizer was disabled (or
    erroreda), the streamed JSON has no speaker labels. The orchestrator
    must fall back to offline diarize at finalization."""
    monkeypatch.delenv("MP_FORCE_BYO", raising=False)
    wav = tmp_path / "20260430-1500.wav"
    wav.write_bytes(b"")
    (tmp_path / "20260430-1500.json").write_text(
        json.dumps(
            {
                "language": "en",
                "segments": [
                    {"start": 0.0, "end": 1.0, "text": "Hi."},  # no speaker
                    {"start": 1.0, "end": 2.0, "text": "Hello."},
                ],
                "audio_path": str(wav),
                "audio_seconds": 2.0,
                "model": "mlx-community/whisper-large-v3-turbo",
                "backend": "mlx-stream",
                "diarization": False,
                "streaming": True,
            }
        ),
        encoding="utf-8",
    )

    cfg = Config()
    summary_json = tmp_path / "20260430-1500.summary.json"
    summary_json.write_text("{}", encoding="utf-8")

    with patch("mp.orchestrate.transcribe") as t, \
         patch("mp.orchestrate.run_diarize", return_value=[]) as d, \
         patch("mp.orchestrate.summarize", return_value={"json": summary_json, "md": tmp_path / "x.md"}), \
         patch("mp.orchestrate.publish", return_value={"page_id": "p", "page_url": "u", "idempotent": False}):
        run_all(wav, cfg=cfg)

    t.assert_not_called()  # transcribe still skipped (we have segments)
    d.assert_called_once()  # but diarize now runs


def test_streamed_transcript_falls_back_when_unusable(tmp_path: Path, monkeypatch):
    """A streamed JSON with zero segments (e.g. SIGKILL mid-recording)
    must fall back to the offline transcribe path so the user still
    gets a transcript at the end."""
    monkeypatch.delenv("MP_FORCE_BYO", raising=False)
    wav = tmp_path / "20260430-1500.wav"
    wav.write_bytes(b"")

    # Streaming JSON with no segments — the orchestrator should ignore it.
    (tmp_path / "20260430-1500.json").write_text(
        json.dumps({"streaming": True, "segments": [], "language": "en"}),
        encoding="utf-8",
    )

    cfg = Config()
    stubbed = _stub_transcribe_output(tmp_path, segments=2, char_count=200)

    with patch("mp.orchestrate.transcribe", return_value=stubbed) as t, \
         patch("mp.orchestrate.summarize", return_value={"json": tmp_path / "x.summary.json", "md": tmp_path / "x.md"}), \
         patch("mp.orchestrate.publish", return_value={"page_id": "p", "page_url": "u", "idempotent": False}):
        run_all(wav, cfg=cfg)

    t.assert_called_once()  # fell back to offline transcribe


def test_no_speech_short_circuits_before_byo_check(tmp_path: Path, monkeypatch):
    """Empty transcript path takes precedence — don't even bother with
    the BYO bundle if there's nothing to summarise."""
    monkeypatch.setenv("MP_FORCE_BYO", "1")
    wav = tmp_path / "x.wav"
    wav.write_bytes(b"")
    cfg = Config()

    stubbed = _stub_transcribe_output(tmp_path, segments=0, char_count=0)

    with patch("mp.orchestrate.transcribe", return_value=stubbed), \
         patch("mp.orchestrate.summarize") as s, \
         patch("mp.orchestrate.publish") as p:
        result = run_all(wav, cfg=cfg)

    s.assert_not_called()
    p.assert_not_called()
    assert result["skipped"] == "no_speech"
    assert "manual_bundle" not in result
