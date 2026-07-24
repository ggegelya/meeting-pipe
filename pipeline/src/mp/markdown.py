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

from .schemas import ActionItem, Evidence, MeetingSummary

_UNSET: object = object()
_UNKNOWN_SPEAKER = "Speaker?"


def format_timestamp(seconds: float) -> str:
    """`mm:ss`, or `h:mm:ss` past the hour. Mirrors Swift's
    `TranscriptDisplay.timestamp`, so the marker the model reads in the
    timestamped transcript render, the suffix a published note carries, and the
    chip the Library draws all read the same way."""
    total = int(max(0.0, seconds))
    h, m, s = total // 3600, (total % 3600) // 60, total % 60
    if h > 0:
        return f"{h}:{m:02d}:{s:02d}"
    return f"{m}:{s:02d}"


def render_markdown(structured: dict[str, Any], *, timestamps: bool = False) -> str:
    """Render the structured transcript into speaker-segmented Markdown.

    Consecutive segments from the same speaker are merged into a single
    block. When diarization failed (or returned no assignments), prepend
    a warning banner and use `Speaker?` for missing labels so the
    failure can never go unnoticed in downstream review.

    `timestamps=True` (FEAT10) prefixes each merged turn with the `[mm:ss]` of
    its first segment. That variant is built for the model input only: the stored
    `<stem>.md` is always rendered without it, so the transcript the Library shows
    and everything downstream of it are byte-identical to before.
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
    # Start of the turn being accumulated, so the timestamps variant marks the
    # turn's own beginning rather than its last segment's.
    turn_start: float | None = None

    def flush() -> None:
        nonlocal turn_start
        if buffer and isinstance(current_speaker, str):
            prefix = ""
            if timestamps and turn_start is not None:
                prefix = f"[{format_timestamp(turn_start)}] "
            lines.append(f"{prefix}**{current_speaker}**: " + " ".join(buffer).strip())
            lines.append("")
            buffer.clear()
        turn_start = None

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
        if turn_start is None:
            start = seg.get("start")
            usable = isinstance(start, (int, float)) and not isinstance(start, bool)
            turn_start = float(start) if usable else 0.0
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


def _action_runs(actions: list[ActionItem]) -> list[tuple[str | None, list[ActionItem]]]:
    """Consecutive runs of actions sharing an `ActionItem.group` (AI10).

    Runs, not buckets: the writer decides the order and the renderer never
    reorders it. Untagged actions fold into one `None` run, which is every
    meeting summary, so the ungrouped render stays byte-identical.

    The contract is that a writer tags all of its actions or none of them (the
    digest tags all, a meeting summary tags none). A mixed list renders its
    untagged run without a heading, which reads as belonging to whatever heading
    came before it, so don't produce one.
    """
    runs: list[tuple[str | None, list[ActionItem]]] = []
    for a in actions:
        if runs and runs[-1][0] == a.group:
            runs[-1][1].append(a)
        else:
            runs.append((a.group, [a]))
    return runs


def evidence_suffix(anchors: list[Evidence]) -> str:
    """FEAT10: the ` [12:34]` (or ` [12:34, 18:22]`) tail a cited point carries in
    a published note.

    Timestamps only, no quote: the owner's call on 2026-07-22 is that the phrase
    is in-app hover detail, so a note stays readable prose rather than turning
    into a transcript with citations bolted on. Empty for an uncited point, so an
    evidence-free summary renders byte-identically to before.
    """
    if not anchors:
        return ""
    return " [" + ", ".join(format_timestamp(a.t) for a in anchors) + "]"


def _section_suffix(s: MeetingSummary, section: str, index: int) -> str:
    """`evidence_suffix` for one entry of a string section, index-guarded.

    The schema keeps the anchor list aligned with the section, but a hand-edited
    file reaches the renderer without passing through that repair, and a citation
    on the wrong bullet is worse than no citation.
    """
    anchors = s.evidence.get(section) or []
    return evidence_suffix(anchors[index]) if index < len(anchors) else ""


def render_summary_md(s: MeetingSummary) -> str:
    """Render a validated summary into the human-readable `<stem>.summary.md`.

    FEAT10: a point with verified anchors carries a ` [mm:ss]` suffix. The Swift
    mirror is `AppleIntelligenceSummarizer.renderMarkdown`, pinned by the CI3
    `summary-md-golden.json` fixture, so the two cannot drift.
    """
    lines: list[str] = [f"# {s.title}", ""]
    if s.attendees:
        lines.append("**Attendees:** " + ", ".join(s.attendees))
        lines.append("")
    lines.append(f"_Language: {s.detected_language}_")
    lines.append("")

    lines.append("## Summary")
    for i, bullet in enumerate(s.summary):
        lines.append(f"- {bullet}{_section_suffix(s, 'summary', i)}")
    lines.append("")

    if s.decisions:
        lines.append("## Decisions")
        for i, d in enumerate(s.decisions):
            lines.append(f"{i + 1}. {d}{_section_suffix(s, 'decisions', i)}")
        lines.append("")

    if s.actions:
        lines.append("## Action Items")
        # AI10: a roll-up across many meetings (the weekly digest) tags each
        # action with the workflow or meeting it came from, so the list reads as
        # named groups instead of one long run. A meeting summary tags nothing
        # and renders exactly as it always did, flat and heading-free.
        for group, items in _action_runs(s.actions):
            if group:
                lines.append("")
                lines.append(f"### {group}")
            for a in items:
                owner = a.owner or "_unassigned_"
                due = f" - due {a.due}" if a.due else ""
                box = "[x]" if a.resolved else "[ ]"
                cite = evidence_suffix(a.evidence)
                lines.append(
                    f"- {box} **{owner}**: {a.task}{due}  _(confidence: {a.confidence})_{cite}"
                )
        lines.append("")

    if s.questions:
        lines.append("## Open Questions")
        for i, q in enumerate(s.questions):
            lines.append(f"- {q}{_section_suffix(s, 'questions', i)}")
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
