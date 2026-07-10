"""Cheap degenerate-transcript checks (LOCAL2 / AUD-21).

The Swift daemon's FluidAudio transcript is the pipeline's only input. When ASR
fails on real audio it does not raise: it emits garbage, a decoder stuck on one
phrase, or near-empty output over a long recording. Summarizing that burns a
model call and publishes nonsense. These pure checks let the orchestrator mark
such a run "transcript suspect" and skip it, the way it already skips genuinely
silent audio. Conservative by design: only clearly degenerate output is flagged,
so a real meeting is never withheld.
"""
from __future__ import annotations

# n-gram window for the repetition check. Long enough that natural speech rarely
# repeats a whole window verbatim, short enough to catch a looping decoder.
_REP_NGRAM = 10
# Below this many words the repetition ratio is too noisy to judge; a short note
# is left alone.
_REP_MIN_WORDS = 60
# Flag when fewer than this fraction of n-gram windows are distinct. A looping
# decoder drives the ratio toward 0; natural speech sits well above 0.7, so 0.2
# leaves a wide margin against false positives.
_REP_MIN_DISTINCT_RATIO = 0.2
# Only apply the words-per-minute floor to recordings at least this long; a short
# quiet clip is plausibly sparse.
_WPM_MIN_DURATION_SEC = 300.0
# Below this words-per-minute over a long recording the transcription almost
# certainly failed (real speech runs 100-150 wpm; 2 wpm is ~10 words in 5 min).
_WPM_FLOOR = 2.0


def _segment_text(segments: list[dict]) -> str:
    return " ".join((seg.get("text") or "").strip() for seg in segments).strip()


def _duration_sec(segments: list[dict]) -> float:
    # Filter the extracted value, not the dict: `isinstance(seg.get("end"), ...)`
    # narrows nothing about the value the comprehension goes on to collect.
    ends = [e for e in (seg.get("end") for seg in segments) if isinstance(e, (int, float))]
    return float(max(ends)) if ends else 0.0


def _distinct_ngram_ratio(words: list[str], n: int) -> float:
    if len(words) < n:
        return 1.0
    grams = [tuple(words[i:i + n]) for i in range(len(words) - n + 1)]
    return len(set(grams)) / len(grams)


def transcript_issues(segments: list[dict]) -> list[str]:
    """Reasons the transcript looks degenerate, or [] if it looks usable.

    Operates on the structured segments so it sees both text and timing. The
    caller has already ruled out the no-segments (silent) case.
    """
    text = _segment_text(segments)
    if not text:
        return ["transcript has segments but no spoken text"]

    issues: list[str] = []
    words = text.split()
    if len(words) >= _REP_MIN_WORDS:
        ratio = _distinct_ngram_ratio(words, _REP_NGRAM)
        if ratio < _REP_MIN_DISTINCT_RATIO:
            issues.append(
                f"only {ratio:.0%} of {_REP_NGRAM}-word windows are distinct "
                "(a looping or stuck transcription)"
            )

    duration = _duration_sec(segments)
    if duration >= _WPM_MIN_DURATION_SEC:
        wpm = len(words) / (duration / 60.0)
        if wpm < _WPM_FLOOR:
            issues.append(
                f"{len(words)} words across {duration / 60:.0f} min "
                f"({wpm:.1f} words/min) is far below real speech"
            )
    return issues
