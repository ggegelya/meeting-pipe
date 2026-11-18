"""Read + apply the daemon's reversible transcript text-correction overlay (PIPE9).

`<stem>.transcript_corrections.json` is written by the Swift daemon
(`TranscriptCorrectionStore`) when the user edits a transcript line in the
Library. Like the speaker-label overlay it is a display overlay the daemon
resolves at load time, so the on-disk `<stem>.json` keeps the pipeline's original
text. This module lets the pipeline apply the same edits when it re-reads a
transcript (regenerate a summary, build the `mp ask` embedding index), so those
consumers stop running on text the Library no longer shows.

The resolution matches the Swift side exactly (a Swift-to-Python contract, like
the speaker overlay): for each segment, a correction at that segment's array
index replaces the segment text with its `edited_text`, else the text is left
as-is. ASR12: only when the correction's `original_text` is still what that
segment says (compared after trimming outer whitespace, which is the text Swift's
`TranscriptLoader.parse` hands its own check). An entry whose original no longer
matches has drifted (the transcript was rewritten under it, so its index points
at another sentence) and is skipped, never deleted, so a later carry can still
recover it. An entry without `original_text` is ignored, as Swift's reader does. The index is the position in the `<stem>.json` `segments` array, the same
zero-based `enumerate` convention `SpeakerLabelStore` / `TranscriptTab.parse`
use.

`overlaid_markdown` is the composed transcript view: it applies the speaker-label
overlay (`speaker_overlay`) AND these text corrections, so a single call resolves
everything the Library shows. Corrections are the outer layer, so this module
owns the composition and depends on `speaker_overlay`, not the other way round.

Schema mirror of Swift's `TranscriptCorrectionStore`:
`{ "schema_version": 1, "segments": [ { "index": N, "original_text": "...", "edited_text": "..." }, ... ] }`.
"""
from __future__ import annotations

import logging
from pathlib import Path
from typing import NamedTuple

from . import storage

SCHEMA_VERSION = 1

log = logging.getLogger("mp.transcript_corrections")


class Correction(NamedTuple):
    """One entry of the sidecar: what the pipeline said when the line was edited,
    and what the owner edited it to."""

    original_text: str
    edited_text: str


def corrections_path(transcript_md: Path) -> Path:
    return transcript_md.parent / f"{transcript_md.stem}.transcript_corrections.json"


def read_corrections(transcript_md: Path) -> dict[int, Correction]:
    """The ``{segment index: Correction}`` map for a meeting, or empty when the
    sidecar is missing or malformed (so a bad file never breaks a re-read).
    ``original_text`` is kept (ASR12) so `apply_corrections` can tell a live
    entry from a drifted one; an entry without it is dropped, as in Swift."""
    obj = storage.read_json_object(corrections_path(transcript_md))
    if obj is None:
        return {}
    segments = obj.get("segments")
    if not isinstance(segments, list):
        return {}
    out: dict[int, Correction] = {}
    for raw in segments:
        if not isinstance(raw, dict):
            continue
        idx = raw.get("index")
        original = raw.get("original_text")
        edited = raw.get("edited_text")
        # `bool` is an `int` subclass; a JSON `true` must not become an index.
        if isinstance(idx, bool) or not isinstance(idx, int):
            continue
        if not isinstance(original, str) or not isinstance(edited, str):
            continue
        out[idx] = Correction(original, edited)
    return out


def is_empty(corrections: dict[int, Correction]) -> bool:
    return not corrections


def is_live(correction: Correction, segment_text: object) -> bool:
    """Whether a correction still describes this segment (ASR12's drift check):
    its snapshot equals the pipeline text, compared trimmed as Swift compares it."""
    text = segment_text.strip() if isinstance(segment_text, str) else ""
    return correction.original_text == text


def apply_corrections(
    segments: list[dict],
    corrections: dict[int, Correction],
    *,
    stem: str | None = None,
) -> bool:
    """Rewrite each segment's ``text`` in place per the corrections, keyed by the
    segment's array index (mirrors Swift's `TranscriptCorrectionStore.apply`).
    A drifted entry (`is_live` false) is skipped and counted in one warning per
    call naming ``stem``. Returns True if any text changed. Pure over the list
    apart from that log line; the caller re-renders."""
    if not corrections:
        return False
    changed = False
    drifted = 0
    for i, seg in enumerate(segments):
        c = corrections.get(i)
        if c is None:
            continue
        if not is_live(c, seg.get("text")):
            drifted += 1
            continue
        if c.edited_text != seg.get("text"):
            seg["text"] = c.edited_text
            changed = True
    if drifted:
        log.warning("transcript corrections: %d of %d skipped for %s, the transcript no longer reads "
                    "what they were written against", drifted, len(corrections), stem or "this meeting")
    return changed


def overlaid_structured(transcript_md: Path) -> tuple[dict, bool] | None:
    """The structured ``<stem>.json`` with BOTH reversible overlays applied, plus
    whether either actually changed anything. None when the file is missing or
    unreadable.

    The composed *data*, where ``overlaid_markdown`` is the composed *view*.
    FEAT10 needs the segments themselves (their times and text) to render a
    timestamped transcript for the model and then to verify the anchors that come
    back, and both have to see exactly what the Library shows, not the raw
    pipeline text.
    """
    from . import speaker_overlay

    overlay = speaker_overlay.read_overlay(transcript_md)
    corrections = read_corrections(transcript_md)
    json_path = transcript_md.with_suffix(".json")
    data = storage.read_json_object(json_path)
    if data is None:
        return None
    segments = data.get("segments") or []
    changed = speaker_overlay.apply_overlay(segments, overlay)
    # `or changed` order matters: apply_corrections must always run, not be
    # short-circuited away when the speaker overlay already reported a change.
    changed = apply_corrections(segments, corrections, stem=transcript_md.stem) or changed
    return data, changed


def publish_text(transcript_md: Path | None) -> str:
    """The transcript every publisher sends (PIPE51): the overlaid view when an
    overlay changes anything, else `<stem>.md` as it is, else empty. The sinks used
    to read `<stem>.md` raw, so a Library rename or line edit never reached a
    destination and a filesystem correction read as "unchanged". Fail-open exactly
    as `summarize` is: an overlay that cannot be read falls back to the raw text
    (STOR9 owns making that visible)."""
    if transcript_md is None or not transcript_md.exists():
        return ""
    overlaid = overlaid_markdown(transcript_md)
    return overlaid if overlaid is not None else transcript_md.read_text(encoding="utf-8")


def overlaid_markdown(transcript_md: Path) -> str | None:
    """The transcript markdown re-rendered with BOTH reversible overlays applied:
    the speaker-label overlay (FEAT3) and these text corrections (PIPE9). Returns
    None when neither overlay is present or neither changes anything (the caller
    then uses ``<stem>.md`` as-is). Reads the structured ``<stem>.json`` so the
    same renderer that produced ``<stem>.md`` re-renders it."""
    from . import speaker_overlay

    overlay = speaker_overlay.read_overlay(transcript_md)
    corrections = read_corrections(transcript_md)
    if speaker_overlay.is_empty(overlay) and is_empty(corrections):
        return None
    composed = overlaid_structured(transcript_md)
    if composed is None:
        return None
    data, changed = composed
    if not changed:
        return None
    from .markdown import render_markdown

    return render_markdown(data)
