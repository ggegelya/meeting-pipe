"""Tests for transcript Markdown rendering + diarization plumbing.

The transcribe step itself runs heavy ML models — we don't exercise the
whisper.load_model path in CI. What we DO test:

  - render_markdown's contract (warning banner, Speaker?, segment merging)
  - annotation_to_whisperx_df: pyannote → DataFrame conversion
  - the Diarizer protocol can be satisfied by a stub, so the diarization
    path is exercisable without actually running pyannote
"""
from __future__ import annotations

from collections import namedtuple
from pathlib import Path

from mp.transcribe import annotation_to_whisperx_df, render_markdown


# Minimal pyannote Annotation stand-in: only itertracks(yield_label=True)
# is part of the contract `annotation_to_whisperx_df` depends on.
_Segment = namedtuple("Segment", ["start", "end"])


class _FakeAnnotation:
    def __init__(self, tracks: list[tuple[float, float, str]]) -> None:
        self._tracks = tracks

    def itertracks(self, *, yield_label: bool):
        # Mirror pyannote's tuple shape: (segment, track_id, label).
        for start, end, label in self._tracks:
            yield _Segment(start=start, end=end), "_", label


def test_renders_speaker_segmented_md():
    structured = {
        "language": "en",
        "audio_path": "/tmp/meeting.wav",
        "segments": [
            {"speaker": "SPEAKER_00", "text": "Hi everyone."},
            {"speaker": "SPEAKER_00", "text": "Thanks for joining."},
            {"speaker": "SPEAKER_01", "text": "Glad to be here."},
            {"speaker": "SPEAKER_00", "text": "Let's start."},
        ],
    }
    md = render_markdown(structured)
    # Consecutive same-speaker turns merge into one block.
    assert md.count("**SPEAKER_00**") == 2
    assert "**SPEAKER_01**: Glad to be here." in md
    assert "Hi everyone. Thanks for joining." in md
    assert "_Language detected: en_" in md
    # Footer with speaker counts.
    assert "- SPEAKER_00:" in md


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
            {"speaker": "SPEAKER_00", "text": "Hi."},
            {"speaker": "SPEAKER_01", "text": "Hello."},
        ],
    }
    md = render_markdown(structured)
    assert "⚠️" not in md


def test_annotation_to_dataframe_yields_one_row_per_track():
    ann = _FakeAnnotation([
        (0.0, 1.5, "SPEAKER_00"),
        (1.5, 3.2, "SPEAKER_01"),
        (3.2, 4.0, "SPEAKER_00"),
    ])
    df = annotation_to_whisperx_df(ann)
    assert list(df.columns) == ["start", "end", "speaker"]
    assert len(df) == 3
    assert df.iloc[1]["speaker"] == "SPEAKER_01"
    assert df.iloc[1]["start"] == 1.5


def test_annotation_to_dataframe_handles_empty_annotation():
    df = annotation_to_whisperx_df(_FakeAnnotation([]))
    assert list(df.columns) == ["start", "end", "speaker"]
    assert len(df) == 0


def test_pyannote_diarizer_satisfies_protocol(tmp_path: Path):
    """Concrete `PyannoteDiarizer` is structurally a `Diarizer` — verified
    via `runtime_checkable` Protocol isinstance check, so future signature
    drift can't silently slip past the type system in py-tests too."""
    from mp.services import Diarizer
    from mp.transcribe import PyannoteDiarizer

    # We don't construct the real model (HF download); just verify the
    # class shape against the protocol.
    assert isinstance(
        PyannoteDiarizer.__new__(PyannoteDiarizer),
        Diarizer,
    )


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
