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
import logging
import math
import stat
import threading
from collections.abc import Iterable
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

import pytest

from mp import providers, storage
from mp.config import Config
from mp.diarize import cosine_similarity
from mp.orchestrate import (
    PIPELINE_LOG_OWNER_ENV,
    _bills_per_token,
    _check_too_long,
    _configure_logging,
    _write_manual_bundle,
    finalize_streamed_transcript,
    run_all,
)
from mp.orchestrate import (
    main as orchestrate_main,
)
from mp.publish_router import EXIT_PUBLISH_FAILED
from mp.roster import EMBEDDING_DIM, RosterStore
from mp.schemas import MeetingSummary
from mp.voiceprint import VoiceprintStore

from .conftest import FakeSummaryClient, RecordingPublisher, read_events
from .fake_health import answer_health


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
    client, publisher = FakeSummaryClient(), RecordingPublisher()

    result = run_all(wav, cfg=cfg, force_byo=True,
                     provider=client.provider(), publishers=[publisher])

    assert client.calls == []
    assert publisher.upserts == []
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
    client, publisher = FakeSummaryClient(), RecordingPublisher()

    result = run_all(wav, cfg=cfg, provider=client.provider(), publishers=[publisher])

    assert client.calls == []
    assert publisher.upserts == []
    assert result["skipped"] == "byo"


