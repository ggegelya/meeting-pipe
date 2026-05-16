"""Tests for transcript Markdown rendering + channel-aware speaker
labelling on the Python fallback path.

The transcribe step itself runs heavy ML models — we don't exercise the
mlx-whisper.transcribe path in CI. Embedding-based diarization lives in
Swift (FluidAudio) and is not covered here. What we DO test:

  - render_markdown's contract (warning banner, Speaker?, segment merging)
  - assign_speakers_by_channel on stereo WAVs
  - Segment normalization preserves the schema downstream consumes
"""
from __future__ import annotations

from pathlib import Path


import numpy as np
import soundfile as sf

from mp.diarize import (
    OTHER_SPEAKER,
    USER_SPEAKER,
    assign_speakers_by_channel,
    is_stereo_recording,
)
from mp.transcribe import _normalize_segment, _resolve_mlx_model_id, render_markdown


# --- render_markdown ---------------------------------------------------------


def test_renders_speaker_segmented_md():
    structured = {
        "language": "en",
        "audio_path": "/tmp/meeting.wav",
        "segments": [
            {"speaker": "speaker_0", "text": "Hi everyone."},
            {"speaker": "speaker_0", "text": "Thanks for joining."},
            {"speaker": "speaker_1", "text": "Glad to be here."},
            {"speaker": "speaker_0", "text": "Let's start."},
        ],
    }
    md = render_markdown(structured)
    # Consecutive same-speaker turns merge into one block.
    assert md.count("**speaker_0**") == 2
    assert "**speaker_1**: Glad to be here." in md
    assert "Hi everyone. Thanks for joining." in md
    assert "_Language detected: en_" in md
    # Footer with speaker counts.
    assert "- speaker_0:" in md


def test_handles_missing_speaker_label():
    """Missing speaker labels render as `Speaker?` — never `Speaker` — so
    a silent diarization failure can't masquerade as a one-person meeting."""
    structured = {
        "language": "uk",
        "audio_path": "/tmp/x.wav",
        "segments": [{"text": "Hello"}, {"text": "World"}],
    }
    md = render_markdown(structured)
    assert "**Speaker?**" in md
    assert "**Speaker**:" not in md
    assert "Hello World" in md


def test_renders_warning_banner_when_diarization_failed():
    structured = {
        "language": "en",
        "audio_path": "/tmp/x.wav",
        "diarization_failed": True,
        "diarization_failure_reason": "RuntimeError: model unavailable",
        "segments": [{"text": "Solo voice."}],
    }
    md = render_markdown(structured)
    assert "⚠️ Diarization failed" in md
    assert "RuntimeError: model unavailable" in md
    assert "**Speaker?**: Solo voice." in md


def test_no_warning_banner_on_successful_diarization():
    structured = {
        "language": "en",
        "audio_path": "/tmp/x.wav",
        "diarization_failed": False,
        "segments": [
            {"speaker": "speaker_0", "text": "Hi."},
            {"speaker": "speaker_1", "text": "Hello."},
        ],
    }
    md = render_markdown(structured)
    assert "⚠️" not in md


def test_skips_empty_segments():
    structured = {
        "language": "en",
        "audio_path": "/tmp/x.wav",
        "segments": [
            {"speaker": "A", "text": ""},
            {"speaker": "A", "text": "  "},
            {"speaker": "A", "text": "Real content."},
        ],
    }
    md = render_markdown(structured)
    assert "Real content." in md


# --- Channel-aware speaker assignment ----------------------------------------


