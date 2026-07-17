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
from mp.diarize import cosine_similarity
from mp.orchestrate import (
    _check_too_long,
    _finalize_streamed_transcript,
    _will_summarize_locally,
    _write_manual_bundle,
    main as orchestrate_main,
    run_all,
)
from mp.publish_router import EXIT_PUBLISH_FAILED
from mp.roster import EMBEDDING_DIM, RosterStore
from mp.voiceprint import VoiceprintStore


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


def test_run_all_threads_backend_override_to_summarize(tmp_path: Path, monkeypatch):
    """PIPE6: a one-shot backend override reaches the summarize call, so a re-run
    over the existing transcript uses the chosen backend without rewriting the
    workflow."""
    monkeypatch.delenv("MP_FORCE_BYO", raising=False)
    stem = "20260707-1500"
    wav = tmp_path / f"{stem}.wav"
    wav.write_bytes(b"")
    _write_fluidaudio_sidecar(tmp_path, stem=stem)
    summary_json = tmp_path / f"{stem}.summary.json"
    summary_json.write_text("{}", encoding="utf-8")

    with patch("mp.orchestrate.summarize", return_value={"json": summary_json, "md": tmp_path / "x.md"}) as s, \
         patch("mp.orchestrate.publish_fanout", return_value={"page_id": "p", "page_url": "u", "idempotent": False}):
        run_all(wav, cfg=Config(), backend="local")

    assert s.call_args.kwargs["backend"] == "local"


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


def _streamed_with_embeddings(wav: Path, segments: list[dict], embeddings: dict) -> dict:
    return {
        "language": "en",
        "segments": segments,
        "audio_path": str(wav),
        "audio_seconds": 9.0,
        "model": "parakeet-tdt-0.6b-v3",
        "backend": "fluidaudio",
        "diarization": True,
        "diarization_failed": False,
        "streaming": False,
        "finalized": True,
        "speaker_embeddings": embeddings,
    }


def test_finalize_voiceprint_match_names_me_and_strips_embeddings(
    tmp_path: Path, monkeypatch
):
    """FEAT3-VOICEPRINT: the voiceprint-matched speaker becomes "me" even when
    another speaker talks far more, and the daemon's per-speaker embeddings are
    stripped from the final transcript the Library reads."""
    dim = 256
    e0 = [1.0] + [0.0] * (dim - 1)       # the user's direction
    e1 = [0.0, 1.0] + [0.0] * (dim - 2)  # someone else
    store = VoiceprintStore(tmp_path / "vp.json")
    store.update(e0)  # voiceprint aligned to speaker_0

    wav = tmp_path / "20260501-1000.wav"
    wav.write_bytes(b"")
    streamed = _streamed_with_embeddings(
        wav,
        [
            {"start": 0.0, "end": 1.0, "text": "hi", "speaker": "speaker_0"},
            {"start": 1.0, "end": 9.0, "text": "lots", "speaker": "speaker_1"},
        ],
        {"speaker_0": e0, "speaker_1": e1},
    )
    # Mono, so enrollment no-ops; this exercises match + strip only.
    monkeypatch.setattr("mp.diarize.is_stereo_recording", lambda w: False)
    out = _finalize_streamed_transcript(
        wav, streamed, user_label="Me",
        voiceprint_store=store, roster_store=RosterStore(tmp_path / "roster.json"),
    )

    data = json.loads(out["json"].read_text(encoding="utf-8"))
    assert "speaker_embeddings" not in data
    # speaker_1 talks 8x longer, but the voiceprint matched the short speaker_0
    # as "Me"; speaker_1 has an embedding and no roster match, so it is THEM-A.
    assert [s["speaker"] for s in data["segments"]] == ["Me", "THEM-A"]
    # Embeddings are persisted keyed by final label for the Library naming UI.
    emb = json.loads((wav.parent / f"{wav.stem}.embeddings.json").read_text(encoding="utf-8"))
    assert set(emb["embeddings"]) == {"Me", "THEM-A"}


