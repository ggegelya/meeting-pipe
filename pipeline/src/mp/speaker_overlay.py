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


def _swift_int(s: str) -> int | None:
    """Parse a segment key the way Swift's `Int(String)` does: an optional sign
    then ASCII digits, nothing else. Python's `int()` is looser (it accepts
    surrounding whitespace, underscore separators, and non-ASCII digits), so
    using it directly would let the two readers disagree on a hand-edited key
    that only one of them accepts."""
    body = s[1:] if s[:1] in ("+", "-") else s
    if not body or not body.isascii() or not body.isdigit():
        return None
    return int(s)


def read_overlay(transcript_md: Path) -> dict:
    """The overlay for a meeting, or an empty overlay when the sidecar is missing or
    malformed (so a bad file never breaks summarize).

    Entries are filtered exactly as Swift's `SpeakerLabelStore.read` filters them:
    an empty cluster key, an empty or non-string name, and a segment key that is
    not an integer are all dropped. Both sides are fail-open on a hand-edited
    sidecar, and being fail-open in DIFFERENT ways is what made the two readers
    diverge: an empty or non-string value used to resolve a speaker to `""` or to
    an integer here while Swift ignored it, so a regenerated summary could
    attribute lines to a nameless speaker the Library never showed. Segment keys
    are canonicalized (`"01"` -> `"1"`) because Swift keys them by `Int`, so an
    un-normalized key would match on one side only. Pinned by
    `Fixtures/speaker-overlay-golden.json` (CI4)."""
    try:
        obj = json.loads(overlay_path(transcript_md).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {"labels": {}, "segments": {}}
    if not isinstance(obj, dict):
        return {"labels": {}, "segments": {}}
    raw_labels = obj.get("labels")
    raw_segments = obj.get("segments")
    labels = {}
    if isinstance(raw_labels, dict):
        labels = {
            k: v
            for k, v in raw_labels.items()
            if isinstance(k, str) and k and isinstance(v, str) and v
        }
    segments = {}
    if isinstance(raw_segments, dict):
        for k, v in raw_segments.items():
            if not isinstance(k, str) or not isinstance(v, str) or not v:
                continue
            idx = _swift_int(k)
            if idx is not None:
                segments[str(idx)] = v
    return {"labels": labels, "segments": segments}


def is_empty(overlay: dict) -> bool:
    return not overlay.get("labels") and not overlay.get("segments")


def apply_overlay(segments: list[dict], overlay: dict) -> bool:
    """Rewrite each segment's ``speaker`` in place per the overlay. Base label is the
    per-segment override (by array index) if present, else the raw speaker; the base is
    then mapped through the cluster-name table (so a reassignment to a named cluster
    resolves to the name). Returns True if any label changed. Pure over the list; the
    caller owns re-render.

    The composed transcript view (this overlay plus the text-correction overlay,
    re-rendered to markdown) lives in ``transcript_corrections.overlaid_markdown``,
    since corrections are the outer layer; callers regenerating a summary or the
    index use that, not this primitive."""
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