def _write_stereo_wav(path, *, sr=16000, l_segments=None, r_segments=None, total_seconds=10):
    """Build a stereo WAV with explicit speech regions on each channel.
    `l_segments` / `r_segments` are lists of (start_sec, end_sec) intervals
    where the named channel has loud-ish content; everywhere else is
    silence. Used to validate the per-segment energy comparison."""
    n = sr * total_seconds
    L = np.zeros(n, dtype=np.float32)
    R = np.zeros(n, dtype=np.float32)
    rng = np.random.default_rng(42)
    for s, e in (l_segments or []):
        L[int(s * sr):int(e * sr)] = rng.standard_normal(int((e - s) * sr)).astype(np.float32) * 0.3
    for s, e in (r_segments or []):
        R[int(s * sr):int(e * sr)] = rng.standard_normal(int((e - s) * sr)).astype(np.float32) * 0.3
    interleaved = np.stack([L, R], axis=1)
    sf.write(str(path), interleaved, sr, subtype="PCM_16")


def test_is_stereo_recording_detects_channel_count(tmp_path):
    mono = tmp_path / "mono.wav"
    sf.write(str(mono), np.zeros(16000, dtype=np.float32), 16000, subtype="PCM_16")
    assert is_stereo_recording(mono) is False

    stereo = tmp_path / "stereo.wav"
    sf.write(str(stereo), np.zeros((16000, 2), dtype=np.float32), 16000, subtype="PCM_16")
    assert is_stereo_recording(stereo) is True


def test_is_stereo_recording_returns_false_on_missing_file(tmp_path):
    """Defensive: probing a path that doesn't exist must NOT crash —
    a transient race or rename mid-pipeline shouldn't kill the run."""
    assert is_stereo_recording(tmp_path / "absent.wav") is False


def test_assign_speakers_by_channel_labels_by_dominant_side(tmp_path):
    """The whole point: when L is loud and R is silent during a segment,
    the segment belongs to USER_SPEAKER (mic). Inverse for OTHER."""
    wav = tmp_path / "stereo.wav"
    _write_stereo_wav(
        wav,
        l_segments=[(0.0, 2.0), (4.0, 5.0)],   # user talks 0-2 and 4-5
        r_segments=[(2.0, 4.0)],                # other talks 2-4
        total_seconds=6,
    )
    transcript = [
        {"start": 0.0, "end": 2.0, "text": "Hi, how are you?"},
        {"start": 2.0, "end": 4.0, "text": "Doing well, thanks."},
        {"start": 4.0, "end": 5.0, "text": "Great."},
    ]
    out = assign_speakers_by_channel(transcript, wav)
    assert [s["speaker"] for s in out] == [USER_SPEAKER, OTHER_SPEAKER, USER_SPEAKER]


def test_assign_speakers_by_channel_collapses_to_user_when_other_side_silent(tmp_path):
    """When the right channel has no real audio at all (system audio
    capture failed), every segment must collapse to USER_SPEAKER. The
    May 5 18:30 recording's failure mode produced 5 spurious 'others'
    saying 'okay' / 'Mm-hmm' from background noise — this is the guard."""
    wav = tmp_path / "stereo_no_system.wav"
    _write_stereo_wav(
        wav,
        l_segments=[(0.0, 5.0)],  # only the user speaks
        r_segments=[],             # right channel is bone silent
        total_seconds=6,
    )
    transcript = [
        {"start": 0.0, "end": 1.0, "text": "Hello."},
        {"start": 1.0, "end": 2.0, "text": "Are you there?"},
        {"start": 3.0, "end": 4.0, "text": "Hmm."},  # backchannel — must NOT become "other"
    ]
    out = assign_speakers_by_channel(transcript, wav)
    assert all(s["speaker"] == USER_SPEAKER for s in out)


def test_assign_speakers_by_channel_handles_overlap(tmp_path):
    """When both speakers are talking simultaneously (both channels
    loud), pick whichever is louder. Either label is acceptable;
    we just refuse to crash or drop the segment."""
    wav = tmp_path / "overlap.wav"
    sr = 16000
    n = sr * 4
    rng = np.random.default_rng(7)
    L = rng.standard_normal(n).astype(np.float32) * 0.3
    R = rng.standard_normal(n).astype(np.float32) * 0.4  # right slightly louder
    sf.write(str(wav), np.stack([L, R], axis=1), sr, subtype="PCM_16")

    transcript = [{"start": 1.0, "end": 3.0, "text": "Both talking."}]
    out = assign_speakers_by_channel(transcript, wav)
    assert out[0]["speaker"] in (USER_SPEAKER, OTHER_SPEAKER)