def test_finalize_names_nobody_me_when_the_user_stayed_silent(tmp_path: Path, monkeypatch):
    """The owner sat in a meeting and never spoke: no voice matches the
    voiceprint and nothing lands on the mic channel. The user's name must go
    to nobody, rather than to whoever talked most (measured on 20260717-103053,
    where a 50 s speaker at 0.19 cosine was labelled with the owner's name)."""
    dim = 256
    mine = [1.0] + [0.0] * (dim - 1)         # enrolled, but absent from this meeting
    talker = [0.0, 1.0] + [0.0] * (dim - 2)  # the person who did all the talking
    quiet = [0.0, 0.0, 1.0] + [0.0] * (dim - 3)
    store = VoiceprintStore(tmp_path / "vp.json")
    store.update(mine)

    wav = tmp_path / "20260501-1300.wav"
    wav.write_bytes(b"")
    streamed = _streamed_with_embeddings(
        wav,
        [
            {"start": 0.0, "end": 50.0, "text": "long update", "speaker": "speaker_0"},
            {"start": 50.0, "end": 52.0, "text": "ok", "speaker": "speaker_1"},
        ],
        {"speaker_0": talker, "speaker_1": quiet},
    )
    # Stereo, but nobody is mic-side: the owner's microphone carried no speech.
    monkeypatch.setattr("mp.diarize.is_stereo_recording", lambda w: True)
    monkeypatch.setattr(
        "mp.diarize.assign_speakers_by_channel",
        lambda segments, w: [{**s, "speaker": "speaker_other"} for s in segments],
    )
    out = _finalize_streamed_transcript(
        wav, streamed, user_label="Heorhii",
        voiceprint_store=store, roster_store=RosterStore(tmp_path / "roster.json"),
    )

    data = json.loads(out["json"].read_text(encoding="utf-8"))
    speakers = [s["speaker"] for s in data["segments"]]
    assert "Heorhii" not in speakers
    assert speakers == ["THEM-A", "THEM-B"]
    # An absent owner must not have their voiceprint updated from a stranger.
    assert store.meetings() == 1
    assert cosine_similarity(store.embedding(), mine) > 0.99


def test_finalize_enrolls_voiceprint_from_stereo_mic_channel(tmp_path: Path, monkeypatch):
    """On a stereo meeting with no prior voiceprint, finalize folds the
    mic-channel user's embedding into the store (auto-enrollment)."""
    dim = 256
    e0 = [1.0] + [0.0] * (dim - 1)
    e1 = [0.0, 1.0] + [0.0] * (dim - 2)
    store = VoiceprintStore(tmp_path / "vp.json")
    assert store.meetings() == 0

    wav = tmp_path / "20260501-1100.wav"
    wav.write_bytes(b"")
    streamed = _streamed_with_embeddings(
        wav,
        [
            {"start": 0.0, "end": 2.0, "text": "hi", "speaker": "speaker_0"},
            {"start": 2.0, "end": 4.0, "text": "hello", "speaker": "speaker_1"},
        ],
        {"speaker_0": e0, "speaker_1": e1},
    )
    # identify_user_speaker resolves both helpers from the diarize namespace:
    # speaker_0 lands on the mic channel, so it is the enrollment target.
    monkeypatch.setattr("mp.diarize.is_stereo_recording", lambda w: True)
    monkeypatch.setattr(
        "mp.diarize.assign_speakers_by_channel",
        lambda segments, w: [
            {**segments[0], "speaker": "speaker_user"},
            {**segments[1], "speaker": "speaker_other"},
        ],
    )
    _finalize_streamed_transcript(
        wav, streamed, user_label="Me",
        voiceprint_store=store, roster_store=RosterStore(tmp_path / "roster.json"),
    )

    assert store.meetings() == 1
    assert cosine_similarity(store.embedding(), e0) > 0.99  # enrolled speaker_0


