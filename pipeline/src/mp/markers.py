"""Flagged-moment markers (FEAT8): the read side of `<stem>.markers.json`.

The daemon stamps a marker each time the user presses the flag hotkey during a
recording and flushes them to `<stem>.markers.json` at stop. Here we turn those
offsets into user-flagged excerpts: for each marker, the transcript segment
spanning it. Capture is deterministic (no model); the summarizer just receives
the excerpts plus a trusted instruction to reflect them, and the BYO / long-
meeting paste bundles list them too.

Fail-open throughout: a missing or malformed sidecar yields nothing, so an
unflagged meeting is unaffected.
"""
from __future__ import annotations

import json
from pathlib import Path

# The trusted instruction that points the model at the excerpts. Lives in the
# system prompt; the excerpts themselves ride in the (untrusted) transcript
# under this heading.
_HEADING = "### User-flagged moments"
FLAGGED_INSTRUCTION = (
    "During the meeting the person recording flagged specific moments as "
    'important; they appear under a "User-flagged moments" heading appended to '
    "the transcript. Make sure the summary clearly reflects what was discussed "
    "at those flagged moments."
)

_MAX_MOMENTS = 25
_MAX_EXCERPT_CHARS = 300


def flagged_moments_block(transcript_md: Path) -> str | None:
    """The user-flagged excerpts for this meeting as a markdown block, or None.

    Reads `<stem>.markers.json` (flag offsets) and the finalized `<stem>.json`
    (segments), and for each marker takes the spanning segment's text (deduped,
    in time order, bounded). Returns None when there are no markers, no
    segments, or nothing readable.
    """
    stem = transcript_md.name.split(".", 1)[0]
    parent = transcript_md.parent
    offsets = _read_marker_offsets(parent / f"{stem}.markers.json")
    if not offsets:
        return None
    segments = _read_segments(parent / f"{stem}.json")
    if not segments:
        return None

    seen: set[int] = set()
    lines: list[str] = []
    for t in sorted(offsets)[:_MAX_MOMENTS]:
        idx = _segment_index_at(t, segments)
        if idx is None or idx in seen:
            continue
        seen.add(idx)
        text = str(segments[idx].get("text") or "").strip()
        if not text:
            continue
        if len(text) > _MAX_EXCERPT_CHARS:
            text = text[: _MAX_EXCERPT_CHARS - 3].rstrip() + "..."
        lines.append(f"- [{_mmss(t)}] {text}")
    if not lines:
        return None
    return (
        f"{_HEADING}\n"
        "The person recording flagged these moments as important:\n"
        + "\n".join(lines)
    )


def _read_marker_offsets(path: Path) -> list[float]:
    try:
        obj = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    if not isinstance(obj, dict):
        return []
    out: list[float] = []
    for m in obj.get("markers", []):
        t = m.get("t_seconds") if isinstance(m, dict) else None
        if isinstance(t, (int, float)) and not isinstance(t, bool):
            out.append(float(t))
    return out


def _read_segments(path: Path) -> list[dict]:
    try:
        obj = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    segs = obj.get("segments") if isinstance(obj, dict) else None
    return segs if isinstance(segs, list) else []


def _segment_index_at(t: float, segments: list[dict]) -> int | None:
    """Index of the segment spanning `t` (start <= t < end); else the last one
    starting at or before `t`; else the first."""
    best: int | None = None
    for i, s in enumerate(segments):
        start = s.get("start")
        if not isinstance(start, (int, float)):
            continue
        end = s.get("end")
        if isinstance(end, (int, float)) and start <= t < end:
            return i
        if start <= t:
            best = i
    if best is not None:
        return best
    return 0 if segments else None


def _mmss(t: float) -> str:
    total = int(t)
    h, rem = divmod(total, 3600)
    m, s = divmod(rem, 60)
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m}:{s:02d}"
