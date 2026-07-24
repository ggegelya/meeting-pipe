"""`mp prep <workflow>` - the pre-meeting prep card (CAL2).

Before a recurring meeting the useful context is "what did we cover last time,
and what do I still owe", and today that is a hunt through the Library. This
answers it from the sidecars already on disk: the newest meeting recorded under
a workflow, the opening points of its summary, and the actions it left open.

Stdlib only, no engine call, no new egress surface. It reads `<stem>.meta.json`
(which workflow recorded the meeting) and `<stem>.summary.json` (the content),
the same two files the Library reads. The daemon renders the same card on the
detection prompt from the same files via `PrepCard.swift`; the two are
independent readers of one on-disk shape, the way `mp actions` and `FactsView`
already are.

Deliberately bounded to the *last* meeting. Carrying every older open action
forward is a different feature with a different failure mode (AI10 owns the
unbounded-action-list problem); "Last time" means last time.
"""
from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from datetime import date, datetime
from pathlib import Path

from .config import Config

#: How much of the last summary the card carries. Small on purpose: this is a
#: glance before a call, not a re-read. The Library holds the whole thing.
MAX_POINTS = 3
MAX_ACTIONS = 3


@dataclass
class PrepAction:
    task: str
    owner: str | None = None
    due: str | None = None


@dataclass
class PrepCard:
    workflow: str
    stem: str
    started_at: datetime
    title: str
    points: list[str]
    actions: list[PrepAction]
    #: Open actions beyond `MAX_ACTIONS`, so the card can say it is truncating
    #: instead of silently dropping them.
    more_actions: int = 0


def parse_stem(stem: str) -> datetime | None:
    """Parse a `YYYYMMDD-HHMMSS` recording stem into a local datetime.

    Mirrors Swift's `MeetingStore.parseStem`, including its length guard: a
    shorter string parses into something meaningless rather than failing.
    """
    if len(stem) != 15:
        return None
    try:
        return datetime.strptime(stem, "%Y%m%d-%H%M%S")
    except ValueError:
        return None


def _read_json(path: Path) -> dict | None:
    try:
        obj = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return obj if isinstance(obj, dict) else None


@dataclass
class _Candidate:
    stem: str
    started_at: datetime
    workflow: str
    summary_path: Path


def candidates(root: Path) -> list[_Candidate]:
    """Every summarized meeting under `root` that names a workflow, newest first.

    A meeting with no `<stem>.summary.json` has nothing to recap, and one with no
    `workflow_name` (a manual, workflow-less recording) belongs to no workflow, so
    both drop out here rather than in the caller.
    """
    root = root.expanduser()
    if not root.is_dir():
        return []
    found: list[_Candidate] = []
    for meta_path in root.glob("*.meta.json"):
        stem = meta_path.name.split(".", 1)[0]
        started_at = parse_stem(stem)
        if started_at is None:
            continue
        summary_path = root / f"{stem}.summary.json"
        if not summary_path.is_file():
            continue
        meta = _read_json(meta_path)
        if meta is None:
            continue
        workflow = str(meta.get("workflow_name") or "").strip()
        if not workflow:
            continue
        found.append(_Candidate(stem, started_at, workflow, summary_path))
    found.sort(key=lambda c: c.started_at, reverse=True)
    return found


def workflow_names(cands: list[_Candidate]) -> list[str]:
    """Distinct workflow names that have at least one summarized meeting, sorted."""
    return sorted({c.workflow for c in cands}, key=str.casefold)


def resolve_workflow(names: list[str], query: str) -> str | None:
    """Pick the workflow `query` means: a case-insensitive exact match first,
    then a unique case-insensitive substring. Ambiguous or unknown returns None
    so the caller can name the alternatives rather than guess (WF9 has the
    owner's config carrying four workflows called "Client work"; a silent pick
    among duplicates would be the wrong kind of helpful)."""
    q = query.strip().casefold()
    if not q:
        return None
    for name in names:
        if name.casefold() == q:
            return name
    partial = [name for name in names if q in name.casefold()]
    return partial[0] if len(partial) == 1 else None


def _clean(values: object, limit: int | None = None) -> list[str]:
    """Non-empty trimmed strings out of a summary list field, tolerating the
    partial / legacy / hand-pasted shapes the Swift reader also tolerates."""
    if not isinstance(values, list):
        return []
    out = [v.strip() for v in values if isinstance(v, str) and v.strip()]
    return out[:limit] if limit is not None else out


