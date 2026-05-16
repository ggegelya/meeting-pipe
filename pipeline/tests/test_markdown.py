"""Tests for transcript Markdown rendering + channel-aware speaker
labelling.

ASR + diarization run in Swift (FluidAudio); this module only renders
markdown from the daemon-written sidecar and labels speakers by channel
when FluidAudio diarization didn't land. Tests cover:

  - render_markdown's contract (warning banner, Speaker?, segment merging)
  - assign_speakers_by_channel on stereo WAVs
"""
from __future__ import annotations

import numpy as np
import soundfile as sf

from mp.diarize import (
    OTHER_SPEAKER,
    USER_SPEAKER,
    assign_speakers_by_channel,
    is_stereo_recording,
)
from mp.markdown import render_markdown


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
    """Missing speaker labels render as `Speaker?`, never as `Speaker`,
    so a silent diarization failure can't masquerade as a one-person
    meeting."""
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
    assert "Diarization failed" in md
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
    assert "Diarization failed" not in md


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
    """Defensive: probing a path that doesn't exist must NOT crash; a
    transient race or rename mid-pipeline shouldn't kill the run."""
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
    capture failed), every segment must collapse to USER_SPEAKER."""
    wav = tmp_path / "stereo_no_system.wav"
    _write_stereo_wav(
        wav,
        l_segments=[(0.0, 5.0)],
        r_segments=[],
        total_seconds=6,
    )
    transcript = [
        {"start": 0.0, "end": 1.0, "text": "Hello."},
        {"start": 1.0, "end": 2.0, "text": "Are you there?"},
        {"start": 3.0, "end": 4.0, "text": "Hmm."},
    ]
    out = assign_speakers_by_channel(transcript, wav)
    assert all(s["speaker"] == USER_SPEAKER for s in out)


def test_assign_speakers_by_channel_handles_overlap(tmp_path):
    """When both speakers are talking simultaneously (both channels
    loud), pick whichever is louder. Either label is acceptable; we just
    refuse to crash or drop the segment."""
    wav = tmp_path / "overlap.wav"
    sr = 16000
    n = sr * 4
    rng = np.random.default_rng(7)
    L = rng.standard_normal(n).astype(np.float32) * 0.3
    R = rng.standard_normal(n).astype(np.float32) * 0.4
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
    """Mono input passed in directly must not raise; fall back to
    USER_SPEAKER for every segment."""
    wav = tmp_path / "mono.wav"
    sf.write(str(wav), np.zeros(16000, dtype=np.float32), 16000, subtype="PCM_16")
    transcript = [{"start": 0.0, "end": 1.0, "text": "Hello."}]
    out = assign_speakers_by_channel(transcript, wav)
    assert out[0]["speaker"] == USER_SPEAKER