def test_finalize_roster_names_enrolled_person_and_clusters_unknown(
    tmp_path: Path, monkeypatch
):
    """FEAT3-ROSTER acceptance: with one person enrolled, a later meeting names
    them, an unknown voice stays an unnamed THEM cluster, and "me" is untouched."""
    def axis(i: int) -> list[float]:
        v = [0.0] * EMBEDDING_DIM
        v[i] = 1.0
        return v

    e0, e1, e2 = axis(0), axis(1), axis(2)  # me, Alice, a stranger
    roster = RosterStore(tmp_path / "roster.json")
    roster.enroll("Alice", e1)
    store = VoiceprintStore(tmp_path / "vp.json")
    store.update(e0)  # the user is identified by voiceprint, not by talking most

    wav = tmp_path / "20260501-1200.wav"
    wav.write_bytes(b"")
    streamed = _streamed_with_embeddings(
        wav,
        [
            {"start": 0.0, "end": 9.0, "text": "lots", "speaker": "speaker_0"},  # me
            {"start": 9.0, "end": 11.0, "text": "hi", "speaker": "speaker_1"},   # Alice
            {"start": 11.0, "end": 12.0, "text": "yo", "speaker": "speaker_2"},  # stranger
        ],
        {"speaker_0": e0, "speaker_1": e1, "speaker_2": e2},
    )
    monkeypatch.setattr("mp.diarize.is_stereo_recording", lambda w: False)
    out = _finalize_streamed_transcript(
        wav, streamed, user_label="Me",
        voiceprint_store=store, roster_store=roster,
    )

    data = json.loads(out["json"].read_text(encoding="utf-8"))
    assert [s["speaker"] for s in data["segments"]] == ["Me", "Alice", "THEM-A"]


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

    # A terminal marker is written so the Library shows a "No speech" state
    # instead of spinning in "Processing" until the staleness window flips it
    # to a misleading "Failed".
    marker = tmp_path / f"{stem}.empty.json"
    assert marker.exists(), "no_speech skip must write the .empty.json marker"
    payload = json.loads(marker.read_text(encoding="utf-8"))
    assert payload["stem"] == stem
    assert payload["reason"] == "no_speech"


def test_suspect_transcript_short_circuits(tmp_path: Path, monkeypatch):
    """A degenerate transcript (a looping decoder) short-circuits to
    `skipped: suspect_transcript` rather than burning a model call and
    publishing garbage (LOCAL2/AUD-21). The marker records the true reason."""
    monkeypatch.delenv("MP_FORCE_BYO", raising=False)
    stem = "20260430-1600"
    wav = tmp_path / f"{stem}.wav"
    wav.write_bytes(b"")
    looping = [
        {"start": float(i), "end": float(i + 1), "text": "thank you so much",
         "speaker": "speaker_0"}
        for i in range(200)
    ]
    _write_fluidaudio_sidecar(tmp_path, stem=stem, segments=looping)
    cfg = Config()

    with patch("mp.orchestrate.summarize") as s, \
         patch("mp.orchestrate.publish_fanout") as p:
        result = run_all(wav, cfg=cfg)
    s.assert_not_called()
    p.assert_not_called()
    assert result["skipped"] == "suspect_transcript"

    marker = tmp_path / f"{stem}.empty.json"
    assert marker.exists(), "a suspect transcript must write a terminal marker"
    payload = json.loads(marker.read_text(encoding="utf-8"))
    assert payload["reason"] == "suspect_transcript"


def test_diarize_cleanup_runs_when_enabled(tmp_path: Path, monkeypatch):
    """When summarization.diarize_cleanup is on and the transcript has
    multiple speakers, run-all runs the cleanup pass before summarize."""
    monkeypatch.delenv("MP_FORCE_BYO", raising=False)
    stem = "20260516-0900"
    wav = tmp_path / f"{stem}.wav"
    wav.write_bytes(b"")
    _write_fluidaudio_sidecar(tmp_path, stem=stem)  # two speakers
    cfg = Config()
    cfg.summarization.diarize_cleanup = True
    summary_json = tmp_path / f"{stem}.summary.json"
    summary_json.write_text("{}", encoding="utf-8")

    cleanup_calls = []

    def fake_cleanup(path, cfg=None, **kwargs):
        cleanup_calls.append(path)
        return {"json": path, "md": tmp_path / f"{stem}.md",
                "merges_count": 1, "reattributions_count": 0, "latency_ms": 3}

    with patch("mp.diarize_cleanup.cleanup_transcript", side_effect=fake_cleanup), \
         patch("mp.orchestrate.summarize", return_value={"json": summary_json, "md": tmp_path / "x.md"}), \
         patch("mp.orchestrate.publish_fanout", return_value={"page_id": "p", "page_url": "u", "idempotent": False}):
        run_all(wav, cfg=cfg)

    assert len(cleanup_calls) == 1


