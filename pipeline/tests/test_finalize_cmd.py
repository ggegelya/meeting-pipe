"""`mp finalize` - stage 1 of run-all, standalone (ASR3).

The re-transcribe ratchet re-runs FluidAudio in the daemon and then calls this
to re-derive everything the finalize stage owns, so glossary entries and roster
names learned after a meeting was recorded reach its transcript. The two things
worth pinning: it does that work, and it stops there (no summarize, no publish,
so a batch over an old library costs nothing and touches no sink).
"""
from __future__ import annotations

import json
from pathlib import Path

import pytest

from mp.config import Config
from mp.finalize import finalize, main as finalize_main
from mp.glossary import Glossary
from mp.roster import EMBEDDING_DIM, RosterStore
from mp.voiceprint import VoiceprintStore


def _write_sidecar(tmp_path: Path, stem: str, segments: list[dict]) -> Path:
    json_path = tmp_path / f"{stem}.json"
    json_path.write_text(
        json.dumps(
            {
                "language": "en",
                "segments": segments,
                "audio_path": str(tmp_path / f"{stem}.wav"),
                "audio_seconds": 2.0,
                "model": "parakeet-tdt-0.6b-v3",
                "backend": "fluidaudio",
                "diarization": True,
                "diarization_failed": False,
                "streaming": False,
                "finalized": True,
            }
        ),
        encoding="utf-8",
    )
    return json_path


def test_finalize_applies_the_current_glossary_to_an_old_transcript(tmp_path: Path, monkeypatch):
    stem = "20260101-0900"
    wav = tmp_path / f"{stem}.wav"
    wav.write_bytes(b"")
    json_path = _write_sidecar(
        tmp_path, stem,
        [{"start": 0.0, "end": 1.0, "text": "we shipped perfecta", "speaker": "speaker_0"}],
    )
    # The glossary entry postdates the recording; that is the whole point.
    monkeypatch.setattr(
        "mp.orchestrate.load_glossary",
        lambda _wav: Glossary(terms={"perfecta": "Perfeqta"}),
    )

    out = finalize(wav, cfg=Config())

    assert out["json"] == json_path
    written = json.loads(json_path.read_text(encoding="utf-8"))
    assert written["segments"][0]["text"] == "we shipped Perfeqta"
    assert "Perfeqta" in (tmp_path / f"{stem}.md").read_text(encoding="utf-8")


def test_finalize_never_summarizes_or_publishes(tmp_path: Path, monkeypatch):
    """A batch re-transcribe must cost no engine call and touch no sink; the
    Library offers re-summarize as a separate, explicit follow-up."""
    stem = "20260101-1000"
    wav = tmp_path / f"{stem}.wav"
    wav.write_bytes(b"")
    _write_sidecar(tmp_path, stem, [{"start": 0.0, "end": 1.0, "text": "hi", "speaker": "speaker_0"}])
    summary = tmp_path / f"{stem}.summary.json"
    summary.write_text('{"kept": true}', encoding="utf-8")

    called: list[str] = []
    monkeypatch.setattr("mp.orchestrate.summarize", lambda *a, **k: called.append("summarize"))
    monkeypatch.setattr("mp.orchestrate.publish_fanout", lambda *a, **k: called.append("publish"))
    monkeypatch.setattr("mp.orchestrate.load_glossary", lambda _wav: None)

    finalize(wav, cfg=Config())

    assert called == []
    # The existing summary survives the run, so the meeting is never summary-less.
    assert summary.read_text(encoding="utf-8") == '{"kept": true}'


def test_finalize_reaches_an_old_meeting_with_a_roster_name_learned_since(
    tmp_path: Path, monkeypatch
):
    """The other half of the ASR3 acceptance: a person enrolled after this
    meeting was recorded is named in it once finalize runs again."""
    def axis(i: int) -> list[float]:
        v = [0.0] * EMBEDDING_DIM
        v[i] = 1.0
        return v

    me, alice = axis(0), axis(1)
    roster = RosterStore(tmp_path / "roster.json")
    roster.enroll("Alice", alice)           # enrolled long after the recording
    voiceprints = VoiceprintStore(tmp_path / "vp.json")
    voiceprints.update(me)

    stem = "20260101-1100"
    wav = tmp_path / f"{stem}.wav"
    wav.write_bytes(b"")
    json_path = _write_sidecar(
        tmp_path, stem,
        [
            {"start": 0.0, "end": 9.0, "text": "lots", "speaker": "speaker_0"},
            {"start": 9.0, "end": 11.0, "text": "hi", "speaker": "speaker_1"},
        ],
    )
    payload = json.loads(json_path.read_text(encoding="utf-8"))
    payload["speaker_embeddings"] = {"speaker_0": me, "speaker_1": alice}
    json_path.write_text(json.dumps(payload), encoding="utf-8")

    monkeypatch.setattr("mp.orchestrate.load_glossary", lambda _wav: None)
    monkeypatch.setattr("mp.diarize.is_stereo_recording", lambda w: False)
    cfg = Config()
    cfg.summarization.user_label = "Me"

    finalize(wav, cfg=cfg, voiceprint_store=voiceprints, roster_store=roster)

    labels = [s["speaker"] for s in json.loads(json_path.read_text(encoding="utf-8"))["segments"]]
    assert labels == ["Me", "Alice"]
    # The embeddings sidecar is re-keyed by the final labels, so the Library's
    # naming UI can still enroll off this meeting.
    embeddings = json.loads((tmp_path / f"{stem}.embeddings.json").read_text(encoding="utf-8"))
    assert set(embeddings["embeddings"]) == {"Me", "Alice"}


def test_finalize_without_a_daemon_transcript_raises(tmp_path: Path):
    wav = tmp_path / "20260101-1200.wav"
    wav.write_bytes(b"")
    with pytest.raises(RuntimeError, match="No daemon transcript"):
        finalize(wav, cfg=Config())


def test_main_usage_and_missing_file(tmp_path: Path):
    assert finalize_main([]) == 2
    assert finalize_main([str(tmp_path / "nope.wav")]) == 1


def test_main_exits_nonzero_when_finalize_fails(tmp_path: Path, monkeypatch):
    """The daemon reads the exit code to decide whether the carried overlays are
    safe to write, so a failure must not look like a clean run."""
    wav = tmp_path / "20260101-1300.wav"
    wav.write_bytes(b"")  # exists, but no sidecar beside it
    monkeypatch.setattr("mp.finalize.entry.prepare", lambda **kw: Config())
    assert finalize_main([str(wav)]) == 1