def test_run_all_threads_backend_override_to_summarize(tmp_path: Path, monkeypatch):
    """PIPE6: a one-shot backend override reaches the summarize call, so a re-run
    over the existing transcript uses the chosen backend without rewriting the
    workflow. T6: pinned by which provider row answered and what the run sidecar
    recorded, not by the keyword a mock was called with."""
    monkeypatch.delenv("MP_FORCE_BYO", raising=False)
    stem = "20260707-1500"
    wav = tmp_path / f"{stem}.wav"
    wav.write_bytes(b"")
    _write_fluidaudio_sidecar(tmp_path, stem=stem)
    local, cloud = FakeSummaryClient(backend_id="local"), FakeSummaryClient(backend_id="anthropic")
    monkeypatch.setitem(providers.PROVIDERS, "local", local.provider())
    monkeypatch.setitem(providers.PROVIDERS, "anthropic", cloud.provider())

    cfg = Config()
    assert cfg.summarization.backend == "anthropic"
    run_all(wav, cfg=cfg, backend="local", publishers=[])

    assert len(local.calls) == 1
    assert cloud.calls == []
    run = json.loads((tmp_path / f"{stem}.run.json").read_text(encoding="utf-8"))
    assert run["backend"] == "local"


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

    result = run_all(wav, cfg=cfg, provider=FakeSummaryClient().provider(),
                     publishers=[RecordingPublisher()])

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

    def fake_label_by_channel(segs, _wav):
        return [{**s, "speaker": "speaker_user"} for s in segs]

    with patch("mp.orchestrate.is_stereo_recording", return_value=True), \
         patch("mp.orchestrate.assign_speakers_by_channel", side_effect=fake_label_by_channel):
        run_all(wav, cfg=cfg, provider=FakeSummaryClient().provider(), publishers=[])

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

    with patch("mp.orchestrate.is_stereo_recording", return_value=False):
        run_all(wav, cfg=cfg, provider=FakeSummaryClient().provider(), publishers=[])

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
    out = finalize_streamed_transcript(
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
    out = finalize_streamed_transcript(
        wav, streamed, user_label="Avery",
        voiceprint_store=store, roster_store=RosterStore(tmp_path / "roster.json"),
    )

    data = json.loads(out["json"].read_text(encoding="utf-8"))
    speakers = [s["speaker"] for s in data["segments"]]
    assert "Avery" not in speakers
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
            {"start": 0.0, "end": 30.0, "text": "hi", "speaker": "speaker_0"},
            {"start": 30.0, "end": 60.0, "text": "hello", "speaker": "speaker_1"},
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
    finalize_streamed_transcript(
        wav, streamed, user_label="Me",
        voiceprint_store=store, roster_store=RosterStore(tmp_path / "roster.json"),
    )

    assert store.meetings() == 1
    assert cosine_similarity(store.embedding(), e0) > 0.99  # enrolled speaker_0


# --- DIAR11: the owner cluster, its enrolment and its event ------------------------------------


def _axis_emb(i: int) -> list[float]:
    v = [0.0] * EMBEDDING_DIM
    v[i] = 1.0
    return v


def _mic_channel(monkeypatch, verdicts: list[str]) -> None:
    """Stereo, with the channel verdict per segment ('speaker_user' = mic side)."""
    monkeypatch.setattr("mp.diarize.is_stereo_recording", lambda w: True)
    monkeypatch.setattr(
        "mp.diarize.assign_speakers_by_channel",
        lambda segments, w: [{**seg, "speaker": v} for seg, v in zip(segments, verdicts, strict=False)],
    )


def _finalize_two(tmp_path: Path, monkeypatch, *, store, durations=(60.0, 60.0), verdicts=("speaker_user", "speaker_other"),
                  embeddings=None):
    wav = tmp_path / "20260501-1100.wav"
    wav.write_bytes(b"")
    a, b = durations
    streamed = _streamed_with_embeddings(
        wav,
        [
            {"start": 0.0, "end": a, "text": "hi", "speaker": "speaker_0"},
            {"start": a, "end": a + b, "text": "hello", "speaker": "speaker_1"},
        ],
        embeddings or {"speaker_0": _axis_emb(0), "speaker_1": _axis_emb(1)},
    )
    _mic_channel(monkeypatch, list(verdicts))
    events: list[tuple] = []
    monkeypatch.setattr("mp.events.emit", lambda cat, action, **kw: events.append((cat, action, kw)))
    out = finalize_streamed_transcript(
        wav, streamed, user_label="Me",
        voiceprint_store=store, roster_store=RosterStore(tmp_path / "roster.json"),
    )
    data = json.loads(out["json"].read_text(encoding="utf-8"))
    return [seg["speaker"] for seg in data["segments"]], events


def test_two_local_voices_name_the_voiceprint_match_and_enroll_nothing(tmp_path: Path, monkeypatch):
    # F096, end to end: both voices are on the mic with similar time, so the mic tier
    # declines, the self-voiceprint (speaker_1's voice) decides, and nothing is enrolled.
    store = VoiceprintStore(tmp_path / "vp.json")
    store.update(_axis_emb(1))
    before = store.meetings()
    speakers, events = _finalize_two(
        tmp_path, monkeypatch, store=store, verdicts=("speaker_user", "speaker_user"), durations=(100.0, 90.0))
    assert speakers == ["THEM-A", "Me"]
    assert store.meetings() == before
    assert [e[2]["tier"] for e in events if e[1] == "owner_cluster_chosen"] == ["voiceprint"]


def test_a_mic_pick_the_voiceprint_disagrees_with_is_not_enrolled(tmp_path: Path, monkeypatch):
    # The voiceprint is speaker_1's voice; the mic side is speaker_0. A system-side voiceprint
    # pick names nobody, and the mic pick's sample must not poison the voiceprint.
    store = VoiceprintStore(tmp_path / "vp.json")
    store.update(_axis_emb(1))
    before = store.meetings()
    speakers, _ = _finalize_two(tmp_path, monkeypatch, store=store)
    assert speakers == ["THEM-A", "THEM-B"]
    assert store.meetings() == before


def test_a_mic_pick_the_voiceprint_agrees_with_is_enrolled(tmp_path: Path, monkeypatch):
    store = VoiceprintStore(tmp_path / "vp.json")
    store.update(_axis_emb(0))
    speakers, events = _finalize_two(tmp_path, monkeypatch, store=store)
    assert speakers == ["Me", "THEM-A"]
    assert store.meetings() == 2
    assert [e[2]["tier"] for e in events if e[1] == "owner_cluster_chosen"] == ["mic"]


def test_a_voiceprint_that_places_nobody_blocks_enrolment_of_the_mic_pick(tmp_path: Path, monkeypatch):
    # A voiceprint exists but matches neither cluster: the mic pick cannot be corroborated.
    store = VoiceprintStore(tmp_path / "vp.json")
    store.update(_axis_emb(7))
    speakers, _ = _finalize_two(tmp_path, monkeypatch, store=store)
    assert speakers[0] == "Me"  # still named, by the mic tier
    assert store.meetings() == 1  # but not folded into the print


def test_owner_cluster_chosen_is_emitted_once_with_the_evidence_and_no_label_text(tmp_path: Path, monkeypatch):
    store = VoiceprintStore(tmp_path / "vp.json")
    store.update(_axis_emb(0))
    _, events = _finalize_two(tmp_path, monkeypatch, store=store)
    chosen = [e for e in events if e[1] == "owner_cluster_chosen"]
    assert len(chosen) == 1
    cat, _, attrs = chosen[0]
    assert cat == "pipeline"
    assert set(attrs) == {
        "stem", "tier", "mic_fraction", "mic_seconds", "voiceprint_score",
        "runner_up_fraction", "runner_up_seconds", "folded", "flagged",
    }
    assert attrs["stem"] == "20260501-1100"
    assert attrs["tier"] == "mic" and attrs["mic_fraction"] == 1.0 and attrs["mic_seconds"] == 60.0
    assert attrs["voiceprint_score"] == 1.0
    assert attrs["runner_up_fraction"] == 0.0 and attrs["runner_up_seconds"] == 0.0
    assert (attrs["folded"], attrs["flagged"]) == (0, 0)
    assert "Me" not in json.dumps(attrs) and "THEM" not in json.dumps(attrs)


def test_a_fold_keeps_the_chosen_clusters_vector_for_the_owner_label(tmp_path: Path, monkeypatch):
    # speaker_0 (mic-side, the pick) and speaker_1 (a mic-side fragment of the same voice) both
    # become "Me". The daemon lists the fragment first; the stored vector must still be the
    # pick's, which Library naming and the replay read.
    store = VoiceprintStore(tmp_path / "vp.json")
    store.update(_axis_emb(0))
    frag = [0.9, 0.1] + [0.0] * (EMBEDDING_DIM - 2)
    wav = tmp_path / "20260501-1100.wav"
    wav.write_bytes(b"")
    streamed = _streamed_with_embeddings(
        wav,
        [
            {"start": 0.0, "end": 30.0, "text": "frag", "speaker": "speaker_1"},
            {"start": 30.0, "end": 330.0, "text": "main", "speaker": "speaker_0"},
            {"start": 330.0, "end": 400.0, "text": "remote", "speaker": "speaker_2"},
        ],
        {"speaker_1": frag, "speaker_0": _axis_emb(0), "speaker_2": _axis_emb(5)},
    )
    _mic_channel(monkeypatch, ["speaker_user", "speaker_user", "speaker_other"])
    finalize_streamed_transcript(
        wav, streamed, user_label="Me",
        voiceprint_store=store, roster_store=RosterStore(tmp_path / "roster.json"),
    )
    data = json.loads((tmp_path / "20260501-1100.embeddings.json").read_text())
    assert data["embeddings"]["Me"] == _axis_emb(0)


def test_an_owner_matching_system_side_cluster_is_flagged_in_the_event_not_named(tmp_path: Path, monkeypatch):
    store = VoiceprintStore(tmp_path / "vp.json")
    store.update(_axis_emb(0))
    near_owner = [0.7] + [0.0] * (EMBEDDING_DIM - 1)
    near_owner[1] = math.sqrt(1 - 0.49)
    speakers, events = _finalize_two(
        tmp_path, monkeypatch, store=store,
        embeddings={"speaker_0": _axis_emb(0), "speaker_1": near_owner})
    assert speakers == ["Me", "THEM-A"]
    attrs = next(e[2] for e in events if e[1] == "owner_cluster_chosen")
    assert (attrs["folded"], attrs["flagged"]) == (0, 1)


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
    out = finalize_streamed_transcript(
        wav, streamed, user_label="Me",
        voiceprint_store=store, roster_store=roster,
    )

    data = json.loads(out["json"].read_text(encoding="utf-8"))
    assert [s["speaker"] for s in data["segments"]] == ["Me", "Alice", "THEM-A"]


def test_finalize_records_the_near_miss_it_declined_to_name(
    tmp_path: Path, monkeypatch
):
    """FEAT14: a voice the roster came close to and still refused to name leaves
    the transcript exactly as it was, a THEM cluster, and leaves the person it
    came closest to in the embeddings sidecar for the app to offer as a
    suggestion. This is the measured stalled-loop case: 0.62 against their own
    centroid, under the 0.65 floor, which used to render as an unnamed voice with
    nothing anywhere saying who it nearly was."""
    def axis(i: int) -> list[float]:
        v = [0.0] * EMBEDDING_DIM
        v[i] = 1.0
        return v

    e0, e1 = axis(0), axis(1)  # me, and the colleague who scores just under
    close_to_e1 = [0.0] * EMBEDDING_DIM
    close_to_e1[1] = 0.62
    close_to_e1[3] = math.sqrt(1.0 - 0.62**2)

    roster = RosterStore(tmp_path / "roster.json")
    roster.enroll("Alice", close_to_e1)
    store = VoiceprintStore(tmp_path / "vp.json")
    store.update(e0)

    wav = tmp_path / "20260501-1400.wav"
    wav.write_bytes(b"")
    streamed = _streamed_with_embeddings(
        wav,
        [
            {"start": 0.0, "end": 9.0, "text": "lots", "speaker": "speaker_0"},
            {"start": 9.0, "end": 11.0, "text": "hi", "speaker": "speaker_1"},
        ],
        {"speaker_0": e0, "speaker_1": e1},
    )
    monkeypatch.setattr("mp.diarize.is_stereo_recording", lambda w: False)
    out = finalize_streamed_transcript(
        wav, streamed, user_label="Me", voiceprint_store=store, roster_store=roster,
    )

    data = json.loads(out["json"].read_text(encoding="utf-8"))
    assert [s["speaker"] for s in data["segments"]] == ["Me", "THEM-A"], (
        "a near miss names nobody; the suggestion is offered, never applied"
    )
    emb = json.loads((wav.parent / f"{wav.stem}.embeddings.json").read_text(encoding="utf-8"))
    assert emb["near_misses"] == {"THEM-A": "Alice"}
    assert "similarity" not in json.dumps(emb), (
        "no score crosses into the app, so no surface can render one as a confidence"
    )


def test_finalize_writes_no_near_miss_key_when_there_is_none(
    tmp_path: Path, monkeypatch
):
    def axis(i: int) -> list[float]:
        v = [0.0] * EMBEDDING_DIM
        v[i] = 1.0
        return v

    e0, e1 = axis(0), axis(1)
    store = VoiceprintStore(tmp_path / "vp.json")
    store.update(e0)
    wav = tmp_path / "20260501-1500.wav"
    wav.write_bytes(b"")
    streamed = _streamed_with_embeddings(
        wav,
        [
            {"start": 0.0, "end": 9.0, "text": "lots", "speaker": "speaker_0"},
            {"start": 9.0, "end": 11.0, "text": "hi", "speaker": "speaker_1"},
        ],
        {"speaker_0": e0, "speaker_1": e1},
    )
    monkeypatch.setattr("mp.diarize.is_stereo_recording", lambda w: False)
    finalize_streamed_transcript(
        wav, streamed, user_label="Me",
        voiceprint_store=store, roster_store=RosterStore(tmp_path / "roster.json"),
    )
    emb = json.loads((wav.parent / f"{wav.stem}.embeddings.json").read_text(encoding="utf-8"))
    assert "near_misses" not in emb  # an empty roster suggests nobody
    assert emb["schema_version"] == 2


def _finalize_branch(kind: str, tmp_path: Path, monkeypatch) -> tuple[Path, dict]:
    """Build the `(wav, streamed)` pair that steers finalize down one of its two
    branches, and stub the stereo probe each one reads.

    `labelled` is the FluidAudio path (segments already carry speakers);
    `channel_aware` is the fallback that labels against the stereo WAV. Neither
    carries `speaker_embeddings`, so the voiceprint/roster work no-ops and the
    write is what is left to observe."""
    wav = tmp_path / f"20260803-1000-{kind}.wav"
    wav.write_bytes(b"")
    if kind == "labelled":
        segments = [{"start": 0.0, "end": 1.0, "text": "Hi.", "speaker": "speaker_0"}]
        monkeypatch.setattr("mp.diarize.is_stereo_recording", lambda w: False)
    else:
        segments = [{"start": 0.0, "end": 1.0, "text": "Hi."}]
        monkeypatch.setattr("mp.orchestrate.is_stereo_recording", lambda w: True)
        monkeypatch.setattr(
            "mp.orchestrate.assign_speakers_by_channel",
            lambda segs, w: [{**s, "speaker": "speaker_user"} for s in segs],
        )
    streamed = {
        "language": "en",
        "segments": segments,
        "audio_path": str(wav),
        "audio_seconds": 1.0,
        "model": "parakeet-tdt-0.6b-v3",
        "backend": "fluidaudio",
        "streaming": False,
    }
    return wav, streamed


def _finalize(wav: Path, streamed: dict, tmp_path: Path) -> dict[str, Path]:
    return finalize_streamed_transcript(
        wav, streamed, user_label="Me",
        voiceprint_store=VoiceprintStore(tmp_path / "vp.json"),
        roster_store=RosterStore(tmp_path / "roster.json"),
    )


@pytest.mark.parametrize("branch", ["labelled", "channel_aware"])
def test_finalize_commits_both_branches_through_the_atomic_helper(
    branch: str, tmp_path: Path, monkeypatch
):
    """PIPE17: BOTH finalize branches commit `<stem>.json` and `<stem>.md`
    through `storage.atomic_write_text`. PIPE8 recorded the conversion as
    covering this whole function, but only the labelled branch got it and no
    test looked at the other one, so parametrize over both rather than trusting
    the half that was already right. 0600 is asserted here too, since the
    helper is now the only thing setting it (SEC14)."""
    wav, streamed = _finalize_branch(branch, tmp_path, monkeypatch)
    real = storage.atomic_write_text
    seen: list[Path] = []

    def spy(path, text, **kwargs):
        seen.append(Path(path))
        real(path, text, **kwargs)

    monkeypatch.setattr(storage, "atomic_write_text", spy)
    out = _finalize(wav, streamed, tmp_path)

    assert seen == [out["json"], out["md"]]
    assert stat.S_IMODE(out["json"].stat().st_mode) == 0o600
    assert stat.S_IMODE(out["md"].stat().st_mode) == 0o600


@pytest.mark.parametrize("branch", ["labelled", "channel_aware"])
def test_finalize_leaves_the_prior_transcript_intact_when_the_write_dies(
    branch: str, tmp_path: Path, monkeypatch
):
    """The failure PIPE17 was filed against: the launcher watchdog SIGKILLs a
    wedged run-all, or the Mac loses power, partway through the finalize write.
    Whatever was on disk has to survive whole, because the retry parses it and
    neither the no-speech nor the suspect-transcript guard fires on a file that
    is merely truncated."""
    wav, streamed = _finalize_branch(branch, tmp_path, monkeypatch)
    json_path = tmp_path / f"{wav.stem}.json"
    md_path = tmp_path / f"{wav.stem}.md"
    json_path.write_text('{"prior": true}', encoding="utf-8")
    md_path.write_text("# prior", encoding="utf-8")

    def _die(src, dst):
        raise OSError("simulated kill mid-write")

    monkeypatch.setattr(storage.os, "replace", _die)
    with pytest.raises(OSError):
        _finalize(wav, streamed, tmp_path)

    assert json_path.read_text(encoding="utf-8") == '{"prior": true}'
    assert md_path.read_text(encoding="utf-8") == "# prior"
    assert not [p for p in tmp_path.iterdir() if ".tmp-" in p.name]


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
    client, publisher = FakeSummaryClient(), RecordingPublisher()

    result = run_all(wav, cfg=cfg, provider=client.provider(), publishers=[publisher])
    assert client.calls == []
    assert publisher.upserts == []
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
    client, publisher = FakeSummaryClient(), RecordingPublisher()

    result = run_all(wav, cfg=cfg, provider=client.provider(), publishers=[publisher])
    assert client.calls == []
    assert publisher.upserts == []
    assert result["skipped"] == "suspect_transcript"

    marker = tmp_path / f"{stem}.empty.json"
    assert marker.exists(), "a suspect transcript must write a terminal marker"
    payload = json.loads(marker.read_text(encoding="utf-8"))
    assert payload["reason"] == "suspect_transcript"


@pytest.mark.content_floor
def test_a_transcript_below_the_content_floor_is_kept_but_not_summarized(
    tmp_path: Path, monkeypatch, _isolated_logs_dir: Path
):
    """PIPE43: a 20 s, 32-word fragment gets an empty marker with its own reason and a
    `run_skipped` event with the counts, and no summarize call."""
    monkeypatch.delenv("MP_FORCE_BYO", raising=False)
    stem = "20260430-1700"
    wav = tmp_path / f"{stem}.wav"
    wav.write_bytes(b"")
    _write_fluidaudio_sidecar(tmp_path, stem=stem, segments=[
        {"start": 0.0, "end": 20.0, "text": " ".join(["word"] * 32), "speaker": "speaker_0"},
    ])
    client, publisher = FakeSummaryClient(), RecordingPublisher()

    result = run_all(wav, cfg=Config(), provider=client.provider(), publishers=[publisher])
    assert client.calls == []
    assert publisher.upserts == []
    assert result["skipped"] == "below_content_floor"
    payload = json.loads((tmp_path / f"{stem}.empty.json").read_text(encoding="utf-8"))
    assert payload["reason"] == "below_content_floor"
    skipped = [{k: r[k] for k in ("wav", "reason", "words", "span_s")}
               for r in read_events(_isolated_logs_dir)
               if (r["category"], r["action"]) == ("pipeline", "run_skipped")]
    assert skipped == [{"wav": str(wav), "reason": "below_content_floor",
                        "words": 32, "span_s": 20.0}]


@pytest.mark.content_floor
def test_a_transcript_above_the_content_floor_reaches_summarize(tmp_path: Path, monkeypatch):
    monkeypatch.delenv("MP_FORCE_BYO", raising=False)
    stem = "20260430-1800"
    wav = tmp_path / f"{stem}.wav"
    wav.write_bytes(b"")
    _write_fluidaudio_sidecar(tmp_path, stem=stem, segments=[
        {"start": i * 20.0, "end": (i + 1) * 20.0,
         "text": f"point {i} about the roadmap budget hiring plan and the next release",
         "speaker": f"speaker_{i % 2}"}
        for i in range(30)
    ])
    client = FakeSummaryClient(raises=RuntimeError("reached summarize"))
    with pytest.raises(RuntimeError, match="reached summarize"):
        run_all(wav, cfg=Config(), provider=client.provider(), publishers=[])
    assert len(client.calls) == 1
    assert not (tmp_path / f"{stem}.empty.json").exists()


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
    client = FakeSummaryClient()

    cleanup_calls = []

    def fake_cleanup(path, cfg=None, **kwargs):
        cleanup_calls.append(path)
        return {"json": path, "md": tmp_path / f"{stem}.md",
                "merges_count": 1, "reattributions_count": 0, "latency_ms": 3}

    with patch("mp.diarize_cleanup.cleanup_transcript", side_effect=fake_cleanup):
        run_all(wav, cfg=cfg, provider=client.provider(), publishers=[])

    assert len(cleanup_calls) == 1
    assert len(client.calls) == 1


def test_diarize_cleanup_skipped_when_disabled(tmp_path: Path, monkeypatch):
    """Default config leaves cleanup off; run-all must not invoke it."""
    monkeypatch.delenv("MP_FORCE_BYO", raising=False)
    stem = "20260516-0900"
    wav = tmp_path / f"{stem}.wav"
    wav.write_bytes(b"")
    _write_fluidaudio_sidecar(tmp_path, stem=stem)

    cleanup_calls = []

    with patch("mp.diarize_cleanup.cleanup_transcript",
               side_effect=lambda *a, **k: cleanup_calls.append(1) or {}):
        run_all(wav, cfg=Config(), provider=FakeSummaryClient().provider(), publishers=[])

    assert cleanup_calls == []


def test_diarize_cleanup_failure_emits_stage_failed_and_still_summarizes(
    tmp_path: Path, monkeypatch, _isolated_logs_dir: Path
):
    """PIPE19: a cleanup exception stays non-fatal but is no longer silent. It
    used to be one `pipeline.log` warning after a `stage_started` with nothing
    following it, which is how cleanup never running on openai and claude_cli
    went unnoticed."""
    monkeypatch.delenv("MP_FORCE_BYO", raising=False)
    stem = "20260516-0900"
    wav = tmp_path / f"{stem}.wav"
    wav.write_bytes(b"")
    _write_fluidaudio_sidecar(tmp_path, stem=stem)
    cfg = Config()
    cfg.summarization.diarize_cleanup = True
    client = FakeSummaryClient()

    with patch("mp.diarize_cleanup.cleanup_transcript", side_effect=RuntimeError("boom")):
        run_all(wav, cfg=cfg, provider=client.provider(), publishers=[])

    assert len(client.calls) == 1
    rows = read_events(_isolated_logs_dir)
    cleanup = [r for r in rows if r.get("stage") == "diarize_cleanup"]
    assert [r["action"] for r in cleanup] == ["stage_started", "stage_failed"]
    assert cleanup[1]["error"] == "RuntimeError"
    assert cleanup[1]["message"] == "boom"


# ----- PERF25: one local client for speaker cleanup and summarize -----


class _FakeMlxHandler(BaseHTTPRequestHandler):
    """A fake `mlx_lm.server`: healthy only while the faked spawn has it up, and
    answering the cleanup schema with no edits and anything else with a summary."""

    def log_message(self, *_: object) -> None:
        pass

    def do_GET(self) -> None:
        up = self.server.up  # type: ignore[attr-defined]
        if up and answer_health(self):
            return
        self.send_response(503)
        self.end_headers()

    def do_POST(self) -> None:
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
        schema = ((body.get("response_format") or {}).get("json_schema") or {}).get("name")
        self.server.requests.append(schema)  # type: ignore[attr-defined]
        content = {"edits": []} if schema == "speaker_edits" else {
            "title": "Sync", "summary": ["Said hello."], "decisions": [], "actions": [],
            "questions": [], "attendees": [], "detected_language": "en",
        }
        out = json.dumps({"choices": [{"message": {"content": json.dumps(content)}}]})
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(out.encode("utf-8"))


@pytest.fixture
def fake_mlx(monkeypatch):
    """The fake server plus a faked spawn/terminate seam on every
    `LocalSummaryClient`: nothing is launched or signalled, no LOCAL10 marker
    is written, and spawns and closes are counted."""
    from mp.summarize_local import LocalSummaryClient

    server = ThreadingHTTPServer(("127.0.0.1", 0), _FakeMlxHandler)
    server.up = False  # type: ignore[attr-defined]
    server.requests = []  # type: ignore[attr-defined]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    counts = {"spawn": 0, "close": 0, "spawn_over_live": 0}

    class _Proc:
        pid = 4242

        def poll(self):
            return None

    def spawn(self):
        counts["spawn"] += 1
        if self._proc is not None:
            # The real `_spawn` would overwrite the handle and leak this server.
            counts["spawn_over_live"] += 1
        self._proc = _Proc()
        server.up = True  # type: ignore[attr-defined]

    def terminate(self):
        if self._proc is not None:
            self._proc = None
            server.up = False  # type: ignore[attr-defined]

    real_close = LocalSummaryClient.close

    def close(self):
        counts["close"] += 1
        real_close(self)

    monkeypatch.setattr(LocalSummaryClient, "_spawn", spawn)
    monkeypatch.setattr(LocalSummaryClient, "_terminate_proc", terminate)
    monkeypatch.setattr(LocalSummaryClient, "close", close)
    monkeypatch.setattr("mp.local_server.served_identity", lambda _port, home=None: None)
    # The fake is "down" until the faked spawn raises it, as a real stopped server
    # would be (connection refused); it keeps listening, so say so here.
    monkeypatch.setattr(
        LocalSummaryClient, "_probe", lambda self: "ok" if server.up else "down"  # type: ignore[attr-defined]
    )
    yield server, counts
    server.shutdown()
    server.server_close()


def test_local_cleanup_and_summarize_share_one_server(tmp_path: Path, monkeypatch, fake_mlx):
    """With cleanup on and the local backend, cleanup and summarize each built a
    client and closed it, so the server cleanup spawned was killed seconds before
    summarize spawned it again and reloaded the weights (4.3 GB for the 7B).
    One shared client now serves both: one spawn, one close."""
    server, counts = fake_mlx
    monkeypatch.delenv("MP_FORCE_BYO", raising=False)
    stem = "20260516-0900"
    wav = tmp_path / f"{stem}.wav"
    wav.write_bytes(b"")
    _write_fluidaudio_sidecar(tmp_path, stem=stem)  # two speakers, so cleanup calls the model
    cfg = Config()
    cfg.recording.output_dir = tmp_path
    cfg.summarization.backend = "local"
    cfg.summarization.diarize_cleanup = True
    cfg.summarization.local_endpoint = f"http://127.0.0.1:{server.server_address[1]}"

    result = run_all(wav, cfg=cfg, publishers=[RecordingPublisher()])

    assert server.requests[0] == "speaker_edits"        # cleanup ran on the model
    assert server.requests[-1] == "meeting_summary"     # and summarize after it
    assert counts == {"spawn": 1, "close": 1, "spawn_over_live": 0}
    assert server.up is False                           # closed before run_all returned
    assert Path(result["summary_json"]).exists()


def test_failed_local_cleanup_closes_the_shared_server_before_summarize(
    tmp_path: Path, monkeypatch, fake_mlx
):
    """A cleanup that fails after the spawn can leave the server alive but not
    answering health checks (a startup timeout, a request it was too busy to
    finish). Reusing that client, summarize would spawn a second server on the
    same port over the handle to the first and leak it. The failed pass's server
    is closed, as its own client's used to be, and summarize starts clean."""
    from mp.diarize_cleanup import LocalCleanupClient
    from mp.summarize_local import LocalSummaryError

    server, counts = fake_mlx

    def wedge(self, *, window_prompt, speakers):
        self._local._ensure_running()  # spawned...
        server.up = False              # ...but no longer answering
        raise LocalSummaryError("mlx_lm.server did not become healthy")

    monkeypatch.setattr(LocalCleanupClient, "propose_edits", wedge)
    monkeypatch.delenv("MP_FORCE_BYO", raising=False)
    stem = "20260516-0900"
    wav = tmp_path / f"{stem}.wav"
    wav.write_bytes(b"")
    _write_fluidaudio_sidecar(tmp_path, stem=stem)
    cfg = Config()
    cfg.recording.output_dir = tmp_path
    cfg.summarization.backend = "local"
    cfg.summarization.diarize_cleanup = True
    cfg.summarization.local_endpoint = f"http://127.0.0.1:{server.server_address[1]}"

    result = run_all(wav, cfg=cfg, publishers=[RecordingPublisher()])

    assert counts["spawn_over_live"] == 0
    assert counts == {"spawn": 2, "close": 2, "spawn_over_live": 0}
    assert server.requests == ["meeting_summary"]
    assert Path(result["summary_json"]).exists()


def test_cloud_backend_builds_cleanup_and_summarize_clients_as_before(tmp_path: Path, monkeypatch):
    """Only `local` shares. On `anthropic` neither callee is handed a client, so
    each builds its own exactly as it did before PERF25. T6: the summary client is
    observed being built from the `anthropic` row, by `summarize` itself, and the
    `local` row is never built."""
    monkeypatch.delenv("MP_FORCE_BYO", raising=False)
    stem = "20260516-0900"
    wav = tmp_path / f"{stem}.wav"
    wav.write_bytes(b"")
    _write_fluidaudio_sidecar(tmp_path, stem=stem)
    cfg = Config()
    cfg.summarization.backend = "anthropic"
    cfg.summarization.diarize_cleanup = True
    local, cloud = FakeSummaryClient(backend_id="local"), FakeSummaryClient(backend_id="anthropic")
    monkeypatch.setitem(providers.PROVIDERS, "local", local.provider())
    monkeypatch.setitem(providers.PROVIDERS, "anthropic", cloud.provider())

    with patch("mp.diarize_cleanup.cleanup_transcript",
               return_value={"merges_count": 0, "reattributions_count": 0}) as c:
        run_all(wav, cfg=cfg, publishers=[])

    assert "client" not in c.call_args.kwargs
    assert (cloud.builds, len(cloud.calls)) == (1, 1)
    assert local.builds == 0


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
    client, publisher = FakeSummaryClient(), RecordingPublisher()

    result = run_all(wav, cfg=cfg, provider=client.provider(), publishers=[publisher])

    assert client.calls == []
    assert publisher.upserts == []
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

def test_bills_per_token_by_backend(monkeypatch):
    """The gate predicate (PIPE4, narrowed by PIPE27): only per-token engines are
    gated; `auto` only while it has a key to bill; `claude_cli` never (it runs on the
    user's subscription). Regulated forces local even with a key."""
    def cfg_for(backend: str) -> Config:
        c = Config()
        c.summarization.backend = backend
        return c

    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")
    assert _bills_per_token(cfg_for("local")) is False
    assert _bills_per_token(cfg_for("apple_intelligence")) is False
    assert _bills_per_token(cfg_for("claude_cli")) is False
    assert _bills_per_token(cfg_for("anthropic")) is True
    assert _bills_per_token(cfg_for("openai")) is True
    # `auto` with a key tries the cloud first, so it is gated.
    assert _bills_per_token(cfg_for("auto")) is True
    regulated = cfg_for("anthropic")
    regulated.modes.regulated_mode = True
    assert _bills_per_token(regulated) is False

    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    # Keyless `auto` resolves to local, so it is exempt (the owner's choice).
    assert _bills_per_token(cfg_for("auto")) is False


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

    client = FakeSummaryClient(raises=RuntimeError("reached summarize"))
    with pytest.raises(RuntimeError, match="reached summarize"):
        run_all(wav, cfg=cfg, provider=client.provider(), publishers=[])
    assert len(client.calls) == 1
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


def _all_sinks_failed() -> list[RecordingPublisher]:
    return [RecordingPublisher("notion", error=RuntimeError("503 from api.notion.com"))]


def _run_with_publishers(tmp_path: Path, publishers: list, monkeypatch) -> dict:
    monkeypatch.delenv("MP_FORCE_BYO", raising=False)
    stem = "20260516-0900"
    wav = tmp_path / f"{stem}.wav"
    wav.write_bytes(b"")
    _write_fluidaudio_sidecar(tmp_path, stem=stem)
    return run_all(wav, cfg=Config(), provider=FakeSummaryClient().provider(),
                   publishers=publishers)


def test_run_all_flags_publish_failed_when_every_sink_failed(tmp_path: Path, monkeypatch):
    publishers = _all_sinks_failed()
    result = _run_with_publishers(tmp_path, publishers, monkeypatch)
    assert result["publish_failed"] is True
    assert len(publishers[0].upserts) == 1
    # The transcript and summary are real work and stay addressable, which is what
    # lets the daemon offer a publish-only retry instead of re-summarizing.
    assert result["summary_json"]
    assert result["transcript_md"]


def test_run_all_emits_run_failed_not_run_completed_on_publish_failure(
    tmp_path: Path, monkeypatch, _isolated_logs_dir: Path
):
    """The daemon keyed "clear the error sidecar, notify published" off a zero exit
    while the event log said `run_completed`. Both had to stop lying."""
    _run_with_publishers(tmp_path, _all_sinks_failed(), monkeypatch)

    rows = [r for r in read_events(_isolated_logs_dir) if r["category"] == "pipeline"]
    actions = [r["action"] for r in rows]
    assert "run_completed" not in actions
    assert "run_failed" in actions
    failed = next(r for r in rows if r["action"] == "run_failed")
    assert failed["stage"] == "publish"
    assert "503" in failed["error"]


# --- T6: run_all end to end through its two collaborators ---------------------


def test_a_normal_run_writes_the_summary_the_publisher_then_receives(
    tmp_path: Path, monkeypatch, _isolated_logs_dir: Path
):
    """The real `summarize` and the real `fanout`, with only the model and the sink
    faked: what the client answered is what lands in `<stem>.summary.json`, and that
    file's content is what the publisher is handed, beside its own sidecar."""
    monkeypatch.delenv("MP_FORCE_BYO", raising=False)
    stem = "20260516-0900"
    wav = tmp_path / f"{stem}.wav"
    wav.write_bytes(b"")
    _write_fluidaudio_sidecar(tmp_path, stem=stem)
    client, publisher = FakeSummaryClient(), RecordingPublisher()

    result = run_all(wav, cfg=Config(), provider=client.provider(), publishers=[publisher])

    summary_json = tmp_path / f"{stem}.summary.json"
    assert result["summary_json"] == str(summary_json)
    written = MeetingSummary.model_validate_json(summary_json.read_text(encoding="utf-8"))
    assert written.summary == client.summary.summary
    assert client.builds == 1
    [call] = client.calls
    assert "Hi." in call["transcript"] and "World." in call["transcript"]
    assert call["system_prompt"]
    [upsert] = publisher.upserts
    assert upsert["summary"].summary == written.summary
    assert upsert["sidecar_path"] == tmp_path / f"{stem}.recording.json"
    assert upsert["transcript_md"] == tmp_path / f"{stem}.md"
    outcome = json.loads((tmp_path / f"{stem}.publish.json").read_text(encoding="utf-8"))
    assert outcome["state"] == "full"
    run = json.loads((tmp_path / f"{stem}.run.json").read_text(encoding="utf-8"))
    assert run["backend"] == "fake"
    actions = [r["action"] for r in read_events(_isolated_logs_dir) if r["category"] == "pipeline"]
    assert actions[-1] == "run_completed"
    assert "run_failed" not in actions


def test_a_summarizer_that_raises_fails_the_run_at_the_summarize_stage(
    tmp_path: Path, monkeypatch, _isolated_logs_dir: Path
):
    monkeypatch.delenv("MP_FORCE_BYO", raising=False)
    failure_path = tmp_path / "failure.json"
    monkeypatch.setenv("MP_FAILURE_PATH", str(failure_path))
    stem = "20260516-0900"
    wav = tmp_path / f"{stem}.wav"
    wav.write_bytes(b"")
    _write_fluidaudio_sidecar(tmp_path, stem=stem)
    client = FakeSummaryClient(raises=RuntimeError("model fell over"))
    publisher = RecordingPublisher()

    with pytest.raises(RuntimeError, match="model fell over"):
        run_all(wav, cfg=Config(), provider=client.provider(), publishers=[publisher])

    assert len(client.calls) == 1
    assert publisher.upserts == []
    assert not (tmp_path / f"{stem}.summary.json").exists()
    rows = [r for r in read_events(_isolated_logs_dir) if r["category"] == "pipeline"]
    assert [r["stage"] for r in rows if r["action"] == "stage_started"][-1] == "summarize"
    assert not any(r["action"] == "stage_completed" and r.get("stage") == "summarize"
                   for r in rows)
    [failed] = [r for r in rows if r["action"] == "run_failed"]
    assert failed["error_type"] == "RuntimeError"
    assert "model fell over" in failed["error"]
    assert "run_completed" not in [r["action"] for r in rows]
    # What the daemon reads to say which stage failed.
    assert json.loads(failure_path.read_text(encoding="utf-8"))["operation"] == "summary"


# --- PIPE16: a publish-stage missing secret is a publish failure -------------


def test_run_all_reports_a_missing_publish_secret_as_a_failed_publish(
    tmp_path: Path, monkeypatch, _isolated_logs_dir: Path
):
    """`require_env`'s `sys.exit(2)` escaped both of this module's handlers.

    `SystemExit` is a `BaseException`, so the `except Exception` at `run_all` and
    the one at `main` both missed it: no `run_failed`, no exit-3 mapping, no
    `<stem>.publish.json`. The daemon saw exit 2 over a meeting whose summary was
    already on disk, mapped it to the generic pipeline stage (whose retry
    re-summarizes), and `MeetingStore` settled the durable row on **"Ready"** for
    a meeting that published nowhere.

    Driven through the real `publish_router.fanout`, not a patched one, because
    the escape happened in `build_publishers` before any publisher ran.
    """
    monkeypatch.delenv("MP_FORCE_BYO", raising=False)
    monkeypatch.delenv("NOTION_TOKEN", raising=False)
    # `entry.prepare` refills the managed tokens from the login Keychain (SEC8);
    # conftest's `_keychain_unreachable` (T12) is what keeps `delenv` meaningful here.
    stem = "20260516-0900"
    wav = tmp_path / f"{stem}.wav"
    wav.write_bytes(b"")
    _write_fluidaudio_sidecar(tmp_path, stem=stem)
    cfg = Config.model_validate({"output": {"sinks": ["notion"]}})

    # No `publishers`: the configured ones are built, which is where the escape was.
    result = run_all(wav, cfg=cfg, provider=FakeSummaryClient().provider())

    # Exit 3, not 2: `main` returns EXIT_PUBLISH_FAILED off this flag, which is
    # the one code `SinkDispatcher` branches on, so the row gets a publish-only
    # retry over the summary already on disk instead of paying the summarizer
    # twice.
    assert result["publish_failed"] is True
    assert EXIT_PUBLISH_FAILED == 3

    rows = [r for r in read_events(_isolated_logs_dir) if r["category"] == "pipeline"]
    actions = [r["action"] for r in rows]
    assert "run_failed" in actions
    assert "run_completed" not in actions
    failed = next(r for r in rows if r["action"] == "run_failed")
    assert failed["stage"] == "publish"
    assert "NOTION_TOKEN" in failed["error"]

    sidecar = json.loads((tmp_path / f"{stem}.publish.json").read_text(encoding="utf-8"))
    assert sidecar["state"] == "none"
    assert sidecar["sinks"]["notion"]["ok"] is False


def test_run_all_completes_normally_on_a_partial_publish(tmp_path: Path, monkeypatch):
    publishers = [RecordingPublisher("notion", error=RuntimeError("boom")),
                  RecordingPublisher("obsidian", result={"idempotent": False})]
    result = _run_with_publishers(tmp_path, publishers, monkeypatch)
    assert "publish_failed" not in result
    assert [len(p.upserts) for p in publishers] == [1, 1]


def test_run_all_completes_when_no_sink_was_configured(tmp_path: Path, monkeypatch):
    result = _run_with_publishers(tmp_path, [], monkeypatch)
    assert "publish_failed" not in result


def test_run_all_with_a_no_sinks_workflow_exits_0_and_records_local(
    tmp_path: Path, monkeypatch
):
    """WF10, end to end through `main`, the overlay and the real fanout: a
    workflow saved with every destination unchecked writes `workflow_sinks: []`.
    That used to fall back to the global default (`["notion"]`), so with no
    `NOTION_TOKEN` it was an exit-3 publish failure for a publish nobody asked
    for. It now publishes nowhere, exits 0, and records `state: "local"`."""
    monkeypatch.delenv("MP_FORCE_BYO", raising=False)
    monkeypatch.delenv("NOTION_TOKEN", raising=False)
    monkeypatch.setattr(Config, "load", classmethod(lambda cls, *a, **k: Config()))
    # `main` passes no collaborators, so the configured backend's row is swapped (T6).
    monkeypatch.setitem(providers.PROVIDERS, "anthropic", FakeSummaryClient().provider())

    stem = "20260516-0900"
    wav = tmp_path / f"{stem}.wav"
    wav.write_bytes(b"")
    _write_fluidaudio_sidecar(tmp_path, stem=stem)
    (tmp_path / f"{stem}.meta.json").write_text(
        json.dumps({"workflow_name": "Library only", "workflow_sinks": [],
                    "workflow_nda_mode": False}),
        encoding="utf-8",
    )

    assert orchestrate_main([str(wav)]) == 0

    sidecar = json.loads((tmp_path / f"{stem}.publish.json").read_text(encoding="utf-8"))
    assert sidecar["state"] == "local"
    assert sidecar["sinks"] == {}
    assert not (tmp_path / f"{stem}.notion.json").exists()


def test_main_returns_the_publish_failed_exit_code(tmp_path: Path, monkeypatch):
    """The exit code is the whole Swift-side contract: it is what tells the daemon
    to stamp stage=publish rather than clear the failure sidecar."""
    wav = tmp_path / "20260516-0900.wav"
    wav.write_bytes(b"")
    monkeypatch.setattr("mp.orchestrate.run_all", lambda w, **_: {"publish_failed": True})
    assert orchestrate_main([str(wav)]) == EXIT_PUBLISH_FAILED

    monkeypatch.setattr("mp.orchestrate.run_all", lambda w, **_: {"page_url": "u"})
    assert orchestrate_main([str(wav)]) == 0


# ---------------------------------------------------------------------------
# CI6: `_configure_logging` must not touch the production log path above its own
# already-configured guard. A pytest run holds root handlers, so the guard fires
# before the FileHandler is ever built; with the mkdir + touch above it, every
# suite run still bumped `~/Library/Logs/MeetingPipe/pipeline.log`'s mtime and,
# on a fresh checkout or a CI runner, created the directory plus an empty log
# under the process umask rather than the 0600 SEC14 ships for that file.
# ---------------------------------------------------------------------------

def _redirect_home(monkeypatch, tmp_path: Path) -> Path:
    """Point `~` and the logs dir at `tmp_path` and hand back the log dir. Since T9
    `_configure_logging` asks `events.logs_dir`, so the env var is what moves it."""
    monkeypatch.setattr("os.path.expanduser", lambda p: p.replace("~", str(tmp_path), 1))
    logs_dir = tmp_path / "Library" / "Logs" / "MeetingPipe"
    monkeypatch.setenv("MEETINGPIPE_LOGS_DIR", str(logs_dir))
    return logs_dir


def _install_root_logger(monkeypatch, logger: logging.Logger) -> None:
    """Make `logging.getLogger()` hand `_configure_logging` our own logger.

    The real root logger is pytest's, and mutating it leaks handlers into every
    later test in the session.
    """
    monkeypatch.setattr("logging.getLogger", lambda *a, **k: logger)


def test_configure_logging_touches_nothing_when_a_caller_owns_the_root_logger(
    tmp_path: Path, monkeypatch
):
    logs_dir = _redirect_home(monkeypatch, tmp_path)
    already_configured = logging.Logger("mp-ci6-configured")
    already_configured.addHandler(logging.NullHandler())
    _install_root_logger(monkeypatch, already_configured)

    _configure_logging()

    assert not logs_dir.exists(), (
        "a call that returns at the already-configured guard must not create "
        "~/Library/Logs/MeetingPipe: under pytest that is every call, and it "
        "lands the log with the process umask rather than SEC14's 0600 (CI6)"
    )
    assert not (tmp_path / "Library").exists()


def test_configure_logging_still_opens_the_log_when_it_configures_the_root(
    tmp_path: Path, monkeypatch
):
    """The other half of the move: a real run still gets `pipeline.log` on disk
    before anything is logged, which is the promise those two lines exist for."""
    logs_dir = _redirect_home(monkeypatch, tmp_path)
    fresh = logging.Logger("mp-ci6-fresh")  # no handlers, so it takes the full path
    _install_root_logger(monkeypatch, fresh)

    try:
        _configure_logging()
        assert (logs_dir / "pipeline.log").exists()
    finally:
        for handler in list(fresh.handlers):
            handler.close()
            fresh.removeHandler(handler)


# ---------------------------------------------------------------------------
# PERF13: `pipeline.log` has one writer per run. The daemon copies a spawned
# run's stderr into it, so with the daemon's flag set Python must add no
# FileHandler (both used to write, doubling every record); a hand run keeps it.
# ---------------------------------------------------------------------------

def _configured_handlers(monkeypatch, tmp_path: Path, name: str) -> tuple[list[logging.Handler], Path]:
    logs_dir = _redirect_home(monkeypatch, tmp_path)
    fresh = logging.Logger(name)
    _install_root_logger(monkeypatch, fresh)
    _configure_logging()
    handlers = list(fresh.handlers)
    for handler in handlers:
        handler.close()
        fresh.removeHandler(handler)
    return handlers, logs_dir


def test_configure_logging_leaves_the_file_to_the_daemon_that_spawned_it(
    tmp_path: Path, monkeypatch
):
    monkeypatch.setenv(PIPELINE_LOG_OWNER_ENV, "daemon")
    handlers, logs_dir = _configured_handlers(monkeypatch, tmp_path, "mp-perf13-spawned")
    assert not any(isinstance(h, logging.FileHandler) for h in handlers)
    assert any(isinstance(h, logging.StreamHandler) for h in handlers), (
        "stderr is the channel the daemon copies into pipeline.log, so it must stay"
    )
    assert not logs_dir.exists(), "a spawned run must not touch or rotate the daemon's file"


def test_configure_logging_keeps_its_file_handler_on_a_hand_run(tmp_path: Path, monkeypatch):
    monkeypatch.delenv(PIPELINE_LOG_OWNER_ENV, raising=False)
    handlers, logs_dir = _configured_handlers(monkeypatch, tmp_path, "mp-perf13-hand")
    assert [type(h) for h in handlers if isinstance(h, logging.FileHandler)] == [logging.FileHandler]
    assert (logs_dir / "pipeline.log").exists()


def test_with_no_voiceprint_an_over_split_owner_is_named_on_both_clusters_and_bootstraps_the_print(
    tmp_path: Path, monkeypatch
):
    # Owner decision 2026-11-17 (accepting audit F096): two mic-side clusters of comparable size and
    # no print yet are one over-split owner, so the leader enrols and both carry the owner's name.
    # A remote voice is on the call too (an all-mic recording gives the mic tier nothing to compare).
    store = VoiceprintStore(tmp_path / "vp.json")
    assert store.embedding() is None
    wav = tmp_path / "20260501-1100.wav"
    wav.write_bytes(b"")
    streamed = _streamed_with_embeddings(
        wav,
        [
            {"start": 0.0, "end": 100.0, "text": "a", "speaker": "speaker_0"},
            {"start": 100.0, "end": 190.0, "text": "b", "speaker": "speaker_1"},
            {"start": 190.0, "end": 250.0, "text": "c", "speaker": "speaker_2"},
        ],
        {"speaker_0": _axis_emb(0), "speaker_1": _axis_emb(1), "speaker_2": _axis_emb(2)},
    )
    _mic_channel(monkeypatch, ["speaker_user", "speaker_user", "speaker_other"])
    events: list[tuple] = []
    monkeypatch.setattr("mp.events.emit", lambda cat, action, **kw: events.append((cat, action, kw)))
    out = finalize_streamed_transcript(
        wav, streamed, user_label="Me",
        voiceprint_store=store, roster_store=RosterStore(tmp_path / "roster.json"),
    )
    speakers = [seg["speaker"] for seg in json.loads(out["json"].read_text(encoding="utf-8"))["segments"]]
    assert speakers == ["Me", "Me", "THEM-A"]
    assert store.meetings() == 1
    assert cosine_similarity(store.embedding(), _axis_emb(0)) > 0.99   # the LEADER's sample, not the contender's
    chosen = [e[2] for e in events if e[1] == "owner_cluster_chosen"]
    assert [c["tier"] for c in chosen] == ["mic"] and chosen[0]["folded"] == 1


def test_a_print_that_matches_the_split_leader_names_it_alone_and_enrolls_it_once(tmp_path: Path, monkeypatch):
    # The `voiceprint is None` guard in `_me_signals`: with a print the runner-up decline stands,
    # so the contender is not folded even though the print agrees with the leader.
    store = VoiceprintStore(tmp_path / "vp.json")
    store.update(_axis_emb(0))
    wav = tmp_path / "20260501-1100.wav"
    wav.write_bytes(b"")
    streamed = _streamed_with_embeddings(
        wav,
        [
            {"start": 0.0, "end": 100.0, "text": "a", "speaker": "speaker_0"},
            {"start": 100.0, "end": 190.0, "text": "b", "speaker": "speaker_1"},
            {"start": 190.0, "end": 250.0, "text": "c", "speaker": "speaker_2"},
        ],
        {"speaker_0": _axis_emb(0), "speaker_1": _axis_emb(1), "speaker_2": _axis_emb(2)},
    )
    _mic_channel(monkeypatch, ["speaker_user", "speaker_user", "speaker_other"])
    out = finalize_streamed_transcript(
        wav, streamed, user_label="Me",
        voiceprint_store=store, roster_store=RosterStore(tmp_path / "roster.json"),
    )
    speakers = [seg["speaker"] for seg in json.loads(out["json"].read_text(encoding="utf-8"))["segments"]]
    assert speakers == ["Me", "THEM-A", "THEM-B"]
    assert store.meetings() == 1    # the tier declined, so nothing new enrols


# --- SEC38: the success rows carry sink names, never the page address ---------


def test_run_all_success_events_carry_sink_names_and_no_page_url(
    tmp_path: Path, monkeypatch, _isolated_logs_dir: Path
):
    """The page address embeds the meeting title's slug, and the event log is handed to
    analysis sessions; `<stem>.publish.json` keeps the link, the log names the sinks."""
    url = "https://example.invalid/placeholder-topic-slug"
    _run_with_publishers(tmp_path, [
        RecordingPublisher("notion", result={"page_id": "p", "page_url": url, "idempotent": False}),
        RecordingPublisher("obsidian", error=RuntimeError("boom")),
    ], monkeypatch)

    rows = [r for r in read_events(_isolated_logs_dir) if r["category"] == "pipeline"]
    completed = next(r for r in rows if r["action"] == "run_completed")
    stage = next(r for r in rows
                 if r["action"] == "stage_completed" and r.get("stage") == "publish")
    for row in (completed, stage):
        assert "page_url" not in row
        assert "placeholder-topic-slug" not in json.dumps(row)
        assert row["sinks"] == ["notion"]
    assert completed["published"] is True


# MARK: DIAR8: the flag, not the label, says the daemon's diarizer failed

def _stereo_wav(path: Path, *, mic_first: bool = True) -> None:
    """Two seconds of stereo 16 kHz: the mic (left) is loud for the first second and the system (right)
    for the second, so the channel-aware pass has a real answer for each segment."""
    import numpy as np
    import soundfile as sf

    rate = 16000
    t = np.arange(rate) / rate
    tone = (0.4 * np.sin(2 * np.pi * 440 * t) * 32767).astype("int16")
    quiet = np.zeros(rate, dtype="int16")
    left = np.concatenate([tone, quiet]) if mic_first else np.concatenate([quiet, tone])
    right = np.concatenate([quiet, tone]) if mic_first else np.concatenate([tone, quiet])
    sf.write(str(path), np.stack([left, right], axis=1), rate, subtype="PCM_16")


def _swift_failed_streamed(wav: Path, *, failed: bool = True, label: str = "speaker_unknown") -> dict:
    """What Swift writes when its diarizer throws: every segment under its own sentinel."""
    return {
        "language": "en",
        "segments": [
            {"start": 0.0, "end": 1.0, "text": "From the mic.", "speaker": label},
            {"start": 1.0, "end": 2.0, "text": "From the call.", "speaker": label},
        ],
        "audio_path": str(wav),
        "audio_seconds": 2.0,
        "model": "parakeet-tdt-0.6b-v3",
        "backend": "fluidaudio",
        "diarization": not failed,
        "diarization_failed": failed,
        "diarization_failure_reason": "CoreMLError: model failed to load" if failed else None,
        "streaming": False,
        "finalized": True,
    }


def _finalize_streamed(wav: Path, streamed: dict) -> dict:
    from mp.orchestrate import finalize_streamed_transcript

    out = finalize_streamed_transcript(
        wav, dict(streamed), voiceprint_store=VoiceprintStore(path=wav.parent / "vp.json"),
    )
    return json.loads(out["json"].read_text(encoding="utf-8"))


def test_a_failed_diarizer_with_a_stereo_recording_takes_the_channel_path_DIAR8(tmp_path: Path):
    wav = tmp_path / "20261118-1000.wav"
    _stereo_wav(wav)

    data = _finalize_streamed(wav, _swift_failed_streamed(wav))

    assert [s["speaker"] for s in data["segments"]] == ["speaker_user", "speaker_other"]
    assert data["diarization_failed"] is True, "the failure stays on the record"
    assert data["diarization_failure_reason"] == "CoreMLError: model failed to load"
    assert data["speaker_fallback"] == "channel"
    md = (tmp_path / "20261118-1000.md").read_text(encoding="utf-8")
    assert "microphone and system audio" in md
    assert "CoreMLError: model failed to load" in md


def test_a_healthy_run_with_mostly_unknown_segments_stays_labelled_DIAR8(tmp_path: Path):
    """The flag decides, not the label: speaker_unknown is also the healthy diarizer's junk drawer."""
    wav = tmp_path / "20261118-1001.wav"
    _stereo_wav(wav)

    data = _finalize_streamed(wav, _swift_failed_streamed(wav, failed=False))

    assert [s["speaker"] for s in data["segments"]] == ["speaker_unknown", "speaker_unknown"]
    assert "speaker_fallback" not in data


def test_a_failed_diarizer_on_a_mono_recording_keeps_the_swift_reason_and_sentinel_DIAR8(tmp_path: Path):
    import numpy as np
    import soundfile as sf

    wav = tmp_path / "20261118-1002.wav"
    sf.write(str(wav), np.zeros(32000, dtype="int16"), 16000, subtype="PCM_16")

    data = _finalize_streamed(wav, _swift_failed_streamed(wav))

    assert data["diarization_failed"] is True
    assert data["diarization_failure_reason"] == "CoreMLError: model failed to load"
    assert data["speaker_fallback"] == "none"
    # Swift's readers know speaker_unknown; a literal `Speaker?` would show up as a person.
    assert [s["speaker"] for s in data["segments"]] == ["speaker_unknown", "speaker_unknown"]
    md = (tmp_path / "20261118-1002.md").read_text(encoding="utf-8")
    assert "no speakers were labeled" in md


def test_finalizing_a_channel_fallback_transcript_twice_keeps_its_labels_without_the_wav_DIAR8(tmp_path: Path):
    wav = tmp_path / "20261118-1003.wav"
    _stereo_wav(wav)
    first = _finalize_streamed(wav, _swift_failed_streamed(wav))
    wav.unlink()  # compressed or removed since

    second = _finalize_streamed(wav, first)

    assert [s["speaker"] for s in second["segments"]] == ["speaker_user", "speaker_other"]
    assert second["speaker_fallback"] == "channel"
    assert second["diarization_failed"] is True


def test_an_unnamed_owner_never_reaches_the_transcript_as_a_digit_UX83(tmp_path: Path, monkeypatch):
    # FluidAudio's ids are "1", "2". With user_label empty the owner used to keep "1" in
    # <stem>.json, <stem>.md and the embeddings sidecar; now it is `speaker_user`, which
    # the Markdown (and so the summarizer's input) renders as "You".
    wav = tmp_path / "20260501-1100.wav"
    wav.write_bytes(b"")
    streamed = _streamed_with_embeddings(
        wav,
        [
            {"start": 0.0, "end": 60.0, "text": "hi", "speaker": "1"},
            {"start": 60.0, "end": 120.0, "text": "hello", "speaker": "2"},
        ],
        {"1": _axis_emb(0), "2": _axis_emb(1)},
    )
    _mic_channel(monkeypatch, ["speaker_user", "speaker_other"])
    out = finalize_streamed_transcript(
        wav, streamed, user_label="",
        voiceprint_store=VoiceprintStore(tmp_path / "vp.json"),
        roster_store=RosterStore(tmp_path / "roster.json"),
    )
    data = json.loads(out["json"].read_text(encoding="utf-8"))
    speakers = [seg["speaker"] for seg in data["segments"]]
    assert speakers == ["speaker_user", "THEM-A"]
    assert not any(s.isdigit() for s in speakers)
    emb = json.loads((tmp_path / "20260501-1100.embeddings.json").read_text())["embeddings"]
    assert set(emb) == {"speaker_user", "THEM-A"}
    assert emb["speaker_user"] == _axis_emb(0)
    md = out["md"].read_text(encoding="utf-8")
    assert "**You**: hi" in md and "speaker_user" not in md and "**1**" not in md
