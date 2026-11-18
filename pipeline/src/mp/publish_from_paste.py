"""`mp publish-from-paste <transcript.md>` — publish a hand-written summary.

Companion to the BYO summary mode. The user records a meeting with
"Record (BYO summary)", hand-summarises the transcript in Claude Code or
their preferred LLM frontend, saves the result as `<stem>.summary.md`
next to the transcript, and runs this command. We parse the markdown
back into a `MeetingSummary` and reuse the existing publish machinery.

The parser is deliberately tolerant: hand-written markdown rarely
matches a strict schema. We extract what we can and fill the rest with
sensible defaults (empty lists, unassigned action items). The published
page is identical in shape to the auto-summarised flow.

PIPE50: the pasted `<stem>.summary.md` is never rewritten. The parsed form
goes to `<stem>.summary.json`, which every sink renders from, and a paste
whose known section has content the parser cannot read (prose under
`## Summary`) is refused with the shape it expects, rather than published
as a placeholder.
"""
from __future__ import annotations

import logging
import os
import re
import sys
from pathlib import Path

from . import entry, events, storage
from .config import Config
from .publish_router import EXIT_PUBLISH_FAILED, fanout, publish_failed, publish_failure_reason
from .schemas import ActionItem, ExtraSection, MeetingSummary

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

#: The schema caps `parse_summary_md` truncates to (PIPE50 reports when it does).
TITLE_LIMIT = 120
SUMMARY_LIMIT = 10


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

    Content outside a recognised shape is not kept in the parsed form.
    `publish_from_paste` refuses a paste where that would empty a known
    section (`lossy_sections`), and reports a truncation (`truncation`), so
    neither loss is silent any more; this function itself stays pure.
    """
    sections = _split_sections(text)

    title_match = _H1.search(text)
    title = ((title_match.group(1).strip() if title_match else "") or fallback_title)[:TITLE_LIMIT]

    summary_bullets = _extract_bullets(sections.get("summary", ""))
    if not summary_bullets:
        summary_bullets = ["(no summary section detected — see transcript)"]
    summary_bullets = summary_bullets[:SUMMARY_LIMIT]  # schema cap

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
        extra_sections=_extract_extra_sections(text),
    )


# The standard sections (lowercased) that map to typed fields; every other H2
# is treated as a workflow-defined extra section (WF7). `transcript` is excluded
# so a summary that inlines the transcript never captures it as a section.
_KNOWN_SECTIONS = frozenset({
    "summary", "decisions", "action items", "actions",
    "open questions", "questions", "attendees", "transcript",
})


#: PIPE50: the content sections a paste is refused over when they hold text that parses to
#: nothing, with the shape each one expects. Attendees is left out: it has its own
#: `Attendees: Alice, Bob` fallback and is a list of names, not content that can be lost.
_REFUSABLE: tuple[tuple[tuple[str, ...], str], ...] = (
    (("summary",), "one bullet per line, starting with `- `"),
    (("decisions",), "one bullet per line, starting with `- ` (or a numbered list)"),
    (("action items", "actions"), "one item per line, written `- [ ] **Owner**: task`"),
    (("open questions", "questions"), "one bullet per line, starting with `- `"),
)


class PasteRefused(ValueError):
    """A paste `publish_from_paste` will not publish because a known section would be lost
    (PIPE50). `main` prints it as one `[FAIL] <sentence>` line, the stderr shape the paste box's
    `FailurePresentation` reads its explanation from (STOR14 / PIPE54), so it stays one short
    sentence."""


def refusal_message(problems: list[tuple[str, str]]) -> str:
    """One sentence for the paste box, short enough for the `[FAIL]` reader's 400-character cap."""
    if len(problems) == 1:
        heading, shape = problems[0]
        return (f"The `## {heading}` section could not be read, so nothing was published. "
                f"Write it as {shape}.")
    names = ", ".join(f"`## {h}`" for h, _ in problems[:-1]) + f" and `## {problems[-1][0]}`"
    return (f"The {names} sections could not be read, so nothing was published. Write each as "
            "one bullet per line starting with `- `, and action items as `- [ ] **Owner**: task`.")


def lossy_sections(text: str) -> list[tuple[str, str]]:
    """The known sections of a paste that have content but would parse to nothing, as
    (heading as written, the shape it expects) (PIPE50). Empty when nothing would be lost. A
    missing heading is not lossy: the minimal-markdown case keeps its placeholder."""
    sections = _split_sections(text)
    headings = {m.group(1).strip().lower(): m.group(1).strip() for m in _H2.finditer(text)}
    problems: list[tuple[str, str]] = []
    for names, shape in _REFUSABLE:
        for name in names:
            body = sections.get(name)
            if body is None or not body.strip():
                continue
            if name in ("action items", "actions"):
                parsed: list = _extract_actions(body)
            elif name == "decisions":
                parsed = _extract_bullets_or_numbered(body)
            else:
                parsed = _extract_bullets(body)
            if not parsed:
                problems.append((headings.get(name, name), shape))
    return problems


def truncation(text: str) -> dict[str, int] | None:
    """What `parse_summary_md` cuts to fit the schema, or None when nothing is cut (PIPE50)."""
    title_match = _H1.search(text)
    title_chars = len(title_match.group(1).strip()) if title_match else 0
    bullets = len(_extract_bullets(_split_sections(text).get("summary", "")))
    if title_chars <= TITLE_LIMIT and bullets <= SUMMARY_LIMIT:
        return None
    return {"title_chars": title_chars, "title_limit": TITLE_LIMIT,
            "summary_bullets": bullets, "summary_limit": SUMMARY_LIMIT}


