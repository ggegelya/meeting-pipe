"""Tests for transcript Markdown rendering.

The transcribe step itself runs heavy ML models — we don't exercise it in CI.
What we DO test: render_markdown's contract, which determines whether the
summarizer downstream gets a clean, speaker-segmented input.
"""
from __future__ import annotations

from mp.transcribe import render_markdown


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
    structured = {
        "language": "uk",
        "audio_path": "/tmp/x.wav",
        "segments": [{"text": "Hello"}, {"text": "World"}],
    }
    md = render_markdown(structured)
    assert "**Speaker**" in md
    assert "Hello World" in md


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
