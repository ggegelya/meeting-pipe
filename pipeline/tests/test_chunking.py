"""Tests for the transcript chunking primitive (TECH-SUM1-PRIMITIVE)."""
from __future__ import annotations

import pytest

from mp.chunking import _CARRY_HEADER, ChunkedWindow, chunked_windows


def _transcript(word_count: int, prefix: str = "w") -> str:
    """A transcript of uniquely-identifiable space-separated words."""
    return " ".join(f"{prefix}{i}" for i in range(word_count))


def test_sixty_minute_transcript_makes_about_four_windows() -> None:
    # ~30k chars (a 60-minute meeting) at max_chars=8000 with 200 overlap
    # should land near four windows per the acceptance bar.
    transcript = "lorem ipsum dolor sit amet " * 1100  # ~30k chars
    assert len(transcript) > 29000
    windows = list(chunked_windows(transcript, max_chars=8000, overlap_chars=200))
    assert len(windows) == 4
    assert all(len(w.text) <= 8000 for w in windows)
    assert windows[0].is_first and not windows[0].is_last
    assert windows[-1].is_last and not windows[-1].is_first


def test_every_word_appears_in_at_least_one_window() -> None:
    transcript = _transcript(2000)
    original_words = set(transcript.split())
    windows = list(chunked_windows(transcript, max_chars=200, overlap_chars=20))
    covered: set[str] = set()
    for w in windows:
        covered.update(w.text.split())
    # Subset, not equality: overlap regions can begin mid-word and so
    # contribute leading fragments, but every full word is guaranteed to
    # appear in at least one window.
    assert original_words.issubset(covered)


def test_consecutive_windows_overlap() -> None:
    transcript = _transcript(2000)
    windows = list(chunked_windows(transcript, max_chars=200, overlap_chars=40))
    assert len(windows) > 1
    # The start of each window after the first lies inside its predecessor:
    # the overlap region is shared text, not a fresh cut.
    for prev, nxt in zip(windows, windows[1:]):
        assert nxt.text[:10] in prev.text


def test_carry_summary_prepended_only_when_supplied() -> None:
    transcript = _transcript(500)
    without = list(chunked_windows(transcript, max_chars=200, overlap_chars=20))
    assert all(_CARRY_HEADER not in w.prompt for w in without)
    assert all(w.prompt == w.text for w in without)

    carry = "Earlier: the team agreed to ship Friday."
    withcarry = list(
        chunked_windows(transcript, max_chars=200, overlap_chars=20, carry_summary=carry)
    )
    assert all(w.prompt.startswith(_CARRY_HEADER) for w in withcarry)
    assert all(carry in w.prompt for w in withcarry)
    # text itself is never mutated by the carry injection.
    assert all(carry not in w.text for w in withcarry)


def test_empty_transcript_yields_no_windows() -> None:
    assert list(chunked_windows("", max_chars=100)) == []


def test_short_transcript_is_single_window() -> None:
    windows = list(chunked_windows("just a few words", max_chars=8000))
    assert len(windows) == 1
    only = windows[0]
    assert only.is_first and only.is_last
    assert only.text == "just a few words"
    assert only.index == 0


def test_non_positive_max_chars_raises() -> None:
    with pytest.raises(ValueError):
        list(chunked_windows("anything", max_chars=0))


def test_overlap_clamped_below_max_chars() -> None:
    # An overlap >= max_chars would stall; it must be clamped so the
    # window still advances and the transcript is fully covered.
    transcript = _transcript(300)
    windows = list(chunked_windows(transcript, max_chars=50, overlap_chars=999))
    covered: set[str] = set()
    for w in windows:
        covered.update(w.text.split())
    assert set(transcript.split()).issubset(covered)


def test_window_is_frozen() -> None:
    w = ChunkedWindow(index=0, text="x", is_first=True, is_last=True)
    with pytest.raises(Exception):
        w.text = "y"  # type: ignore[misc]
