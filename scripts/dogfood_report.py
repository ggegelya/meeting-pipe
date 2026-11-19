#!/usr/bin/env python3
"""TECH-E4: dogfood acceptance-bar report over the MeetingPipe event logs.

Leave the daemon on through a normal workday (or a `MEETING_PIPE_DRY_RUN=1`
session) and run this to see how detection, mic-gating, and the pipeline
actually behaved across the real distribution of meetings, without opening a
single `.wav`. It is the "is detection still good?" / "is gating sane?" read,
distinct from `mp dogfood`, which A/B-scores summary quality on one transcript.

Reads, by default:
  ~/Library/Logs/MeetingPipe/events.jsonl           (daemon: lifecycle, coordinator, micgate)
  ~/Library/Logs/MeetingPipe/pipeline_events.jsonl  (pipeline: run_*/stage_*, publisher sinks)

Usage:
  scripts/dogfood_report.py                       # full report, all history
  scripts/dogfood_report.py --since 2026-06-01    # only events at/after a timestamp
  scripts/dogfood_report.py --json                # machine-readable
  scripts/dogfood_report.py --out report.md       # write markdown to a file
  scripts/dogfood_report.py --events <p> --pipeline-events <p>

Stdlib only, so it runs on a clean Mac without `uv`.
"""
from __future__ import annotations

import argparse
import json
import re
import statistics
import sys
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath

DEFAULT_DIR = Path("~/Library/Logs/MeetingPipe").expanduser()


def _parse_ts(raw: object) -> datetime | None:
    if not isinstance(raw, str) or not raw:
        return None
    try:
        parsed = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return None
    # A date-only --since (or any naive input) is treated as UTC so it compares
    # cleanly against the UTC event timestamps.
    # Not `datetime.UTC` (3.11+): this script runs under macOS's system Python 3.9.
    return parsed if parsed.tzinfo is not None else parsed.replace(tzinfo=timezone.utc)  # noqa: UP017


def _log_files(path: Path) -> list[Path]:
    """PERF7: the base log plus its rotated generations (`events.1.jsonl`, ...),
    oldest first, so the report still sees the recent window after rotation.
    Stdlib-only mirror of mp.events.log_generations (this script imports no mp)."""
    numbered: list[tuple[int, Path]] = []
    for g in path.parent.glob(f"{path.stem}.*{path.suffix}"):
        mid = g.name[len(path.stem) + 1 : len(g.name) - len(path.suffix)]
        if mid.isdigit():
            numbered.append((int(mid), g))
    files = [g for _, g in sorted(numbered, reverse=True)]
    if path.exists():
        files.append(path)
    return files


REAL_ENGINE = "fluidaudio"
_REAL_STEM = re.compile(r"^\d{8}-\d{6}$")
_MEETING_KEYS = ("file", "stem", "wav", "meeting", "primary", "fragments")


def _is_test_residue(event: dict) -> bool:
    """True when a row in the real log was written by a test suite, not by the app.

    Stdlib-only mirror of mp.events.is_test_residue (this script imports no mp); keep the
    two in step. Both suites wrote into the user's real log before their harnesses were
    isolated, and those rows are permanent: they sit in rotated generations nothing
    rewrites, and _log_files reads every generation. Without this filter the report counts
    meetings that never happened. It read 250 `pipeline_failed` against 0 real ones.

    Not exhaustive, and cannot be: test rows naming no meeting (`coordinator.state_change`)
    are byte-identical to real ones. Those inflate benign counters but fabricate no
    failures. See CONVENTIONS.md "Event log schema".
    """
    if event.get("category") == "transcription":
        engine = event.get("engine")
        if isinstance(engine, str) and engine != REAL_ENGINE:
            return True
    for key in _MEETING_KEYS:
        value = event.get(key)
        for item in value if isinstance(value, list) else [value]:
            if isinstance(item, str) and item:
                if not _REAL_STEM.match(PurePosixPath(item).name.split(".")[0]):
                    return True
    return False


DIAGNOSTICS = "diagnostics.jsonl"


def _daemon_files(path: Path) -> list[Path]:
    """OBS9: the daemon's rows are two families. `diagnostics.jsonl` beside `events.jsonl`
    holds the high-volume ones (HAL subscribe churn, process-audio resolution,
    `call_teardown_source_missing`), which used to share `events.jsonl`."""
    return _log_files(path) + _log_files(path.with_name(DIAGNOSTICS))