def test_assign_speakers_by_channel_does_not_mutate_input(tmp_path):
    wav = tmp_path / "stereo.wav"
    _write_stereo_wav(wav, l_segments=[(0.0, 1.0)], r_segments=[], total_seconds=2)
    transcript = [{"start": 0.0, "end": 1.0, "text": "Hi."}]
    out = assign_speakers_by_channel(transcript, wav)
    assert "speaker" not in transcript[0]
    assert out[0] is not transcript[0]


def test_assign_speakers_by_channel_falls_back_on_mono_input(tmp_path):
    """The transcribe.py wrapper guards against this with is_stereo_
    recording, but defense-in-depth: a mono file passed in directly
    must not raise — fall back to USER_SPEAKER for every segment."""
    wav = tmp_path / "mono.wav"
    sf.write(str(wav), np.zeros(16000, dtype=np.float32), 16000, subtype="PCM_16")
    transcript = [{"start": 0.0, "end": 1.0, "text": "Hello."}]
    out = assign_speakers_by_channel(transcript, wav)
    assert out[0]["speaker"] == USER_SPEAKER


# --- MLX model resolver -------------------------------------------------------


def test_resolve_mlx_model_id_passes_full_repo_through():
    """A `mlx-community/...` HuggingFace repo must round-trip unchanged
    so users who set the canonical name keep getting exactly that model."""
    assert _resolve_mlx_model_id("mlx-community/whisper-large-v3-turbo") == "mlx-community/whisper-large-v3-turbo"
    assert _resolve_mlx_model_id("mlx-community/whisper-medium") == "mlx-community/whisper-medium"


def test_resolve_mlx_model_id_maps_legacy_names_to_real_mlx_repos():
    """Pre-Tier-1 configs used bare faster-whisper names — those have to
    map to the ACTUAL published mlx-community repos (not a naive prefix).
    `large-v3` notably routes to `-turbo` since the mlx-community repo
    only ships the distilled / smaller variants under explicit names;
    `mlx-community/whisper-large-v3` does NOT exist and was the bug
    that made the previous fix's auto-prefix produce 404s in the wild."""
    assert _resolve_mlx_model_id("large-v3") == "mlx-community/whisper-large-v3-turbo"
    assert _resolve_mlx_model_id("large-v3-turbo") == "mlx-community/whisper-large-v3-turbo"
    assert _resolve_mlx_model_id("large-v2") == "mlx-community/whisper-large-v2-mlx"
    assert _resolve_mlx_model_id("medium") == "mlx-community/whisper-medium-mlx"
    assert _resolve_mlx_model_id("medium.en") == "mlx-community/whisper-medium.en-mlx"
    assert _resolve_mlx_model_id("tiny.en") == "mlx-community/whisper-tiny.en-mlx"


def test_resolve_mlx_model_id_falls_back_to_naive_prefix_for_unknown_names():
    """Future Whisper variants we haven't enumerated should still be
    reachable by setting `model = "<name>"`; mlx-whisper's own 404 path
    surfaces a real typo. This is the escape hatch we keep open."""
    assert _resolve_mlx_model_id("hypothetical-future-variant") == "mlx-community/whisper-hypothetical-future-variant"


def test_resolve_mlx_model_id_passes_local_paths_through():
    """A user pointing at a locally-converted MLX directory should not
    be silently rerouted to HuggingFace."""
    assert _resolve_mlx_model_id("~/models/whisper-custom") == "~/models/whisper-custom"
    assert _resolve_mlx_model_id("./local-model") == "./local-model"


