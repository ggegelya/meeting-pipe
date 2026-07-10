"""Read + apply the daemon's reversible speaker-label overlay (FEAT3-UNDO / FEAT3-SEGMENT).

`<stem>.speaker_labels.json` is written by the Swift daemon (`SpeakerLabelStore`) when
the user names or reassigns speakers in the Library. It is a display overlay the daemon
resolves at load time so the on-disk transcript keeps its diarization labels. This
module lets the pipeline apply the same overlay when re-summarizing, so a regenerate
reflects those in-app edits in the summary body + attendees.

The resolution matches the Swift side exactly (the two must agree, like any sidecar
contract): for each segment the base label is its per-segment override if present, else
its raw speaker; that base is then mapped through the cluster-name table. So a segment
reassigned to a named cluster shows the cluster's name.

Schema mirror of Swift's `SpeakerLabelStore.Overlay`:
`{ "labels": { "<raw label>": "<name>" }, "segments": { "<index>": "<label>" } }`.
"""
from __future__ import annotations

import json
from pathlib import Path


def overlay_path(transcript_md: Path) -> Path:
    return transcript_md.parent / f"{transcript_md.stem}.speaker_labels.json"


def read_overlay(transcript_md: Path) -> dict:
    """The overlay for a meeting, or an empty overlay when the sidecar is missing or
    malformed (so a bad file never breaks summarize)."""
    try:
        obj = json.loads(overlay_path(transcript_md).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {"labels": {}, "segments": {}}
    if not isinstance(obj, dict):
        return {"labels": {}, "segments": {}}
    labels = obj.get("labels")
    segments = obj.get("segments")
    return {
        "labels": labels if isinstance(labels, dict) else {},
        "segments": segments if isinstance(segments, dict) else {},
    }


def is_empty(overlay: dict) -> bool:
    return not overlay.get("labels") and not overlay.get("segments")


def apply_overlay(segments: list[dict], overlay: dict) -> bool:
    """Rewrite each segment's ``speaker`` in place per the overlay. Base label is the
    per-segment override (by array index) if present, else the raw speaker; the base is
    then mapped through the cluster-name table (so a reassignment to a named cluster
    resolves to the name). Returns True if any label changed. Pure over the list; the
    caller owns re-render."""
    labels: dict = overlay.get("labels") or {}
    seg_overrides: dict = overlay.get("segments") or {}
    if not labels and not seg_overrides:
        return False
    changed = False
    for i, seg in enumerate(segments):
        base = seg_overrides.get(str(i), seg.get("speaker"))
        if base is None:
            continue
        resolved = labels.get(base, base)
        if resolved != seg.get("speaker"):
            seg["speaker"] = resolved
            changed = True
    return changed


def overlaid_markdown(transcript_md: Path) -> str | None:
    """The transcript markdown re-rendered with the overlay applied, or None when there
    is no overlay (the caller then uses ``<stem>.md`` as-is). Reads the structured
    ``<stem>.json`` so the labels can be re-mapped and re-rendered with the same
    renderer that produced ``<stem>.md``."""
    overlay = read_overlay(transcript_md)
    if is_empty(overlay):
        return None
    json_path = transcript_md.with_suffix(".json")
    try:
        data = json.loads(json_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    segments = data.get("segments") or []
    if not apply_overlay(segments, overlay):
        return None
    from .markdown import render_markdown

    return render_markdown(data)
