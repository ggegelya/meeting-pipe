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
as-is. The index is the position in the `<stem>.json` `segments` array, the same
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

import json
from pathlib import Path

SCHEMA_VERSION = 1


def corrections_path(transcript_md: Path) -> Path:
    return transcript_md.parent / f"{transcript_md.stem}.transcript_corrections.json"


def read_corrections(transcript_md: Path) -> dict[int, str]:
    """The ``{segment index: edited text}`` map for a meeting, or empty when the
    sidecar is missing or malformed (so a bad file never breaks a re-read)."""
    try:
        obj = json.loads(corrections_path(transcript_md).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    if not isinstance(obj, dict):
        return {}
    segments = obj.get("segments")
    if not isinstance(segments, list):
        return {}
    out: dict[int, str] = {}
    for raw in segments:
        if not isinstance(raw, dict):
            continue
        idx = raw.get("index")
        edited = raw.get("edited_text")
        # `bool` is an `int` subclass; a JSON `true` must not become an index.
        if isinstance(idx, bool) or not isinstance(idx, int) or not isinstance(edited, str):
            continue
        out[idx] = edited
    return out


def is_empty(corrections: dict[int, str]) -> bool:
    return not corrections


def apply_corrections(segments: list[dict], corrections: dict[int, str]) -> bool:
    """Rewrite each segment's ``text`` in place per the corrections, keyed by the
    segment's array index (mirrors Swift's `TranscriptCorrectionStore.apply`).
    Returns True if any text changed. Pure over the list; the caller re-renders."""
    if not corrections:
        return False
    changed = False
    for i, seg in enumerate(segments):
        edited = corrections.get(i)
        if edited is not None and edited != seg.get("text"):
            seg["text"] = edited
            changed = True
    return changed


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
    json_path = transcript_md.with_suffix(".json")
    try:
        data = json.loads(json_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    segments = data.get("segments") or []
    changed = speaker_overlay.apply_overlay(segments, overlay)
    # `or changed` order matters: apply_corrections must always run, not be
    # short-circuited away when the speaker overlay already reported a change.
    changed = apply_corrections(segments, corrections) or changed
    if not changed:
        return None
    from .markdown import render_markdown

    return render_markdown(data)
