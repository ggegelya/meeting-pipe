"""The pipeline's Markdown renderers.

`render_markdown` turns a structured transcript dict into speaker-segmented
Markdown. The structured shape is FluidAudio's `<stem>.json` sidecar (Swift
writes it directly after recording); the render becomes the human-readable
`<stem>.md` for the library and downstream consumers.

`render_summary_md` turns a validated `MeetingSummary` into the human-readable
`<stem>.summary.md`. It is the single rendering every consumer shares: the
summarizer, `publish-from-paste`, `digest`, and the LAN and filesystem sinks.
The filesystem sink used to carry its own copy of this function to avoid
importing a private helper from `summarize`; the copy drifted (PIPE7).
"""
from __future__ import annotations

from collections import defaultdict
from pathlib import Path
from typing import Any

from .schemas import MeetingSummary

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
        if seg.get("kind") == "gap":
            # An explicit recording-gap marker (FEAT9 merge). Render it as a
            # divider note rather than a speaker turn so it reads as a break and
            # never counts as a speaker / attendee.
            flush()
            current_speaker = _UNSET
            note = (seg.get("text") or "").strip()
            lines.append("---")
            lines.append("")
            if note:
                lines.append(f"_{note}_")
                lines.append("")
            continue
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
        if seg.get("kind") == "gap":
            continue
        counts[seg.get("speaker") or _UNKNOWN_SPEAKER] += 1
    if counts:
        lines.append("---")
        lines.append("")
        lines.append("Speakers (segment counts):")
        for spk, n in sorted(counts.items()):
            lines.append(f"- {spk}: {n}")
    return "\n".join(lines).rstrip() + "\n"


def render_summary_md(s: MeetingSummary) -> str:
    """Render a validated summary into the human-readable `<stem>.summary.md`."""
    lines: list[str] = [f"# {s.title}", ""]
    if s.attendees:
        lines.append("**Attendees:** " + ", ".join(s.attendees))
        lines.append("")
    lines.append(f"_Language: {s.detected_language}_")
    lines.append("")

    lines.append("## Summary")
    for bullet in s.summary:
        lines.append(f"- {bullet}")
    lines.append("")

    if s.decisions:
        lines.append("## Decisions")
        for i, d in enumerate(s.decisions, 1):
            lines.append(f"{i}. {d}")
        lines.append("")

    if s.actions:
        lines.append("## Action Items")
        for a in s.actions:
            owner = a.owner or "_unassigned_"
            due = f" - due {a.due}" if a.due else ""
            box = "[x]" if a.resolved else "[ ]"
            lines.append(f"- {box} **{owner}**: {a.task}{due}  _(confidence: {a.confidence})_")
        lines.append("")

    if s.questions:
        lines.append("## Open Questions")
        for q in s.questions:
            lines.append(f"- {q}")
        lines.append("")

    # WF7: workflow-defined extra sections, after the standard ones. Skip an
    # empty one (the model may return a requested-but-unfilled section) so the
    # note never carries a bare heading.
    for sec in s.extra_sections:
        if not sec.content:
            continue
        lines.append(f"## {sec.name}")
        for item in sec.content:
            lines.append(f"- {item}")
        lines.append("")

    return "\n".join(lines).rstrip() + "\n"