def _load(path: Path, since: datetime | None, *, files: list[Path] | None = None) -> list[dict]:
    events: list[dict] = []
    for source in (files if files is not None else _log_files(path)):
        for line in source.read_text(encoding="utf-8", errors="ignore").splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(event, dict):
                continue
            if _is_test_residue(event):
                continue
            if since is not None:
                ts = _parse_ts(event.get("ts"))
                if ts is not None and ts < since:
                    continue
            events.append(event)
    return events


def _is(event: dict, category: str, action: str) -> bool:
    return event.get("category") == category and event.get("action") == action


def _percentile(values: list[float], pct: float) -> float:
    """Nearest-rank percentile; stdlib-only, safe on tiny samples."""
    if not values:
        return 0.0
    ordered = sorted(values)
    rank = max(0, min(len(ordered) - 1, round(pct / 100.0 * len(ordered) + 0.5) - 1))
    return ordered[rank]


def _stage_durations(pipeline_events: list[dict]) -> dict[str, list[float]]:
    """Pair stage_started/stage_completed by stage name and collect seconds.

    Runs are serial (one pipeline job at a time), so keying by stage name does
    not mispair across overlapping runs.
    """
    durations: dict[str, list[float]] = defaultdict(list)
    open_stage: dict[str, datetime] = {}
    for event in pipeline_events:
        ts = _parse_ts(event.get("ts"))
        if ts is None:
            continue
        if _is(event, "pipeline", "stage_started"):
            open_stage[str(event.get("stage", "?"))] = ts
        elif _is(event, "pipeline", "stage_completed"):
            stage = str(event.get("stage", "?"))
            start = open_stage.pop(stage, None)
            if start is not None:
                durations[stage].append((ts - start).total_seconds())
    return dict(durations)


def build_report(daemon_events: list[dict], pipeline_events: list[dict]) -> dict:
    """Aggregate the two event streams into a structured report (pure)."""
    lifecycle = Counter()
    ended_by_signal = Counter()
    for event in daemon_events:
        if event.get("category") == "lifecycle":
            lifecycle[str(event.get("action"))] += 1
            if event.get("action") == "ended":
                ended_by_signal[str(event.get("leading_signal", "unknown"))] += 1

    coordinator = Counter(
        str(e.get("action")) for e in daemon_events if e.get("category") == "coordinator"
    )

    micgate_verdicts = Counter(
        str(e.get("verdict", "unknown"))
        for e in daemon_events
        if _is(e, "micgate", "verdict_changed")
    )
    # OBS9: reason swaps and RMS opens and closes that wrote no `verdict_changed` row.
    micgate_churn = Counter()
    for e in daemon_events:
        if _is(e, "micgate", "verdict_churn"):
            for key in ("reason_swaps", "rms_opens", "rms_closes"):
                micgate_churn[key] += int(e.get(key, 0) or 0)

    run_skipped_reason = Counter(
        str(e.get("reason", "unknown"))
        for e in pipeline_events
        if _is(e, "pipeline", "run_skipped")
    )
    pipeline_runs = {
        "started": sum(1 for e in pipeline_events if _is(e, "pipeline", "run_started")),
        "completed": sum(1 for e in pipeline_events if _is(e, "pipeline", "run_completed")),
        "skipped": sum(run_skipped_reason.values()),
        "failed": sum(1 for e in pipeline_events if _is(e, "pipeline", "run_failed")),
    }

    sinks: dict[str, dict[str, int]] = defaultdict(lambda: {"completed": 0, "failed": 0})
    for event in pipeline_events:
        if _is(event, "publisher", "sink_completed"):
            sinks[str(event.get("sink", "?"))]["completed"] += 1
        elif _is(event, "publisher", "sink_failed"):
            sinks[str(event.get("sink", "?"))]["failed"] += 1

    stage_stats = {}
    for stage, secs in _stage_durations(pipeline_events).items():
        stage_stats[stage] = {
            "n": len(secs),
            "mean": round(statistics.fmean(secs), 2),
            "median": round(statistics.median(secs), 2),
            "p95": round(_percentile(secs, 95), 2),
        }

    timestamps = [
        ts
        for ts in (_parse_ts(e.get("ts")) for e in (daemon_events + pipeline_events))
        if ts is not None
    ]
    window = {
        "first": min(timestamps).isoformat() if timestamps else None,
        "last": max(timestamps).isoformat() if timestamps else None,
    }

    return {
        "window": window,
        "counts": {"daemon_events": len(daemon_events), "pipeline_events": len(pipeline_events)},
        "detection": {
            "lifecycle": dict(lifecycle),
            "ended_by_leading_signal": dict(ended_by_signal),
            "coordinator": dict(coordinator),
        },
        "micgate": {"verdict_changed": dict(micgate_verdicts), "verdict_churn": dict(micgate_churn)},
        "pipeline": {
            "runs": pipeline_runs,
            "skipped_by_reason": dict(run_skipped_reason),
            "stage_seconds": stage_stats,
            "sinks": {k: dict(v) for k, v in sinks.items()},
        },
    }