def test_diarize_cleanup_skipped_when_disabled(tmp_path: Path, monkeypatch):
    """Default config leaves cleanup off; run-all must not invoke it."""
    monkeypatch.delenv("MP_FORCE_BYO", raising=False)
    stem = "20260516-0900"
    wav = tmp_path / f"{stem}.wav"
    wav.write_bytes(b"")
    _write_fluidaudio_sidecar(tmp_path, stem=stem)
    summary_json = tmp_path / f"{stem}.summary.json"
    summary_json.write_text("{}", encoding="utf-8")

    cleanup_calls = []

    with patch("mp.diarize_cleanup.cleanup_transcript",
               side_effect=lambda *a, **k: cleanup_calls.append(1) or {}), \
         patch("mp.orchestrate.summarize", return_value={"json": summary_json, "md": tmp_path / "x.md"}), \
         patch("mp.orchestrate.publish_fanout", return_value={"page_id": "p", "page_url": "u", "idempotent": False}):
        run_all(wav, cfg=Config())

    assert cleanup_calls == []


def test_apple_intelligence_hands_off_and_writes_sentinel(tmp_path: Path, monkeypatch):
    """apple_intelligence finalizes, writes the sentinel, and stops before
    Python summarize/publish so the daemon can summarize on-device."""
    monkeypatch.delenv("MP_FORCE_BYO", raising=False)
    stem = "20260516-0900"
    wav = tmp_path / f"{stem}.wav"
    wav.write_bytes(b"")
    _write_fluidaudio_sidecar(tmp_path, stem=stem)
    cfg = Config()
    cfg.summarization.backend = "apple_intelligence"

    with patch("mp.orchestrate.summarize") as s, \
         patch("mp.orchestrate.publish_fanout") as p:
        result = run_all(wav, cfg=cfg)

    s.assert_not_called()
    p.assert_not_called()
    assert result["skipped"] == "apple_pending"
    sentinel = tmp_path / f"{stem}.apple_pending.json"
    assert sentinel.exists()
    assert result["apple_pending"] == str(sentinel)


def test_apple_intelligence_bypasses_long_meeting_guard(tmp_path: Path, monkeypatch):
    """The long-meeting paste-bundle guard is for Anthropic cost; Apple is
    on-device and chunks itself, so it hands off rather than writing a bundle
    even when the transcript exceeds the threshold."""
    monkeypatch.delenv("MP_FORCE_BYO", raising=False)
    stem = "20260516-0900"
    wav = tmp_path / f"{stem}.wav"
    wav.write_bytes(b"")
    _write_fluidaudio_sidecar(tmp_path, stem=stem)
    cfg = Config()
    cfg.summarization.backend = "apple_intelligence"
    cfg.summarization.skip_above_chars = 1  # any non-empty transcript exceeds this

    result = run_all(wav, cfg=cfg)

    assert result["skipped"] == "apple_pending"
    assert "manual_bundle" not in result


# --- PIPE4: the long-meeting guard is cloud-only ----------------------------

