"""Transcript chunking primitive.

Splits a long transcript into LLM-context-fitting windows with a
configurable character budget and overlap. Shared by the diarization
cleanup pass (`diarize_cleanup.py`) and the Apple Intelligence summarizer
(which carries a Swift mirror of this same algorithm). Keep the two in
sync; `TranscriptChunkerTests` in the daemon pins the parity.

Coverage contract: every word of the input appears in at least one
window. Windows end on whitespace boundaries (so a word is never split
across an end boundary), and consecutive windows overlap by
``overlap_chars``, so a word that the overlap region begins mid-way
through still has its full form in the preceding window. The single
exception is a token longer than ``max_chars`` (no whitespace to break
on); such a token is hard-split, which real transcripts do not contain.
"""
from __future__ import annotations

from collections.abc import Iterator
from dataclasses import dataclass

# Prefix used when a carry summary is injected, kept identical to the
# Swift mirror so both backends send the model the same framing.
_CARRY_HEADER = "Context from earlier in the meeting:"


@dataclass(frozen=True)
class ChunkedWindow:
    """One window of the transcript.

    ``text`` is the raw slice. ``prompt`` is what a caller sends to the
    model: identical to ``text`` unless a ``carry_summary`` was supplied,
    in which case the summary is prepended as context.
    """

    index: int
    text: str
    is_first: bool
    is_last: bool
    carry_summary: str | None = None

    @property
    def prompt(self) -> str:
        if self.carry_summary:
            return f"{_CARRY_HEADER}\n{self.carry_summary}\n\n{self.text}"
        return self.text


def _last_whitespace_break(text: str, end: int, start: int) -> int | None:
    """Index of the last whitespace char in ``text[start:end]``, or None
    when the window holds no whitespace (a single oversized token)."""
    i = end - 1
    while i > start:
        if text[i].isspace():
            return i
        i -= 1
    return None


def chunked_windows(
    transcript: str,
    max_chars: int,
    overlap_chars: int = 200,
    carry_summary: str | None = None,
) -> Iterator[ChunkedWindow]:
    """Yield overlapping windows of ``transcript``, each at most
    ``max_chars`` characters.

    ``overlap_chars`` is the target overlap between consecutive windows;
    it is clamped to ``max_chars - 1`` so progress is always possible.
    When ``carry_summary`` is supplied it is exposed on each window's
    ``prompt`` (never mutating ``text``).
    """
    if max_chars <= 0:
        raise ValueError("max_chars must be positive")

    n = len(transcript)
    if n == 0:
        return

    overlap = max(0, min(overlap_chars, max_chars - 1))

    start = 0
    index = 0
    while start < n:
        end = min(n, start + max_chars)
        if end < n:
            snap = _last_whitespace_break(transcript, end, start)
            if snap is not None:
                end = snap
        is_last = end >= n
        yield ChunkedWindow(
            index=index,
            text=transcript[start:end],
            is_first=index == 0,
            is_last=is_last,
            carry_summary=carry_summary,
        )
        if is_last:
            return
        index += 1
        # Advance by the step, keeping the requested overlap. max() guards
        # the pathological case where end snapped back near start, which
        # would otherwise stall or rewind.
        start = max(start + 1, end - overlap)