def _fmt_counter(counter: dict, indent: str = "  ") -> str:
    if not counter:
        return f"{indent}(none)"
    rows = sorted(counter.items(), key=lambda kv: (-kv[1], kv[0]))
    return "\n".join(f"{indent}- {name}: {count}" for name, count in rows)


def render_markdown(report: dict) -> str:
    win = report["window"]
    counts = report["counts"]
    det = report["detection"]
    pipe = report["pipeline"]
    lines: list[str] = []
    lines.append("# MeetingPipe dogfood report")
    lines.append("")
    span = f"{win['first']} .. {win['last']}" if win["first"] else "(no events in range)"
    lines.append(f"Window: {span}")
    lines.append(
        f"Source: {counts['daemon_events']} daemon events, "
        f"{counts['pipeline_events']} pipeline events"
    )
    lines.append("")
    lines.append("## Detection")
    lines.append(f"Lifecycle verdicts:\n{_fmt_counter(det['lifecycle'])}")
    lines.append(f"Ends, by leading signal:\n{_fmt_counter(det['ended_by_leading_signal'])}")
    lines.append(f"Coordinator actions:\n{_fmt_counter(det['coordinator'])}")
    lines.append("")
    lines.append("## Mic gate")
    lines.append(f"Verdict transitions:\n{_fmt_counter(report['micgate']['verdict_changed'])}")
    lines.append(f"Unlogged churn:\n{_fmt_counter(report['micgate']['verdict_churn'])}")
    lines.append("")
    lines.append("## Pipeline")
    runs = pipe["runs"]
    lines.append(
        f"Runs: {runs['completed']} completed, {runs['skipped']} skipped, "
        f"{runs['failed']} failed (of {runs['started']} started)"
    )
    if pipe["skipped_by_reason"]:
        lines.append(f"Skipped, by reason:\n{_fmt_counter(pipe['skipped_by_reason'])}")
    if pipe["stage_seconds"]:
        lines.append("")
        lines.append("Stage timings (seconds):")
        lines.append("")
        lines.append("| stage | n | mean | median | p95 |")
        lines.append("|---|---|---|---|---|")
        for stage, s in sorted(pipe["stage_seconds"].items()):
            lines.append(f"| {stage} | {s['n']} | {s['mean']} | {s['median']} | {s['p95']} |")
    if pipe["sinks"]:
        lines.append("")
        lines.append("Publishers:")
        for sink, s in sorted(pipe["sinks"].items()):
            lines.append(f"  - {sink}: {s['completed']} completed, {s['failed']} failed")
    lines.append("")
    return "\n".join(lines)


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description="MeetingPipe dogfood acceptance-bar report.")
    ap.add_argument("--events", type=Path, default=DEFAULT_DIR / "events.jsonl",
                    help="daemon events.jsonl path")
    ap.add_argument("--pipeline-events", type=Path,
                    default=DEFAULT_DIR / "pipeline_events.jsonl",
                    help="pipeline_events.jsonl path")
    ap.add_argument("--since", type=str, default=None,
                    help="ISO8601 lower bound, e.g. 2026-06-01 or 2026-06-01T00:00:00Z")
    ap.add_argument("--json", action="store_true", help="emit the structured report as JSON")
    ap.add_argument("--out", type=Path, default=None, help="write the report to a file")
    args = ap.parse_args(argv)

    since = _parse_ts(args.since) if args.since else None
    if args.since and since is None:
        print(f"error: could not parse --since {args.since!r}", file=sys.stderr)
        return 2

    daemon = _load(args.events, since, files=_daemon_files(args.events))
    daemon.sort(key=lambda e: str(e.get("ts", "")))
    report = build_report(daemon, _load(args.pipeline_events, since))
    rendered = json.dumps(report, indent=2) if args.json else render_markdown(report)

    if args.out is not None:
        args.out.write_text(rendered + "\n", encoding="utf-8")
        print(f"wrote {args.out}")
    else:
        print(rendered)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
