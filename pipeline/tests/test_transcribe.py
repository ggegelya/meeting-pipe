"""Tests for transcript Markdown rendering + speaker assignment.

The transcribe step itself runs heavy ML models — we don't exercise the
mlx-whisper.transcribe / sherpa-onnx paths in CI. What we DO test:

  - render_markdown's contract (warning banner, Speaker?, segment merging)
  - assign_speakers: midpoint match, closest-fallback, empty diarization
  - Segment normalization preserves the schema downstream consumes
"""
from __future__ import annotations

from pathlib import Path

from mp.diarize import DiarizationSegment, _renumber_speakers, assign_speakers
from mp.transcribe import _normalize_segment, render_markdown


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


# --- assign_speakers ----------------------------------------------------------


def test_assign_speakers_midpoint_match():
    """Each transcript segment's midpoint is matched against the
    diarization timeline; the speaker label flows through verbatim."""
    transcript = [
        {"start": 0.0, "end": 2.0, "text": "Hi."},
        {"start": 2.0, "end": 5.0, "text": "How are you?"},
        {"start": 5.0, "end": 8.0, "text": "Fine, thanks."},
    ]
    diar = [
        DiarizationSegment(start=0.0, end=2.5, speaker="speaker_0"),
        DiarizationSegment(start=2.5, end=6.0, speaker="speaker_1"),
        DiarizationSegment(start=6.0, end=10.0, speaker="speaker_0"),
    ]
    out = assign_speakers(transcript, diar)
    assert out[0]["speaker"] == "speaker_0"  # midpoint 1.0 in [0, 2.5]
    assert out[1]["speaker"] == "speaker_1"  # midpoint 3.5 in [2.5, 6.0]
    assert out[2]["speaker"] == "speaker_0"  # midpoint 6.5 in [6.0, 10.0]


def test_assign_speakers_falls_back_to_closest():
    """When a transcript segment's midpoint sits in a tiny gap between
    diarization segments, we attach to the nearest by edge distance
    instead of dropping the speaker label."""
    transcript = [{"start": 5.0, "end": 5.5, "text": "Quick interjection."}]
    diar = [
        DiarizationSegment(start=0.0, end=4.0, speaker="speaker_0"),
        DiarizationSegment(start=6.0, end=10.0, speaker="speaker_1"),
    ]
    out = assign_speakers(transcript, diar)
    # Midpoint 5.25 is closer to speaker_1's start at 6.0 (distance 0.75)
    # than speaker_0's end at 4.0 (distance 1.25).
    assert out[0]["speaker"] == "speaker_1"


def test_assign_speakers_empty_diarization_marks_unknown():
    """When diarization produced nothing, every segment gets the
    fallback label so the failure is visible in downstream Markdown."""
    transcript = [{"start": 0.0, "end": 1.0, "text": "Hi."}]
    out = assign_speakers(transcript, [])
    assert out[0]["speaker"] == "Speaker?"


def test_assign_speakers_does_not_mutate_input():
    """Callers reuse the transcript list elsewhere — assign_speakers must
    return new dicts rather than tagging speakers onto the originals."""
    transcript = [{"start": 0.0, "end": 1.0, "text": "Hi."}]
    diar = [DiarizationSegment(start=0.0, end=1.0, speaker="speaker_0")]
    out = assign_speakers(transcript, diar)
    assert "speaker" not in transcript[0]
    assert out[0] is not transcript[0]


# --- Speaker renumbering ------------------------------------------------------


def test_renumber_speakers_makes_ids_contiguous():
    """sherpa-onnx hands back IDs from internal cluster numbers — they
    can have gaps (`speaker_0, speaker_4, speaker_22`). Downstream
    rendering and the Anthropic prompt look weird with those gaps, so
    we renumber in order of first appearance."""
    segs = [
        DiarizationSegment(start=0.0, end=1.0, speaker="speaker_4"),
        DiarizationSegment(start=1.0, end=2.0, speaker="speaker_22"),
        DiarizationSegment(start=2.0, end=3.0, speaker="speaker_4"),
        DiarizationSegment(start=3.0, end=4.0, speaker="speaker_0"),
    ]
    out = _renumber_speakers(segs)
    # First appearance: speaker_4 → 0, speaker_22 → 1, speaker_0 → 2.
    assert [s.speaker for s in out] == ["speaker_0", "speaker_1", "speaker_0", "speaker_2"]
    # Timing fields untouched.
    assert out[1].start == 1.0 and out[1].end == 2.0


def test_renumber_speakers_preserves_already_contiguous_ids():
    """A well-numbered input must round-trip unchanged."""
    segs = [
        DiarizationSegment(start=0.0, end=1.0, speaker="speaker_0"),
        DiarizationSegment(start=1.0, end=2.0, speaker="speaker_1"),
    ]
    out = _renumber_speakers(segs)
    assert [s.speaker for s in out] == ["speaker_0", "speaker_1"]


def test_renumber_speakers_empty_input():
    assert _renumber_speakers([]) == []


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
