"""Tests for the degenerate-transcript guard (LOCAL2 / AUD-21).

Conservative by design: the guard must catch a looping decoder and a near-empty
long recording, but never withhold a real (even sparse) meeting.
"""
from __future__ import annotations

from mp.transcript_quality import transcript_issues


def _seg(text: str, start: float = 0.0, end: float = 1.0) -> dict:
    return {"start": start, "end": end, "text": text, "speaker": "speaker_0"}


def test_clean_transcript_has_no_issues():
    segs = [
        _seg(f"point number {i} about the roadmap budget and the hiring plan", i, i + 1)
        for i in range(80)
    ]
    assert transcript_issues(segs) == []


def test_segments_present_but_no_spoken_text_is_flagged():
    issues = transcript_issues([_seg("", 0, 1), _seg("   ", 1, 2)])
    assert issues and "no spoken text" in issues[0]


def test_looping_decoder_is_flagged():
    # The same short phrase repeated is the classic stuck-decoder garbage.
    segs = [_seg("thank you so much", i, i + 1) for i in range(200)]
    assert any("distinct" in issue for issue in transcript_issues(segs))


def test_near_empty_over_a_long_recording_is_flagged():
    # A handful of words across ten minutes is a failed transcription.
    segs = [_seg("hello", 0.0, 1.0), _seg("are you there", 600.0, 601.0)]
    assert any("words/min" in issue for issue in transcript_issues(segs))


def test_short_sparse_clip_is_not_flagged():
    # The words-per-minute floor only applies to long recordings, so a brief
    # quiet clip must not be withheld.
    assert transcript_issues([_seg("quick note", 0.0, 30.0)]) == []