def test_will_summarize_locally_by_backend(monkeypatch):
    """The guard exemption predicate (PIPE4): on-device backends are exempt, and
    `auto` counts as local only when no Anthropic key is available (mirroring the
    backend-fallback resolution). Regulated forces local even with a key."""
    def cfg_for(backend: str) -> Config:
        c = Config()
        c.summarization.backend = backend
        return c

    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")
    assert _will_summarize_locally(cfg_for("local")) is True
    assert _will_summarize_locally(cfg_for("apple_intelligence")) is True
    assert _will_summarize_locally(cfg_for("anthropic")) is False
    # `auto` with a key tries the cloud first, so it is not exempt.
    assert _will_summarize_locally(cfg_for("auto")) is False
    # Regulated forces local regardless of the key.
    regulated = cfg_for("anthropic")
    regulated.modes.regulated_mode = True
    assert _will_summarize_locally(regulated) is True

    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    # Keyless `auto` resolves to local, so it is exempt (the owner's choice).
    assert _will_summarize_locally(cfg_for("auto")) is True


def test_check_too_long_bundles_for_cloud_but_not_local(tmp_path: Path, monkeypatch):
    """`_check_too_long` writes a paste bundle for a cloud run over the threshold, but
    exempts a local run (which map-reduces the transcript instead)."""
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    stem = "20260516-0900"
    md = tmp_path / f"{stem}.md"
    md.write_text("A: " + "word " * 50, encoding="utf-8")
    t = {"md": md, "json": tmp_path / f"{stem}.json"}
    wav = tmp_path / f"{stem}.wav"
    long_text = md.read_text(encoding="utf-8")

    cloud = Config()
    cloud.summarization.backend = "anthropic"
    cloud.summarization.skip_above_chars = 10
    cloud_skip = _check_too_long(wav, t, long_text, cloud)
    assert cloud_skip is not None and "manual_bundle" in cloud_skip
    assert (tmp_path / f"{stem}.READY_FOR_MANUAL.md").exists()

    (tmp_path / f"{stem}.READY_FOR_MANUAL.md").unlink()
    local = Config()
    local.summarization.backend = "local"
    local.summarization.skip_above_chars = 10
    assert _check_too_long(wav, t, long_text, local) is None
    assert not (tmp_path / f"{stem}.READY_FOR_MANUAL.md").exists()


def test_local_backend_over_threshold_reaches_summarize_without_bundle(tmp_path: Path, monkeypatch):
    """End-to-end: a local run over the threshold no longer dead-ends in a bundle; the
    orchestrator proceeds to `summarize` (which map-reduces on-device)."""
    monkeypatch.delenv("MP_FORCE_BYO", raising=False)
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    stem = "20260516-0900"
    wav = tmp_path / f"{stem}.wav"
    wav.write_bytes(b"")
    _write_fluidaudio_sidecar(tmp_path, stem=stem)
    cfg = Config()
    cfg.summarization.backend = "local"
    cfg.summarization.skip_above_chars = 1  # any non-empty transcript exceeds this

    with patch("mp.orchestrate.summarize", side_effect=RuntimeError("reached summarize")) as s:
        with pytest.raises(RuntimeError, match="reached summarize"):
            run_all(wav, cfg=cfg)
    s.assert_called_once()
    assert not (tmp_path / f"{stem}.READY_FOR_MANUAL.md").exists()


# --- FEAT8: paste bundles carry the flagged moments --------------------------

def test_manual_bundle_includes_flagged_moments(tmp_path: Path):
    stem = "20260707-1500"
    md = tmp_path / f"{stem}.md"
    md.write_text("# Transcript\n\n**A**: long meeting.\n", encoding="utf-8")
    (tmp_path / f"{stem}.json").write_text(
        json.dumps({"segments": [
            {"start": 0.0, "end": 10.0, "text": "Preamble.", "speaker": "A"},
            {"start": 10.0, "end": 20.0, "text": "Key point to remember.", "speaker": "B"},
        ]}),
        encoding="utf-8",
    )
    (tmp_path / f"{stem}.markers.json").write_text(
        json.dumps({"schema_version": 1, "markers": [{"t_seconds": 15.0}]}), encoding="utf-8"
    )

    bundle = _write_manual_bundle(md, char_count=90000, threshold=80000)
    text = bundle.read_text(encoding="utf-8")
    assert "User-flagged moments" in text
    assert "Key point to remember." in text


