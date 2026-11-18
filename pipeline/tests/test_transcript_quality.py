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


# ----- PIPE43: the content floor -----

import pytest  # noqa: E402

from mp import transcript_quality  # noqa: E402
from mp.transcript_quality import below_content_floor  # noqa: E402


def _spread(words: int, span_s: float, per_seg: int = 10) -> list[dict]:
    n = max(1, words // per_seg)
    step = span_s / n
    return [_seg(" ".join(["word"] * per_seg), i * step, (i + 1) * step) for i in range(n)]


@pytest.mark.content_floor
def test_the_floor_thresholds_are_the_owner_confirmed_constants():
    assert transcript_quality._FLOOR_MIN_WORDS == 150
    assert transcript_quality._FLOOR_MIN_SPAN_SEC == 120.0


@pytest.mark.content_floor
def test_a_twenty_second_fragment_is_below_the_floor():
    # The field's 20261009-121708: 20 s, 32 words, summarized into 88 words with actions.
    assert below_content_floor([_seg(" ".join(["w"] * 32), 0.0, 20.0)]) is not None


@pytest.mark.content_floor
def test_a_long_sparse_recording_is_below_the_floor_on_words():
    # 20260923-154340: 2,692 s, 131 words. Long enough on span, too thin on words.
    segs = [_seg(" ".join(["w"] * 131), 0.0, 2692.0)]
    reason = below_content_floor(segs)
    assert reason is not None and "131 words" in reason


@pytest.mark.content_floor
def test_a_real_short_meeting_clears_the_floor():
    assert below_content_floor(_spread(300, 600.0)) is None


@pytest.mark.content_floor
def test_enough_words_in_too_short_a_span_is_below_the_floor():
    reason = below_content_floor(_spread(200, 90.0))
    assert reason is not None and "content floor" in reason


@pytest.mark.content_floor
def test_the_span_is_measured_from_the_first_word_not_from_zero():
    # 200 words between 500 s and 560 s: 60 s of speech, whatever silence preceded it.
    segs = [_seg(" ".join(["w"] * 100), 500.0, 530.0), _seg(" ".join(["w"] * 100), 530.0, 560.0)]
    assert below_content_floor(segs) is not None