def build_card(
    workflow: str,
    stem: str,
    started_at: datetime,
    summary: dict,
    max_points: int = MAX_POINTS,
    max_actions: int = MAX_ACTIONS,
) -> PrepCard | None:
    """Project one summary into the card. Pure.

    Returns None when there is nothing to say (no points and no open actions), so
    an empty card is never rendered: the affordance stays quiet instead of
    announcing that it has nothing.

    Points come from `summary`, falling back to `decisions` when a run put its
    content there and left the recap empty (a local model does this often
    enough to matter).
    """
    points = _clean(summary.get("summary"), max_points)
    if not points:
        points = _clean(summary.get("decisions"), max_points)

    open_actions: list[PrepAction] = []
    raw_actions = summary.get("actions")
    if isinstance(raw_actions, list):
        for item in raw_actions:
            if not isinstance(item, dict):
                continue
            # `done` is the legacy spelling of `resolved` (the pydantic alias).
            if item.get("resolved") or item.get("done"):
                continue
            task = str(item.get("task") or "").strip()
            if not task:
                continue
            owner = str(item["owner"]).strip() if item.get("owner") else None
            due = str(item["due"]).strip() if item.get("due") else None
            open_actions.append(PrepAction(task, owner or None, due or None))

    if not points and not open_actions:
        return None

    title = str(summary.get("title") or "").strip() or stem
    shown = open_actions[:max_actions]
    return PrepCard(
        workflow=workflow,
        stem=stem,
        started_at=started_at,
        title=title,
        points=points,
        actions=shown,
        more_actions=len(open_actions) - len(shown),
    )


def prep(root: Path, workflow: str, max_points: int = MAX_POINTS,
         max_actions: int = MAX_ACTIONS) -> PrepCard | None:
    """The card for the newest meeting recorded under `workflow`, or None.

    Walks back through that workflow's meetings newest-first: a last meeting whose
    summary carried neither points nor open actions has nothing to recap, and the
    one before it usually does, so the card falls through rather than reporting an
    empty "last time".
    """
    for cand in candidates(root):
        if cand.workflow != workflow:
            continue
        summary = _read_json(cand.summary_path)
        if summary is None:
            continue
        card = build_card(workflow, cand.stem, cand.started_at, summary,
                          max_points, max_actions)
        if card is not None:
            return card
    return None


def relative_day(started: datetime, today: date) -> str:
    """"today" / "yesterday" / "3 days ago" / "5 weeks ago". Day-granular: the
    time of day is noise on a card that answers "when did we last talk"."""
    days = (today - started.date()).days
    if days <= 0:
        return "today"
    if days == 1:
        return "yesterday"
    if days < 14:
        return f"{days} days ago"
    weeks = days // 7
    if weeks < 9:
        return f"{weeks} weeks ago"
    months = max(2, round(days / 30))
    return f"{months} months ago"


def _action_line(action: PrepAction) -> str:
    meta = [m for m in (action.owner, f"due {action.due}" if action.due else None) if m]
    tag = "  (" + ", ".join(meta) + ")" if meta else ""
    return f"  - [ ] {action.task}{tag}"


def render(card: PrepCard, today: date) -> str:
    """The text card. Sentence case, no emoji, no exclamation: the CLI says the
    same thing the prompt panel shows."""
    when = relative_day(card.started_at, today)
    lines = [
        f"Last time in {card.workflow}",
        f"{card.title}  ·  {when} ({card.started_at:%Y-%m-%d})",
    ]
    if card.points:
        lines.append("")
        lines.extend(f"  - {p}" for p in card.points)
    if card.actions:
        lines.append("")
        lines.append(f"Open actions ({len(card.actions) + card.more_actions}):")
        lines.extend(_action_line(a) for a in card.actions)
        if card.more_actions:
            lines.append(f"  … {card.more_actions} more in the Library")
    lines.append("")
    lines.append(f"  [{card.stem}]")
    return "\n".join(lines)


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(
        prog="mp prep",
        description="Recap the last meeting recorded under a workflow (CAL2).",
    )
    ap.add_argument("workflow", type=str,
                    help="workflow name (exact, or a unique substring)")
    ap.add_argument("--dir", type=Path, default=None,
                    help="override the recordings directory")
    ap.add_argument("--json", action="store_true", dest="as_json",
                    help="emit JSON instead of text")
    args = ap.parse_args(argv)

    root = Path(args.dir if args.dir is not None else Config.load().recording.output_dir)
    cands = candidates(root)
    names = workflow_names(cands)
    resolved = resolve_workflow(names, args.workflow)
    if resolved is None:
        print(f"No workflow matches {args.workflow!r} under {root}.", file=sys.stderr)
        if names:
            print("Workflows with recorded meetings:", file=sys.stderr)
            for name in names:
                print(f"  {name}", file=sys.stderr)
        return 2

    card = prep(root, resolved)
    if card is None:
        if args.as_json:
            print(json.dumps({"workflow": resolved, "card": None}, indent=2))
            return 0
        print(f"No summarized meeting yet in {resolved}.")
        return 0

    if args.as_json:
        print(json.dumps({
            "workflow": card.workflow,
            "card": {
                "stem": card.stem,
                "started_at": card.started_at.isoformat(),
                "title": card.title,
                "points": card.points,
                "actions": [
                    {"task": a.task, "owner": a.owner, "due": a.due} for a in card.actions
                ],
                "more_actions": card.more_actions,
            },
        }, indent=2))
        return 0

    print(render(card, date.today()))
    return 0
