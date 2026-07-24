"""`mp actions` - action items across the meeting library (TECH-FEAT4 + AI1).

Scans each meeting's `<stem>.summary.json` for the `actions` list the
summarizer already extracts (ADR 0014, `MeetingSummary.actions`) and surfaces
them in one place, so commitments don't stay buried per-meeting. Stdlib only,
no new egress surface; mirrors the `mp ask` MVP shape.

AI1 adds the lifecycle: `ActionItem.resolved` distinguishes open from closed,
`--open` / `--closed` / `--overdue` filter on it, and a dated open action shows
its age computed off the ISO `due` date (no stored aging, no date dependency).
The legacy `done` spelling is tolerated on read (mirrors the pydantic alias).

AI7 adds the series view: each action carries the workflow of the meeting it came
from, and `--cluster` groups a recurring series' restatements of one commitment
into a single cluster (`action_clusters`, on-device embeddings) so a standup's
repeated promise reads once instead of once per occurrence. `--out` writes the
JSON to a file, which is how the daemon's Facts rail consumes the grouping.
"""
from __future__ import annotations

import argparse
import json
from dataclasses import dataclass
from datetime import date
from pathlib import Path

from . import entry
from .workflow import read_meta

_CONFIDENCE_RANK = {"low": 0, "medium": 1, "high": 2}


def _parse_iso_date(value: str | None) -> date | None:
    """Parse an ISO 8601 date prefix (`2026-07-01`), tolerating a datetime
    suffix. Returns None for empty / unparseable values so undated and
    malformed dates fold together as "no deadline"."""
    if not value:
        return None
    try:
        return date.fromisoformat(value[:10])
    except ValueError:
        return None


@dataclass
class OpenAction:
    stem: str
    title: str
    task: str
    owner: str | None
    due: str | None
    confidence: str
    resolved: bool = False
    #: Workflow of the meeting this came from (`<stem>.meta.json`), the series key
    #: AI7 clusters within. None when the meeting is untagged, which makes the
    #: action a singleton (a meeting with no series has no restatements).
    workflow: str | None = None
    #: Cluster id assigned by `--cluster`; None when clustering did not run.
    cluster: int | None = None

    def age_days(self, today: date) -> int | None:
        """Whole days past `due` for a dated action (negative if still upcoming);
        None when undated. Sign is "overdue positive" so callers read it directly."""
        d = _parse_iso_date(self.due)
        return (today - d).days if d is not None else None

    def is_overdue(self, today: date) -> bool:
        age = self.age_days(today)
        return (not self.resolved) and age is not None and age > 0


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
        # AI7: the meeting's workflow is the series key. Read once per meeting,
        # not once per action; an absent / malformed sidecar reads as untagged.
        workflow = str(read_meta(summary_json).get("workflow_name") or "") or None
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
                resolved=bool(item.get("resolved") or item.get("done")),
                workflow=workflow,
            ))
    return found


def _passes(action: OpenAction, owner: str | None, due_before: str | None,
            min_conf: str | None, lifecycle: str | None, today: date) -> bool:
    if lifecycle == "open" and action.resolved:
        return False
    if lifecycle == "closed" and not action.resolved:
        return False
    if lifecycle == "overdue" and not action.is_overdue(today):
        return False
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
                   min_conf: str | None = None,
                   lifecycle: str | None = None,
                   today: date | None = None) -> list[OpenAction]:
    """Filter the actions. `lifecycle` is one of "open" / "closed" / "overdue"
    (None keeps all). `today` is injected for deterministic aging in tests;
    defaults to the real current date."""
    today = today or date.today()
    return [a for a in actions if _passes(a, owner, due_before, min_conf, lifecycle, today)]


def _sort_key(a: OpenAction) -> tuple:
    # Open before closed, then dated first (soonest due), then higher
    # confidence, then by meeting.
    return (a.resolved, a.due is None, a.due or "", -_CONFIDENCE_RANK.get(a.confidence, 1), a.stem)


