"""Render a structured transcript dict to speaker-segmented Markdown.

The structured shape is FluidAudio's `<stem>.json` sidecar (Swift writes
it directly after recording). This module renders that into a human-
readable `<stem>.md` for the library and downstream consumers.
"""
from __future__ import annotations

from collections import defaultdict
from pathlib import Path
from typing import Any

_UNSET: object = object()
_UNKNOWN_SPEAKER = "Speaker?"


def render_markdown(structured: dict[str, Any]) -> str:
    """Render the structured transcript into speaker-segmented Markdown.

    Consecutive segments from the same speaker are merged into a single
    block. When diarization failed (or returned no assignments), prepend
    a warning banner and use `Speaker?` for missing labels so the
    failure can never go unnoticed in downstream review.
    """
    lines: list[str] = []
    title = Path(structured.get("audio_path", "transcript")).stem
    lines.append(f"# Transcript - {title}")
    lines.append("")
    lines.append(f"_Language detected: {structured.get('language', 'unknown')}_")
    lines.append("")

    if structured.get("diarization_failed"):
        reason = structured.get("diarization_failure_reason") or "unknown"
        lines.append(
            f"> Diarization failed; all turns labeled `{_UNKNOWN_SPEAKER}`. "
            f"Reason: {reason}"
        )
        lines.append("")

    current_speaker: str | object = _UNSET
    buffer: list[str] = []

    def flush() -> None:
        if buffer and isinstance(current_speaker, str):
            lines.append(f"**{current_speaker}**: " + " ".join(buffer).strip())
            lines.append("")
            buffer.clear()

    for seg in structured.get("segments", []):
        speaker = seg.get("speaker") or _UNKNOWN_SPEAKER
        text = (seg.get("text") or "").strip()
        if not text:
            continue
        if speaker != current_speaker:
            flush()
            current_speaker = speaker
        buffer.append(text)
    flush()

    counts: dict[str, int] = defaultdict(int)
    for seg in structured.get("segments", []):
        counts[seg.get("speaker") or _UNKNOWN_SPEAKER] += 1
    if counts:
        lines.append("---")
        lines.append("")
        lines.append("Speakers (segment counts):")
        for spk, n in sorted(counts.items()):
            lines.append(f"- {spk}: {n}")
    return "\n".join(lines).rstrip() + "\n"
