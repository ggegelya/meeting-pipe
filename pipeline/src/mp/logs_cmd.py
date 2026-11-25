"""`mp logs` — pretty-print filtered events from the JSONL event streams.

Sources, in the logs folder (``events.logs_dir()``: ``MEETINGPIPE_LOGS_DIR`` when set,
else ``~/Library/Logs/MeetingPipe``):
  events.jsonl          (Swift daemon)
  pipeline_events.jsonl (Python pipeline)
  diagnostics.jsonl     (Swift daemon, high-volume rows, OBS9)

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
import sys
from collections.abc import Iterable, Iterator
from datetime import datetime

from . import events as events_mod

SOURCES = ("events.jsonl", "pipeline_events.jsonl", "diagnostics.jsonl")


def _iter_events(skipped: events_mod.SkipCounter | None = None) -> Iterator[dict]:
    # HYG16: the folder is resolved per call, so `MEETINGPIPE_LOGS_DIR` holds here as it
    # does for both writers; a module-level path froze the real one at import.
    logs = events_mod.logs_dir()
    for name in SOURCES:
        # PERF7: read the base log plus its rotated generations, so `mp logs`
        # keeps working on the recent window after a rotation. A torn line from a
        # concurrent write is skipped, not fatal (the user is debugging, not
        # forensically auditing), but counted (PERF13).
        for path in events_mod.log_generations(logs / name):
            yield from events_mod.iter_jsonl(path, skipped)


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
    skip = {"ts", "category", "action", "launch_id"}  # OBS5: on every daemon row, noise in a listing
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

    since = events_mod.parse_since(args.since) if args.since else None
    skipped = events_mod.SkipCounter()
    matched = list(_filter(_iter_events(skipped),
                            since=since, category=args.category, action=args.action))
    matched.sort(key=lambda e: e.get("ts", ""))
    skipped.report()

    if args.json:
        for ev in matched:
            sys.stdout.write(json.dumps(ev, sort_keys=True) + "\n")
        return 0

    for ev in matched:
        print(_format(ev))
    return 0
