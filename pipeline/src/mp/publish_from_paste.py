"""`mp publish-from-paste <transcript.md>` — publish a hand-written summary.

Companion to the BYO summary mode. The user records a meeting with
"Record (BYO summary)", hand-summarises the transcript in Claude Code or
their preferred LLM frontend, saves the result as `<stem>.summary.md`
next to the transcript, and runs this command. We parse the markdown
back into a `MeetingSummary` and reuse the existing publish machinery.

The parser is deliberately tolerant: hand-written markdown rarely
matches a strict schema. We extract what we can and fill the rest with
sensible defaults (empty lists, unassigned action items). The published
Notion page is identical in shape to the auto-summarised flow — same
properties, same body block structure.
"""
from __future__ import annotations

import logging
import re
import sys
from pathlib import Path

from .config import Config
from .egress_guard import arm_for_config
from .publish_notion import publish
from .schemas import ActionItem, MeetingSummary
from .summarize import _render_summary_md

log = logging.getLogger("mp.publish_from_paste")


# Heading + bullet regexes. Match Markdown produced by Claude Code or
# claude.ai by default — H2 sections, "- " or "* " bullets, "[ ]"/"[x]" todos.
_H1 = re.compile(r"^# (.+?)\s*$", re.MULTILINE)
_H2 = re.compile(r"^##\s+(.+?)\s*$", re.MULTILINE)
_BULLET = re.compile(r"^\s*[-*]\s+(.+?)\s*$", re.MULTILINE)
_NUMBERED = re.compile(r"^\s*\d+[.)]\s+(.+?)\s*$", re.MULTILINE)
# `[ ]` and `[x]`/`[X]` both match — a checked item is parsed as a completed
# action (confidence stays "medium", task text is unchanged). The owner
# separator is `:` or `-` (no `|` — that was a bug from putting `|` inside
# the character class, where it's literal, not alternation).
_TODO = re.compile(
    r"^\s*[-*]\s+\[(?P<done>[ xX])\]\s+(?:\*\*(?P<owner>[^*]+)\*\*\s*[:\-]\s*)?(?P<task>.+?)\s*$",
    re.MULTILINE,
)


def parse_summary_md(text: str, *, fallback_title: str = "(untitled meeting)") -> MeetingSummary:
    """Best-effort parse of free-form summary Markdown into MeetingSummary.

    Recognises:
      - First H1 → title (truncated to 120 chars to satisfy the schema).
      - H2 sections: "Summary", "Decisions", "Action Items", "Open Questions",
        "Attendees" (case-insensitive). Bullet/numbered list items become
        list entries.
      - Inside Action Items: lines like `- [ ] **Owner**: task` extract
        owner; otherwise owner=None and confidence=low.
      - "Attendees: Alice, Bob" line (anywhere) populates attendees.

    Anything we can't parse is dropped silently — better to publish a
    partial summary than to fail the whole flow.
    """
    sections = _split_sections(text)

    title_match = _H1.search(text)
    title = (title_match.group(1).strip() if title_match else fallback_title)[:120]

    summary_bullets = _extract_bullets(sections.get("summary", ""))
    if not summary_bullets:
        summary_bullets = ["(no summary section detected — see transcript)"]
    summary_bullets = summary_bullets[:10]  # schema cap

    decisions = _extract_bullets_or_numbered(sections.get("decisions", ""))
    questions = _extract_bullets(sections.get("open questions", "")) or _extract_bullets(
        sections.get("questions", "")
    )

    actions = _extract_actions(sections.get("action items", "")) or _extract_actions(
        sections.get("actions", "")
    )

    attendees = _extract_attendees(sections.get("attendees", ""), text)

    detected_language = _extract_language_hint(text)

    return MeetingSummary(
        title=title,
        summary=summary_bullets,
        decisions=decisions,
        actions=actions,
        questions=questions,
        attendees=attendees,
        detected_language=detected_language,
    )


def _split_sections(text: str) -> dict[str, str]:
    """Return {section-title-lowercased: section-body}.

    Sections are H2-delimited. The body of a section is everything up to
    the next H2 (or end of file). Title comparison is case-insensitive.
    """
    sections: dict[str, str] = {}
    matches = list(_H2.finditer(text))
    for i, m in enumerate(matches):
        name = m.group(1).strip().lower()
        start = m.end()
        end = matches[i + 1].start() if i + 1 < len(matches) else len(text)
        sections[name] = text[start:end]
    return sections


def _extract_bullets(body: str) -> list[str]:
    return [m.group(1).strip() for m in _BULLET.finditer(body)]


def _extract_bullets_or_numbered(body: str) -> list[str]:
    bullets = _extract_bullets(body)
    if bullets:
        return bullets
    return [m.group(1).strip() for m in _NUMBERED.finditer(body)]


