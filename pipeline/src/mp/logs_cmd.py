"""`mp logs` — pretty-print filtered events from the JSONL event streams.

Sources:
  ~/Library/Logs/MeetingPipe/events.jsonl          (Swift daemon)
  ~/Library/Logs/MeetingPipe/pipeline_events.jsonl (Python pipeline)

Filters: --since, --category, --action. Each event is one JSON object;
this command applies filters in Python so the user does not have to
remember `jq` syntax. Events are merged across both files and sorted
by timestamp.

Output format: one event per line, fields aligned for scanning.
``--json`` re-emits the matched events as JSONL for downstream piping.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Iterable, Iterator

LOGS_DIR = Path(os.path.expanduser("~/Library/Logs/MeetingPipe"))
SOURCES = ("events.jsonl", "pipeline_events.jsonl")


def _parse_since(s: str) -> datetime:
    """Accept either an ISO timestamp or a `Nh` / `Nm` / `Nd` relative offset.

    Relative is the common case (`mp logs --since 1h`). ISO is for
    pinning a postmortem window. Naive ISO inputs are assumed UTC,
    matching how the emitters write timestamps.
    """
    s = s.strip()
    if s and s[-1] in "smhd" and s[:-1].isdigit():
        n = int(s[:-1])
        unit = {"s": "seconds", "m": "minutes", "h": "hours", "d": "days"}[s[-1]]
        return datetime.now(timezone.utc) - timedelta(**{unit: n})
    dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


def _iter_events() -> Iterator[dict]:
    for name in SOURCES:
        path = LOGS_DIR / name
        if not path.exists():
            continue
        with path.open("r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    yield json.loads(line)
                except json.JSONDecodeError:
                    # A truncated tail line during concurrent write. Skip
                    # rather than abort: the user is debugging, not
                    # forensically auditing.
                    continue


def _filter(
    events: Iterable[dict],
    *,
    since: datetime | None,
    category: str | None,
    action: str | None,
) -> Iterator[dict]:
    for ev in events:
        if category and ev.get("category") != category:
            continue
        if action and ev.get("action") != action:
            continue
        if since is not None:
            ts = ev.get("ts")
            if not ts:
                continue
            try:
                ev_dt = datetime.fromisoformat(str(ts).replace("Z", "+00:00"))
            except ValueError:
                continue
            if ev_dt < since:
                continue
        yield ev


def _format(ev: dict) -> str:
    ts = ev.get("ts", "?")
    cat = ev.get("category", "?")
    action = ev.get("action", "?")
    skip = {"ts", "category", "action"}
    rest = {k: v for k, v in ev.items() if k not in skip}
    rest_str = " ".join(f"{k}={json.dumps(v, default=str)}" for k, v in sorted(rest.items()))
    return f"{ts}  {cat:<11} {action:<22} {rest_str}".rstrip()


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(
        prog="mp logs",
        description="Filter and pretty-print meeting-pipe JSONL events.",
    )
    p.add_argument("--since", help="ISO timestamp or relative (e.g. 1h, 30m, 2d).")
    p.add_argument("--category", help="Match exact category (e.g. detector, coordinator, pipeline).")
    p.add_argument("--action", help="Match exact action (e.g. started, ended, run_failed).")
    p.add_argument("--json", action="store_true", help="Emit matched events as JSONL on stdout.")
    args = p.parse_args(argv)

    since = _parse_since(args.since) if args.since else None
    matched = list(_filter(_iter_events(),
                            since=since, category=args.category, action=args.action))
    matched.sort(key=lambda e: e.get("ts", ""))

    if args.json:
        for ev in matched:
            sys.stdout.write(json.dumps(ev, sort_keys=True) + "\n")
        return 0

    for ev in matched:
        print(_format(ev))
    return 0