def test_resolve_mlx_model_id_falls_back_to_default_on_empty():
    """Defensive: an empty config value shouldn't propagate to mlx-whisper
    as the empty string."""
    assert _resolve_mlx_model_id("") == "mlx-community/whisper-large-v3-turbo"
    assert _resolve_mlx_model_id("   ") == "mlx-community/whisper-large-v3-turbo"


# --- Segment normalization ----------------------------------------------------


def test_normalize_segment_preserves_words_when_present():
    raw = {
        "start": 0.5,
        "end": 1.5,
        "text": " Hi there. ",
        "words": [
            {"word": "Hi", "start": 0.5, "end": 0.8},
            {"word": "there.", "start": 0.9, "end": 1.5},
        ],
    }
    out = _normalize_segment(raw)
    assert out["text"] == "Hi there."
    assert len(out["words"]) == 2
    assert out["words"][0]["word"] == "Hi"
    assert out["words"][0]["start"] == 0.5


def test_normalize_segment_drops_words_when_absent():
    raw = {"start": 0.0, "end": 1.0, "text": "No words list."}
    out = _normalize_segment(raw)
    assert "words" not in out
    assert out["text"] == "No words list."


def test_normalize_segment_handles_missing_word_timings():
    """Some Whisper outputs return word entries without `start`/`end`
    (e.g. silence padding). They should fall back to the segment-level
    boundaries instead of crashing."""
    raw = {
        "start": 1.0,
        "end": 2.0,
        "text": "Edge case.",
        "words": [{"word": "Edge"}, {"word": "case."}],
    }
    out = _normalize_segment(raw)
    assert all(w["start"] == 1.0 and w["end"] == 2.0 for w in out["words"])


# --- Anti-loop kwargs --------------------------------------------------------


def test_mlx_anti_loop_kwargs_block_repetition_hallucination():
    """Locks in the four flags that prevent the Whisper repetition
    loop on long silences (e.g. the Teams test-call beep gaps)."""
    from mp.transcribe import _MLX_ANTI_LOOP_KWARGS

    # condition_on_previous_text=False is the load-bearing one. Without
    # it Whisper feeds its own prior output back as context and any
    # hallucinated phrase snowballs.
    assert _MLX_ANTI_LOOP_KWARGS["condition_on_previous_text"] is False

    # The newer dedicated knob: drop text the decoder would have
    # produced over silent stretches longer than 2 s.
    assert _MLX_ANTI_LOOP_KWARGS["hallucination_silence_threshold"] == 2.0

    # compression_ratio + no_speech thresholds match Whisper's documented
    # defaults; we set them explicitly so a future config change is one
    # grep away.
    assert _MLX_ANTI_LOOP_KWARGS["compression_ratio_threshold"] == 2.4
    assert _MLX_ANTI_LOOP_KWARGS["no_speech_threshold"] == 0.6


def test_mlx_call_site_forwards_anti_loop_kwargs(monkeypatch):
    """The constant has to actually reach mlx_whisper.transcribe; if a
    refactor drops the spread, this test catches it."""
    import sys
    import types

    captured: dict = {}

    fake = types.ModuleType("mlx_whisper")

    def fake_transcribe(_audio, **kwargs):
        captured.update(kwargs)
        return {"language": "en", "segments": []}

    fake.transcribe = fake_transcribe  # type: ignore[attr-defined]
    monkeypatch.setitem(sys.modules, "mlx_whisper", fake)

    from mp.transcribe import _MLX_ANTI_LOOP_KWARGS, _run_mlx

    class _TCfg:
        model = "mlx-community/whisper-large-v3-turbo"
        language = "auto"

    _run_mlx(Path("/tmp/fake.wav"), _TCfg())

    for key, value in _MLX_ANTI_LOOP_KWARGS.items():
        assert captured.get(key) == value, f"{key} not forwarded to mlx_whisper.transcribe"
