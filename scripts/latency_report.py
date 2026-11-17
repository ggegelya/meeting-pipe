#!/usr/bin/env python3
"""OBS7: click-to-feedback latency per action and per build, from `events.jsonl`.

Reads the `ui` rows the daemon writes (`ui_action`, `ui_feedback`, `first_paint`,
`window_opened`) through the same reader the dogfood report uses (every rotated generation,
test residue dropped) and prints, per action and per build: n, median, p90 and max of

  - `ui_feedback.ms`        click to the first visible state, measured on the next main turn
  - click to first paint    `first_paint.ms` on the rows that carry the click's `seq`
  - click to completion     `ui_action` to the next `recording_started` (a start click) or
                            `recording_stopped` (a stop click) row, wall-clock `ts`
  p90 is nearest-rank, so on fewer than ten samples it equals the max.
  - `window_opened.ms_to_key`

Builds are split at each `app_rebuild` row (labelled by its `new_cdhash`), or by a `build`
attribute on the row when DIST6's build stamp is present. Rows before any marker are `(unknown)`.

Read-only: nothing is written unless `--out` is given. Stdlib only.

Usage:
  scripts/latency_report.py                  # all history
  scripts/latency_report.py --since 2026-11-17
  scripts/latency_report.py --json
  scripts/latency_report.py --events <path>
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import statistics
import sys
from collections import defaultdict
from datetime import datetime
from pathlib import Path

_DOGFOOD = Path(__file__).resolve().parent / "dogfood_report.py"
_spec = importlib.util.spec_from_file_location("dogfood_report", _DOGFOOD)
assert _spec and _spec.loader
dogfood = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(dogfood)

# A completion row more than this long after the click belongs to something else.
COMPLETION_WINDOW_SECONDS = 120.0
_COMPLETIONS = ("recording_started", "recording_stopped")
# Which completion row answers which click. A toggle is a start or a stop depending on state, so
# either row answers it; a click absent here (a window open, a Skip) has no completion row.
_ANSWERED_BY = {
    "recording_started": {
        "prompt_record", "prompt_record_byo", "prompt_always", "menu_start", "hotkey_toggle",
        "automation_toggle", "automation_record", "notification_record",
    },
    "recording_stopped": {
        "hud_stop", "menu_stop", "notification_stop", "automation_stop", "automation_toggle",
        "hotkey_toggle", "hotkey_force_stop",
    },
}
UNKNOWN_BUILD = "(unknown)"


def _stats(values: list[float]) -> dict:
    if not values:
        return {"n": 0, "median": None, "p90": None, "max": None}
    return {
        "n": len(values),
        "median": round(float(statistics.median(values)), 1),
        "p90": round(float(dogfood._percentile(values, 90)), 1),
        "max": round(float(max(values)), 1),
    }


def _build_label(event: dict) -> str | None:
    stamp = event.get("build")
    if isinstance(stamp, str) and stamp:
        return stamp
    if event.get("action") == "app_rebuild":
        cdhash = event.get("new_cdhash")
        if isinstance(cdhash, str) and cdhash:
            return cdhash[:8]
    return None


def build_report(events: list[dict]) -> dict:
    """{build: {metric: {action_or_window: stats}}}, builds in first-seen order."""
    # (build, metric, key) -> samples
    samples: dict[tuple[str, str, str], list[float]] = defaultdict(list)
    build = UNKNOWN_BUILD
    actions: dict[int, tuple[str, str, datetime | None]] = {}  # seq -> (build, action, ts)
    builds_seen: list[str] = []
    # clicks still waiting for a completion row, in order
    waiting: list[tuple[str, str, datetime]] = []

    def note_build(label: str) -> None:
        if label not in builds_seen:
            builds_seen.append(label)

    note_build(build)
    for event in events:
        label = _build_label(event)
        if label is not None:
            build = label
            note_build(build)
            waiting = []  # a relaunch ends every click still waiting on the old process
        category, action = event.get("category"), event.get("action")
        ts = dogfood._parse_ts(event.get("ts"))

        if category == "ui" and action == "ui_action" and isinstance(event.get("seq"), int):
            # `name`, not `action`: `Log.event` writes the row type into `action` last.
            actions[event["seq"]] = (build, str(event.get("name")), ts)
        elif category == "ui" and action == "ui_feedback":
            ref = actions.get(event.get("seq"))
            if ref and isinstance(event.get("ms"), (int, float)):
                samples[(ref[0], "feedback_ms", ref[1])].append(event["ms"])
        elif category == "ui" and action == "first_paint":
            ref = actions.get(event.get("seq"))
            if ref and isinstance(event.get("ms"), (int, float)):
                samples[(ref[0], "first_paint_ms", ref[1])].append(event["ms"])
        elif category == "ui" and action == "window_opened":
            ms = event.get("ms_to_key")
            if isinstance(ms, (int, float)):
                samples[(build, "window_ms_to_key", str(event.get("window")))].append(ms)
        elif category == "coordinator" and action in _COMPLETIONS and ts is not None:
            # The first completion after a click answers it; one that came too late answers nothing.
            for b, name, at in waiting:
                delta = (ts - at).total_seconds()
                if 0 <= delta <= COMPLETION_WINDOW_SECONDS and name in _ANSWERED_BY[str(action)]:
                    samples[(b, "completion_ms", name)].append(delta * 1000)
            # Clicks this completion cannot answer stay; a later one may.
            waiting = [
                w for w in waiting
                if w[1] not in _ANSWERED_BY[str(action)] and (ts - w[2]).total_seconds() <= COMPLETION_WINDOW_SECONDS
            ]
        if category == "ui" and action == "ui_action" and ts is not None:
            ref = actions.get(event.get("seq"))
            if ref:
                waiting.append((ref[0], ref[1], ts))

    report: dict[str, dict[str, dict[str, dict]]] = {}
    for b in builds_seen:
        per_metric: dict[str, dict[str, dict]] = {}
        for (sb, metric, key), values in sorted(samples.items()):
            if sb == b:
                per_metric.setdefault(metric, {})[key] = _stats(values)
        if per_metric:
            report[b] = per_metric
    return report


_TITLES = {
    "feedback_ms": "click to first visible state (ui_feedback.ms)",
    "first_paint_ms": "click to first paint (first_paint.ms)",
    "completion_ms": "click to completion row (recording_started / recording_stopped)",
    "window_ms_to_key": "window open to key (window_opened.ms_to_key)",
}


def render_markdown(report: dict) -> str:
    if not report:
        return "No `ui` rows found. The daemon writes them from the OBS7 build on.\n"
    out: list[str] = []
    for build, metrics in report.items():
        out.append(f"## build {build}\n")
        for metric, title in _TITLES.items():
            rows = metrics.get(metric)
            if not rows:
                continue
            out.append(f"### {title}\n")
            out.append("| key | n | median ms | p90 ms | max ms |")
            out.append("|---|---:|---:|---:|---:|")
            for key, s in rows.items():
                out.append(f"| {key} | {s['n']} | {s['median']} | {s['p90']} | {s['max']} |")
            out.append("")
    return "\n".join(out)


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description="MeetingPipe click-to-feedback latency report.")
    ap.add_argument("--events", type=Path, default=dogfood.DEFAULT_DIR / "events.jsonl")
    ap.add_argument("--since", type=str, default=None)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)
    since = dogfood._parse_ts(args.since) if args.since else None
    if args.since and since is None:
        print(f"error: could not parse --since {args.since!r}", file=sys.stderr)
        return 2
    report = build_report(dogfood._load(args.events, since))
    print(json.dumps(report, indent=2) if args.json else render_markdown(report))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