def _age_phrase(age_days: int) -> str:
    """Human age for a dated action: how `due` relates to today, in whole days.
    Positive `age_days` is overdue, negative is upcoming, zero is today."""
    if age_days > 0:
        return f"{age_days}d overdue"
    if age_days < 0:
        return f"in {-age_days}d"
    return "due today"


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(
        prog="mp actions",
        description="List action items across the meeting library (TECH-FEAT4 + AI1).",
    )
    ap.add_argument("--owner", type=str, default=None, help="only actions for this owner")
    ap.add_argument("--due-before", dest="due_before", type=str, default=None,
                    help="only actions due on/before this ISO date (e.g. 2026-07-01)")
    ap.add_argument("--min-confidence", dest="min_confidence",
                    choices=["low", "medium", "high"], default=None,
                    help="drop actions below this confidence")
    lifecycle = ap.add_mutually_exclusive_group()
    lifecycle.add_argument("--open", action="store_const", const="open", dest="lifecycle",
                           help="only unresolved (open) actions")
    lifecycle.add_argument("--closed", action="store_const", const="closed", dest="lifecycle",
                           help="only resolved (closed) actions")
    lifecycle.add_argument("--overdue", action="store_const", const="overdue", dest="lifecycle",
                           help="only open actions whose ISO due date is in the past")
    ap.add_argument("--dir", type=Path, default=None, help="override the recordings directory")
    ap.add_argument("--cluster", action="store_true",
                    help="group a workflow's restatements of one commitment (AI7)")
    ap.add_argument("--cluster-threshold", dest="cluster_threshold", type=float, default=None,
                    help="cosine floor for --cluster (default follows the embedder)")
    ap.add_argument("--json", action="store_true", dest="as_json",
                    help="emit JSON instead of text")
    ap.add_argument("--out", type=Path, default=None,
                    help="write the JSON to this file instead of stdout (implies --json)")
    args = ap.parse_args(argv)

    # AI7: --cluster loads an on-device embedding model, which on a cold cache
    # fetches weights, so this is no longer a pure read of files on disk. Arm the
    # guard for every invocation (no secrets: nothing here touches a token), so a
    # regulated Mac clamps the fetch rather than relying on the flag not being used.
    cfg = entry.prepare(secrets=False)

    today = date.today()
    root = args.dir if args.dir is not None else cfg.recording.output_dir
    actions = filter_actions(
        discover(Path(root)), args.owner, args.due_before, args.min_confidence,
        args.lifecycle, today,
    )
    if args.cluster:
        from .action_clusters import cluster_actions
        for action, cluster in zip(actions, cluster_actions(
            actions, threshold=args.cluster_threshold
        )):
            action.cluster = cluster
    actions.sort(key=_sort_key)

    if args.as_json or args.out is not None:
        payload = json.dumps([
            {"stem": a.stem, "title": a.title, "task": a.task,
             "owner": a.owner, "due": a.due, "confidence": a.confidence,
             "resolved": a.resolved, "age_days": a.age_days(today),
             "overdue": a.is_overdue(today),
             "workflow": a.workflow, "cluster": a.cluster}
            for a in actions
        ], indent=2)
        if args.out is not None:
            args.out.parent.mkdir(parents=True, exist_ok=True)
            args.out.write_text(payload, encoding="utf-8")
        else:
            print(payload)
        return 0

    if not actions:
        scope = {"open": "open ", "closed": "closed ", "overdue": "overdue "}.get(args.lifecycle, "")
        print(f"No {scope}action items under {root}.")
        return 0

    label = {"closed": "closed", "overdue": "overdue"}.get(args.lifecycle, "open")
    if args.lifecycle is None:
        label = "tracked"
    # AI7: under --cluster one line stands for the whole series, so count and
    # print clusters rather than instances; the restatements ride on the tag.
    shown = _cluster_representatives(actions) if args.cluster else actions
    print(f"{len(shown)} {label} action item(s):\n")
    restated = _cluster_sizes(actions) if args.cluster else {}
    for a in shown:
        # Show the age only for a dated OPEN action: a closed item's deadline is
        # moot, and an undated one has no age to report.
        age = a.age_days(today)
        due_str = None
        if a.due:
            due_str = f"due {a.due}"
            if not a.resolved and age is not None:
                due_str += f" ({_age_phrase(age)})"
        status = "done" if a.resolved else None
        size = restated.get(a.cluster, 1)
        repeats = f"restated {size}x" if size > 1 else None
        meta = [m for m in (a.owner, due_str, a.confidence, status, repeats) if m]
        tag = "  (" + ", ".join(meta) + ")" if meta else ""
        check = "[x]" if a.resolved else "[ ]"
        print(f"- {check} {a.task}{tag}")
        print(f"    {a.title}  [{a.stem}]")
    return 0


def _cluster_sizes(actions: list[OpenAction]) -> dict[int | None, int]:
    """How many instances each cluster holds, so a representative can say so."""
    sizes: dict[int | None, int] = {}
    for a in actions:
        sizes[a.cluster] = sizes.get(a.cluster, 0) + 1
    return sizes


def _cluster_representatives(actions: list[OpenAction]) -> list[OpenAction]:
    """One action per cluster, in `actions` order: the newest instance (stems are
    datetime-derived, so the largest stem is the latest restatement), which is the
    wording the series most recently used. Order is preserved so the caller's sort
    still holds."""
    newest: dict[int | None, OpenAction] = {}
    for a in actions:
        current = newest.get(a.cluster)
        if current is None or a.stem > current.stem:
            newest[a.cluster] = a
    keep = {id(a) for a in newest.values()}
    return [a for a in actions if id(a) in keep]