def _extract_actions(body: str) -> list[ActionItem]:
    """Parse `- [ ] **Owner**: task — due 2026-05-01` style action items.

    The schema requires task; owner/due are optional. Confidence defaults
    to "medium" because hand-written items presumably came from a real
    review pass — distinct from the LLM's "low" guard.
    """
    items: list[ActionItem] = []
    for m in _TODO.finditer(body):
        task = m.group("task").strip()
        owner = m.group("owner")
        owner = owner.strip() if owner else None
        due = _extract_due_date(task)
        if due:
            # Strip the "— due 2026-05-01" trailer from the task text.
            task = re.sub(
                r"\s*[—-]\s*due\s+\d{4}-\d{2}-\d{2}\s*$",
                "",
                task,
                flags=re.IGNORECASE,
            ).strip()
        items.append(
            ActionItem(
                task=task,
                owner=owner,
                due=due,
                confidence="medium",
            )
        )
    return items


def _extract_due_date(text: str) -> str | None:
    m = re.search(r"\bdue\s+(\d{4}-\d{2}-\d{2})\b", text, re.IGNORECASE)
    return m.group(1) if m else None


def _extract_attendees(section_body: str, full_text: str) -> list[str]:
    """Pull attendees from a dedicated section first, then fall back to
    a `**Attendees:** Alice, Bob` line anywhere in the document."""
    bullets = _extract_bullets(section_body)
    if bullets:
        return bullets
    # Match `**Attendees:** Alice, Bob`, `Attendees: Alice, Bob`, or any
    # mix — different LLM frontends emit different bolding conventions.
    m = re.search(r"(?:\*\*)?Attendees:(?:\*\*)?\s*([^\n]+)", full_text)
    if m:
        return [name.strip() for name in m.group(1).split(",") if name.strip()]
    return []


def _extract_language_hint(text: str) -> str:
    m = re.search(r"_Language(?: detected)?:\s*([a-z]{2})_", text, re.IGNORECASE)
    return m.group(1).lower() if m else "en"


# --- CLI entry point --------------------------------------------------------


def publish_from_paste(transcript_md: Path, cfg: Config | None = None) -> dict:
    """Read `<stem>.summary.md` next to the transcript, parse, publish."""
    cfg = cfg or Config.load()
    arm_for_config(cfg)  # TECH-SEC3: block non-loopback egress under regulated/NDA
    stem = transcript_md.stem
    summary_md_path = transcript_md.parent / f"{stem}.summary.md"
    summary_json_path = transcript_md.parent / f"{stem}.summary.json"

    if not summary_md_path.exists():
        raise FileNotFoundError(
            f"Expected your hand-written summary at {summary_md_path}. "
            f"Save the LLM's output there, then re-run."
        )

    raw = summary_md_path.read_text(encoding="utf-8")
    summary = parse_summary_md(raw, fallback_title=stem)
    log.info(
        "Parsed summary: title=%r, %d bullets, %d decisions, %d actions, %d questions",
        summary.title,
        len(summary.summary),
        len(summary.decisions),
        len(summary.actions),
        len(summary.questions),
    )

    if cfg.modes.regulated_mode:
        # Don't touch the user's hand-written .summary.md and don't write
        # the .summary.json sidecar — regulated_mode means "nothing leaves
        # this machine, and nothing on disk gets rewritten without an
        # explicit user action". publish() short-circuits internally too,
        # but we have to gate file writes here because they happen before
        # the publish call.
        log.info(
            "regulated_mode=true → preserving %s untouched, skipping Notion publish",
            summary_md_path,
        )
        return publish(summary_json_path, cfg=cfg, transcript_md=transcript_md)

    # Persist the canonical .summary.json so re-runs (or the auto-flow
    # later) see a consistent on-disk shape.
    summary_json_path.write_text(
        summary.model_dump_json(indent=2, exclude_none=False),
        encoding="utf-8",
    )
    # Re-render the summary.md from the parsed form so the Notion toggle
    # body matches what we publish — preserves user content but drops
    # whatever ad-hoc styling the LLM produced.
    summary_md_path.write_text(_render_summary_md(summary), encoding="utf-8")

    return publish(summary_json_path, cfg=cfg, transcript_md=transcript_md)


def main(argv: list[str]) -> int:
    if not argv or argv[0] in {"-h", "--help"}:
        print("usage: mp publish-from-paste <transcript.md>")
        print("Reads <stem>.summary.md, parses to MeetingSummary, publishes to Notion.")
        return 0
    transcript = Path(argv[0]).expanduser().resolve()
    if not transcript.exists():
        print(f"No such file: {transcript}", file=sys.stderr)
        return 1
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    try:
        publish_from_paste(transcript)
    except Exception as e:  # noqa: BLE001
        log.error("publish-from-paste failed: %s", e)
        return 1
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main(sys.argv[1:]))