def _extract_extra_sections(text: str) -> list[ExtraSection]:
    """WF7: any H2 section that isn't one of the standard ones round-trips as an
    extra section, preserving its original-case name, so a hand-pasted summary
    with a "## Billable follow-ups" block survives the BYO publish path."""
    out: list[ExtraSection] = []
    matches = list(_H2.finditer(text))
    for i, m in enumerate(matches):
        name = m.group(1).strip()
        if name.lower() in _KNOWN_SECTIONS:
            continue
        start = m.end()
        end = matches[i + 1].start() if i + 1 < len(matches) else len(text)
        content = _extract_bullets_or_numbered(text[start:end])
        if content:
            out.append(ExtraSection(name=name[:80], content=content))
    return out


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
        # A checked box (`[x]`/`[X]`) is a resolved action; `[ ]` is open. This
        # is the markdown round-trip for the AI1 resolved flag.
        resolved = m.group("done").lower() == "x"
        due = _extract_due_date(task)
        if due:
            # Strip the "- due 2026-05-01" trailer from the task text.
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
                resolved=resolved,
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
    # The entry contract (SEC13): overlay, arm, secrets, once, before either
    # branch. `<stem>.md` and `<stem>.summary.json` resolve to the same meta
    # sidecar, so anchoring on the transcript is equivalent to the old
    # post-parse overlay and puts the NDA/regulated clamp in force before any
    # sink or token is reachable. Folding the overlay in this early also means a
    # meeting *recorded* under regulated mode (sidecar `regulated_mode`, DSN6)
    # now takes the preserve-untouched branch below even if the global flag has
    # since been turned off.
    cfg = entry.prepare(cfg, transcript_md)
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
    cut = truncation(raw)
    log.info(
        "Parsed summary: title=%r, %d bullets, %d decisions, %d actions, %d questions",
        summary.title,
        len(summary.summary),
        len(summary.decisions),
        len(summary.actions),
        len(summary.questions),
    )

    if cfg.modes.regulated_mode:
        # Don't touch the user's hand-written .summary.md and don't write the
        # .summary.json sidecar: regulated_mode means "nothing reaches a cloud
        # service, and nothing on disk gets rewritten without an explicit user
        # action". The guard is already armed by `entry.prepare` above.
        log.info(
            "regulated_mode=true, preserving %s untouched and skipping publish",
            summary_md_path,
        )
        return {"page_id": None, "page_url": None, "regulated": True}

    # SEC14: a summary carries meeting content, so the pasted file is owner-only. The daemon
    # writes it with default permissions; the re-render used to make it 0600 by accident of
    # `atomic_write_text`, so with the re-render gone (PIPE50) only the mode is set, the bytes
    # stay exactly as pasted.
    try:
        os.chmod(summary_md_path, 0o600)
    except OSError as exc:
        log.warning("could not make %s private: %s", summary_md_path.name, exc)

    # PIPE50: refuse, before anything is written, a paste whose known section the parser cannot
    # read. Publishing it used to replace prose under `## Summary` with the placeholder bullet in
    # the file and every sink. `main` exits 1 and the paste box shows this message inline.
    if problems := lossy_sections(raw):
        raise PasteRefused(refusal_message(problems))
    if cut is not None:
        log.warning("The pasted summary was trimmed to fit: title %d of %d characters kept, "
                    "summary %d of %d bullets kept",
                    min(cut["title_chars"], TITLE_LIMIT), cut["title_chars"],
                    min(cut["summary_bullets"], SUMMARY_LIMIT), cut["summary_bullets"])
        events.emit("pipeline", "paste_truncated", **cut)

    # PIPE50: the pasted `<stem>.summary.md` stays exactly as the owner pasted it, so the Ask
    # index and drag-out keep the full text. It used to be re-rendered from the parsed form,
    # which kept only what the parser recognised. `<stem>.summary.json` carries the parsed form
    # every sink renders from; atomic, like `summarize`'s writer of the same file (PIPE30).
    storage.atomic_write_text(summary_json_path, summary.model_dump_json(indent=2, exclude_none=False))

    # Route through the fanout so every configured sink receives the summary,
    # not just Notion (PIPE2/AUD-15). An NDA workflow still drops the Notion
    # sink (`effective_sinks`), and the title comes from the shared
    # apply_meeting_title path inside fanout.
    return fanout(summary_json=summary_json_path, cfg=cfg, transcript_md=transcript_md)


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
        result = publish_from_paste(transcript)
    except PasteRefused as e:
        # PIPE50: the paste box shows this sentence inline (`FailurePresentation.refusalSentence`).
        log.error("publish-from-paste refused: %s", e)
        print(f"[FAIL] {e}", file=sys.stderr)
        return 1
    except Exception as e:  # noqa: BLE001
        log.error("publish-from-paste failed: %s", e)
        return 1
    # Same honest-failure contract as `run-all` and `mp publish` (PIPE1): the
    # daemon's paste box treats a zero exit as "published" and clears the failure
    # sidecar, so an all-sinks-failed paste must not exit zero.
    if publish_failed(result):
        log.error("publish-from-paste failed: %s", publish_failure_reason(result))
        return EXIT_PUBLISH_FAILED
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main(sys.argv[1:]))
