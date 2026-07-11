"""mp classify-meetings (AI5 spike): label the library by meeting type.

Throwaway owner-dev spike (de-CLI exempt, like dogfood / analyze-detection) to
judge whether meeting-type labels are useful enough to earn a `MeetingSummary`
schema field. Heuristic by default (zero-egress: title / attendees / workflow);
`--llm` adds a local-engine label beside it for comparison, routed through
`engine.complete_text` so `effective_backend` and the egress guard apply (the
AI/DV standing rule). No schema change lands here: the owner decides adoption
after seeing the labels on a real library.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter
from dataclasses import dataclass
from pathlib import Path

from . import engine, entry
from .config import Config

# The candidate taxonomy. Deliberately small and common; the point is to see how
# cleanly a real library falls into buckets, not to be exhaustive.
TAXONOMY = [
    "one_on_one", "standup", "planning", "retro", "interview",
    "client", "review", "brainstorm", "all_hands", "other",
]

# First-match keyword rules over the title + workflow name (lower-cased).
_KEYWORDS: list[tuple[str, list[str]]] = [
    ("one_on_one", [r"\b1:1\b", r"\bone[- ]on[- ]one\b", r"\bcatch[- ]?up\b", r"\bsync\b"]),
    ("standup", [r"\bstand[- ]?up\b", r"\bdaily\b", r"\bscrum\b"]),
    ("planning", [r"\bplanning\b", r"\bsprint\b", r"\broadmap\b", r"\bkick[- ]?off\b"]),
    ("retro", [r"\bretro\b", r"\bretrospective\b", r"\bpost[- ]?mortem\b"]),
    ("interview", [r"\binterview\b", r"\bscreen(ing)?\b", r"\bcandidate\b"]),
    ("review", [r"\breview\b", r"\bdemo\b", r"\bwalkthrough\b"]),
    ("brainstorm", [r"\bbrainstorm\b", r"\bideation\b", r"\bworkshop\b"]),
    ("all_hands", [r"\ball[- ]hands\b", r"\btown ?hall\b", r"\bquarterly\b"]),
    ("client", [r"\bclient\b", r"\bcustomer\b", r"\bvendor\b", r"\bpartner\b"]),
]

_STEM_DATE = re.compile(r"^(\d{8})")


@dataclass
class Meeting:
    stem: str
    title: str
    date: str
    attendees: int
    workflow: str
    heuristic_type: str
    heuristic_reason: str
    llm_type: str | None = None


def meeting_day(stem: str) -> str:
    m = _STEM_DATE.match(stem)
    if not m:
        return ""
    d = m.group(1)
    return f"{d[0:4]}-{d[4:6]}-{d[6:8]}"


def classify_heuristic(title: str, workflow: str, attendees: int) -> tuple[str, str]:
    """Return (type, reason) from title/workflow keywords, then attendee count."""
    hay = f"{title} {workflow}".lower()
    for label, patterns in _KEYWORDS:
        for pat in patterns:
            if re.search(pat, hay):
                return label, f"keyword:{label}"
    if attendees == 2:
        return "one_on_one", "attendees=2"
    if attendees >= 9:
        return "all_hands", f"attendees={attendees}"
    return "other", "no match"


def discover(root: Path) -> list[Meeting]:
    """Every meeting with a summary, heuristically typed. The `*.summary.json`
    glob + `stem = name.split('.', 1)[0]` idiom matches actions / digest."""
    out: list[Meeting] = []
    for sj in sorted(root.glob("*.summary.json")):
        stem = sj.name.split(".", 1)[0]
        try:
            summary = json.loads(sj.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        meta: dict = {}
        meta_path = root / f"{stem}.meta.json"
        if meta_path.exists():
            try:
                meta = json.loads(meta_path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                meta = {}
        title = str(summary.get("title") or meta.get("meeting_title") or stem)
        attendees = len(summary.get("attendees") or [])
        workflow = str(meta.get("workflow_name") or "")
        htype, hreason = classify_heuristic(title, workflow, attendees)
        out.append(Meeting(
            stem=stem, title=title, date=meeting_day(stem), attendees=attendees,
            workflow=workflow, heuristic_type=htype, heuristic_reason=hreason,
        ))
    return out


_LLM_SYSTEM = (
    "You label a meeting with exactly one type from a fixed list. "
    "Reply with only the label, nothing else."
)


def _llm_user(m: Meeting) -> str:
    return (
        f"Types: {', '.join(TAXONOMY)}\n\n"
        f"Title: {m.title}\nWorkflow: {m.workflow}\nAttendees: {m.attendees}\n\n"
        "The single best type label:"
    )


def classify_llm(cfg: Config, m: Meeting) -> str:
    """One local-engine label per meeting, snapped to the taxonomy. Routes through
    `engine.complete_text`, so a regulated / NDA config stays on-device."""
    try:
        res = engine.complete_text(
            cfg, system_prompt=_LLM_SYSTEM, user_message=_llm_user(m), max_tokens=12
        )
    except engine.EngineError:
        return "error"
    text = res.text.strip().lower()
    for label in TAXONOMY:
        if label in text or label.replace("_", " ") in text or label.replace("_", "-") in text:
            return label
    return "other"


def render_report(meetings: list[Meeting], *, use_llm: bool) -> str:
    lines = [f"# Meeting-type classification (AI5 spike): {len(meetings)} meetings", ""]
    if not meetings:
        lines.append("No meetings found (no *.summary.json in the library).")
        return "\n".join(lines) + "\n"

    dist = Counter(m.heuristic_type for m in meetings)
    lines.append("## Heuristic distribution")
    for label in TAXONOMY:
        if dist.get(label):
            lines.append(f"- {label}: {dist[label]}")
    lines.append("")

    if use_llm:
        agree = sum(1 for m in meetings if m.llm_type == m.heuristic_type)
        lines.append(f"## Heuristic vs local-LLM agreement: {agree}/{len(meetings)}")
        lines.append("")

    lines.append("## Per meeting")
    lines.append("date        type            " + ("llm             " if use_llm else "") + "title")
    for m in sorted(meetings, key=lambda x: x.stem):
        row = f"{m.date:<11} {m.heuristic_type:<15} "
        if use_llm:
            row += f"{(m.llm_type or '-'):<15} "
        row += m.title
        lines.append(row.rstrip())
    return "\n".join(lines) + "\n"


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(
        prog="mp classify-meetings",
        description="AI5 spike: label the library by meeting type (heuristic, optional local LLM).",
    )
    p.add_argument("--dir", type=Path, help="Library directory (default: recording.output_dir).")
    p.add_argument("--llm", action="store_true",
                   help="Also label via the local engine for comparison (honors effective_backend).")
    p.add_argument("--json", action="store_true", help="Emit JSON instead of the text report.")
    args = p.parse_args(argv)

    # Arm the egress guard either way; load secrets only when the LLM path runs.
    cfg = entry.prepare(secrets=args.llm)
    root = args.dir if args.dir is not None else cfg.recording.output_dir
    meetings = discover(root)

    if args.llm:
        for m in meetings:
            m.llm_type = classify_llm(cfg, m)

    if args.json:
        payload = [
            {
                "stem": m.stem, "date": m.date, "title": m.title, "attendees": m.attendees,
                "workflow": m.workflow, "type": m.heuristic_type, "reason": m.heuristic_reason,
                "llm_type": m.llm_type,
            }
            for m in meetings
        ]
        json.dump(payload, sys.stdout, indent=2)
        sys.stdout.write("\n")
        return 0

    sys.stdout.write(render_report(meetings, use_llm=args.llm))
    return 0
