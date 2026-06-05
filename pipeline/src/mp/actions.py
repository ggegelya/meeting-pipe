"""`mp actions` - open action items across the meeting library (TECH-FEAT4).

Scans each meeting's `<stem>.summary.json` for the `actions` list the
summarizer already extracts (ADR 0014, `MeetingSummary.actions`) and surfaces
them in one place, so commitments don't stay buried per-meeting. Stdlib only,
no new egress surface; mirrors the `mp ask` MVP shape.

"Open" is not yet modeled in the schema, so every extracted action counts as
open. A resolved/done flag (and the UI to set it) is the named follow-up.
"""
from __future__ import annotations

import argparse
import json
from dataclasses import dataclass
from pathlib import Path

from .config import Config

_CONFIDENCE_RANK = {"low": 0, "medium": 1, "high": 2}


@dataclass
class OpenAction:
    stem: str
    title: str
    task: str
    owner: str | None
    due: str | None
    confidence: str


def discover(root: Path) -> list[OpenAction]:
    """Collect every action item from the `<stem>.summary.json` files under `root`."""
    root = root.expanduser()
    if not root.is_dir():
        return []
    found: list[OpenAction] = []
    for summary_json in sorted(root.glob("*.summary.json")):
        stem = summary_json.name.split(".", 1)[0]
        try:
            obj = json.loads(summary_json.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if not isinstance(obj, dict):
            continue
        title = str(obj.get("title") or stem)
        for item in obj.get("actions") or []:
            if not isinstance(item, dict) or not item.get("task"):
                continue
            found.append(OpenAction(
                stem=stem,
                title=title,
                task=str(item["task"]),
                owner=str(item["owner"]) if item.get("owner") else None,
                due=str(item["due"]) if item.get("due") else None,
                confidence=str(item.get("confidence") or "medium"),
            ))
    return found


def _passes(action: OpenAction, owner: str | None, due_before: str | None,
            min_conf: str | None) -> bool:
    if owner is not None and (action.owner or "").lower() != owner.lower():
        return False
    if min_conf is not None and (
        _CONFIDENCE_RANK.get(action.confidence, 1) < _CONFIDENCE_RANK[min_conf]
    ):
        return False
    if due_before is not None:
        # When filtering by a deadline, undated actions are not "due before" it.
        # ISO 8601 dates sort lexicographically, so a string compare is correct.
        if not action.due or action.due > due_before:
            return False
    return True


def filter_actions(actions: list[OpenAction], owner: str | None = None,
                   due_before: str | None = None,
                   min_conf: str | None = None) -> list[OpenAction]:
    return [a for a in actions if _passes(a, owner, due_before, min_conf)]


def _sort_key(a: OpenAction) -> tuple:
    # Dated actions first (soonest due), then higher confidence, then by meeting.
    return (a.due is None, a.due or "", -_CONFIDENCE_RANK.get(a.confidence, 1), a.stem)


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(
        prog="mp actions",
        description="List open action items across the meeting library (TECH-FEAT4).",
    )
    ap.add_argument("--owner", type=str, default=None, help="only actions for this owner")
    ap.add_argument("--due-before", dest="due_before", type=str, default=None,
                    help="only actions due on/before this ISO date (e.g. 2026-07-01)")
    ap.add_argument("--min-confidence", dest="min_confidence",
                    choices=["low", "medium", "high"], default=None,
                    help="drop actions below this confidence")
    ap.add_argument("--dir", type=Path, default=None, help="override the recordings directory")
    ap.add_argument("--json", action="store_true", dest="as_json",
                    help="emit JSON instead of text")
    args = ap.parse_args(argv)

    root = args.dir if args.dir is not None else Config.load().recording.output_dir
    actions = filter_actions(
        discover(Path(root)), args.owner, args.due_before, args.min_confidence
    )
    actions.sort(key=_sort_key)

    if args.as_json:
        print(json.dumps([
            {"stem": a.stem, "title": a.title, "task": a.task,
             "owner": a.owner, "due": a.due, "confidence": a.confidence}
            for a in actions
        ], indent=2))
        return 0

    if not actions:
        print(f"No open action items under {root}.")
        return 0

    print(f"{len(actions)} open action item(s):\n")
    for a in actions:
        meta = [m for m in (a.owner, f"due {a.due}" if a.due else None, a.confidence) if m]
        tag = "  (" + ", ".join(meta) + ")" if meta else ""
        print(f"- {a.task}{tag}")
        print(f"    {a.title}  [{a.stem}]")
    return 0