def test_manual_bundle_without_markers_has_no_flagged_section(tmp_path: Path):
    stem = "20260707-1600"
    md = tmp_path / f"{stem}.md"
    md.write_text("# Transcript\n", encoding="utf-8")
    bundle = _write_manual_bundle(md, char_count=90000, threshold=80000)
    assert "User-flagged moments" not in bundle.read_text(encoding="utf-8")


# --- PIPE1 / AUD-14: an all-sinks-failed run is not a completed run ----------


def _all_sinks_failed_result() -> dict:
    return {
        "page_id": None,
        "page_url": None,
        "sinks": {"notion": {"error": "503 from api.notion.com"}},
        "failures": [("notion", "503 from api.notion.com")],
    }


def _run_with_publish_result(tmp_path: Path, pub: dict, monkeypatch) -> dict:
    monkeypatch.delenv("MP_FORCE_BYO", raising=False)
    stem = "20260516-0900"
    wav = tmp_path / f"{stem}.wav"
    wav.write_bytes(b"")
    _write_fluidaudio_sidecar(tmp_path, stem=stem)
    summary_json = tmp_path / f"{stem}.summary.json"
    summary_json.write_text("{}", encoding="utf-8")
    with patch("mp.orchestrate.summarize",
               return_value={"json": summary_json, "md": tmp_path / f"{stem}.summary.md"}), \
         patch("mp.orchestrate.publish_fanout", return_value=pub):
        return run_all(wav, cfg=Config())


def test_run_all_flags_publish_failed_when_every_sink_failed(tmp_path: Path, monkeypatch):
    result = _run_with_publish_result(tmp_path, _all_sinks_failed_result(), monkeypatch)
    assert result["publish_failed"] is True
    # The transcript and summary are real work and stay addressable, which is what
    # lets the daemon offer a publish-only retry instead of re-summarizing.
    assert result["summary_json"]
    assert result["transcript_md"]


def test_run_all_emits_run_failed_not_run_completed_on_publish_failure(
    tmp_path: Path, monkeypatch
):
    """The daemon keyed "clear the error sidecar, notify published" off a zero exit
    while the event log said `run_completed`. Both had to stop lying."""
    emitted: list[tuple] = []
    monkeypatch.setattr("mp.orchestrate.events.emit",
                        lambda cat, action, **attrs: emitted.append((cat, action, attrs)))
    _run_with_publish_result(tmp_path, _all_sinks_failed_result(), monkeypatch)

    actions = [a for _, a, _ in emitted]
    assert "run_completed" not in actions
    assert "run_failed" in actions
    failed = next(attrs for _, a, attrs in emitted if a == "run_failed")
    assert failed["stage"] == "publish"
    assert "503" in failed["error"]


def test_run_all_completes_normally_on_a_partial_publish(tmp_path: Path, monkeypatch):
    pub = {
        "page_id": "p", "page_url": "u",
        "sinks": {"notion": {"error": "boom"}, "obsidian": {"idempotent": False}},
        "failures": [("notion", "boom")],
    }
    result = _run_with_publish_result(tmp_path, pub, monkeypatch)
    assert "publish_failed" not in result


def test_run_all_completes_when_no_sink_was_configured(tmp_path: Path, monkeypatch):
    pub = {"page_id": None, "page_url": None, "sinks": {}, "failures": [], "regulated": True}
    result = _run_with_publish_result(tmp_path, pub, monkeypatch)
    assert "publish_failed" not in result


def test_main_returns_the_publish_failed_exit_code(tmp_path: Path, monkeypatch):
    """The exit code is the whole Swift-side contract: it is what tells the daemon
    to stamp stage=publish rather than clear the failure sidecar."""
    wav = tmp_path / "20260516-0900.wav"
    wav.write_bytes(b"")
    monkeypatch.setattr("mp.orchestrate.run_all", lambda w, **_: {"publish_failed": True})
    assert orchestrate_main([str(wav)]) == EXIT_PUBLISH_FAILED

    monkeypatch.setattr("mp.orchestrate.run_all", lambda w, **_: {"page_url": "u"})
    assert orchestrate_main([str(wav)]) == 0
