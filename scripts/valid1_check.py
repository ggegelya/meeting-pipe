#!/usr/bin/env python3
"""TECH-VALID1 helper: read the MeetingPipe event logs and surface the numbers
the on-device acceptance bars (A15 / A16 / DIAR1 / SUM1-APPLE / UX4) are graded
against.

This does NOT replace the real acceptance run: cold-start latency, DER, Apple
Intelligence quality, and zero-egress-via-Little-Snitch are measured by running
the app on a real Apple-Silicon Mac. What this does is turn the JSONL the daemon
and pipeline already write into a glance-readable report, and make the one
event-shaped bar (UX4) a hard pass/fail.

Reads, by default:
  ~/Library/Logs/MeetingPipe/events.jsonl           (daemon: recording.degraded/recovered, ...)
  ~/Library/Logs/MeetingPipe/pipeline_events.jsonl  (pipeline: run_*/stage_* with a `stage` attr)

Usage:
  scripts/valid1_check.py                 # UX4 check + the latest runs' stage timings
  scripts/valid1_check.py --ux4           # only the UX4 degraded/recovered assertion (exit 1 on fail)
  scripts/valid1_check.py --timings       # only the run/stage timing table
  scripts/valid1_check.py --since 2026-06-03T00:00:00Z
  scripts/valid1_check.py --events <path> --pipeline-events <path>

Stdlib only, so it runs on a clean Mac without `uv`.
"""
from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime
from pathlib import Path

DEFAULT_DIR = Path("~/Library/Logs/MeetingPipe").expanduser()


def _parse_ts(raw: object) -> datetime | None:
    if not isinstance(raw, str) or not raw:
        return None
    try:
        return datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return None


def _load(path: Path, since: datetime | None) -> list[dict]:
    if not path.exists():
        return []
    events: list[dict] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(event, dict):
            continue
        if since is not None:
            ts = _parse_ts(event.get("ts"))
            if ts is not None and ts < since:
                continue
        events.append(event)
    return events


def _key(event: dict) -> str:
    return f"{event.get('category', '?')}.{event.get('action', '?')}"


def check_ux4(daemon_events: list[dict]) -> bool:
    """UX4: a real failed SCStream must surface `recording.degraded` (and ideally
    a later `recording.recovered`). Pass when at least one degraded event exists.
    """
    degraded = [e for e in daemon_events if _key(e) == "recording.degraded"]
    recovered = [e for e in daemon_events if _key(e) == "recording.recovered"]
    print("== UX4: live degraded banner + recording.degraded event ==")
    if not degraded:
        print("  FAIL  no recording.degraded event found.")
        print("        Force a real SCStream failure (revoke Screen Recording mid-call,")
        print("        or stop the capture target) and confirm the HUD banner appears.")
        return False
    for e in degraded:
        print(f"  degraded  {e.get('ts', '?')}  reason={e.get('reason', '?')}")
    for e in recovered:
        print(f"  recovered {e.get('ts', '?')}")
    print(f"  PASS  {len(degraded)} degraded, {len(recovered)} recovered.")
    return True


def report_timings(pipeline_events: list[dict]) -> None:
    """Pair run_started/run_completed and stage_started/stage_completed (by
    `stage`) and print elapsed seconds. Feeds the A15 cold-start, A16 latency,
    and DIAR1 under-10s reads; thresholds live in the runbook, not here.
    """
    print("== Run + stage timings (A15 cold-start / A16 latency / DIAR1) ==")
    open_runs: list[datetime] = []
    open_stages: dict[str, datetime] = {}
    any_row = False
    for e in pipeline_events:
        key = _key(e)
        ts = _parse_ts(e.get("ts"))
        if ts is None:
            continue
        if key == "pipeline.run_started":
            open_runs.append(ts)
        elif key == "pipeline.run_completed" and open_runs:
            start = open_runs.pop(0)
            print(f"  run        {start.isoformat()}  ->  {(ts - start).total_seconds():7.2f} s total")
            any_row = True
        elif key == "pipeline.stage_started":
            open_stages[str(e.get("stage", "?"))] = ts
        elif key == "pipeline.stage_completed":
            stage = str(e.get("stage", "?"))
            start = open_stages.pop(stage, None)
            if start is not None:
                print(f"    stage {stage:<16} {(ts - start).total_seconds():7.2f} s")
                any_row = True
    if not any_row:
        print("  (no completed runs in range; run a meeting through the pipeline first.)")


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description="MeetingPipe VALID1 acceptance helper.")
    ap.add_argument("--events", type=Path, default=DEFAULT_DIR / "events.jsonl",
                    help="daemon events.jsonl path")
    ap.add_argument("--pipeline-events", type=Path, default=DEFAULT_DIR / "pipeline_events.jsonl",
                    help="pipeline_events.jsonl path")
    ap.add_argument("--since", type=str, default=None,
                    help="ISO8601 lower bound, e.g. 2026-06-03T00:00:00Z")
    ap.add_argument("--ux4", action="store_true", help="only the UX4 assertion")
    ap.add_argument("--timings", action="store_true", help="only the timing table")
    args = ap.parse_args(argv)

    since = _parse_ts(args.since) if args.since else None
    if args.since and since is None:
        print(f"error: could not parse --since {args.since!r}", file=sys.stderr)
        return 2

    daemon_events = _load(args.events, since)
    pipeline_events = _load(args.pipeline_events, since)

    run_ux4 = args.ux4 or not args.timings
    run_timings = args.timings or not args.ux4

    ok = True
    if run_ux4:
        ok = check_ux4(daemon_events) and ok
        if run_timings:
            print()
    if run_timings:
        report_timings(pipeline_events)

    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
