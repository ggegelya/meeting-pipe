"""`mp analyze-detection`: audit how often meeting-end detection
misses the "meeting ended" signal.

Pairs each `coordinator.recording_started` with the next
`coordinator.recording_stopped` from the Swift event stream
(`~/Library/Logs/MeetingPipe/events.jsonl`). For each session, scans
for a `lifecycle.ended` event in between, and for the non-detector stop
causes that land inside a session window (`coordinator.auto_stop_silence`,
`coordinator.force_stop`), so the report tells a silence-backstop auto-stop
and a force-stop hotkey apart from a genuine manual stop. Only a true manual
stop (no detector end, no backstop, no force-stop) counts as a miss:
the failure mode the lifecycle subsystem exists to reduce. Crash-orphaned
recordings (a `recording_started` with no `recording_stopped`, recovered at
the next launch) are out of scope: that session is unterminated, so it is
not paired and does not appear in the audit.

Pure functions (`iter_events`, `pair_sessions`, `classify_session`,
`aggregate`, `render_report`) are kept side-effect-free so the same
pipeline runs against captured fixtures in the test suite. Only `main`
touches the filesystem.
"""
from __future__ import annotations

import argparse
import json
import os
import statistics
import sys
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Iterable, Iterator

DEFAULT_EVENTS_PATH = Path(os.path.expanduser("~/Library/Logs/MeetingPipe/events.jsonl"))

# Pairing window: any `lifecycle.ended` whose timestamp falls within the
# session's [started, stopped] interval is treated as the trigger.
# We do not bound how far before `recording_stopped` it can be: the
# lifecycle verdict stream drives `stopRecording`, so the two events are
# normally <100 ms apart, but `Recorder.stop` is async and can take
# seconds to flush, which would make a tight window flag real successes
# as misses.

# Stop kinds, in classification priority order. A genuine `manual` stop is
# the only one that counts as a detector miss.
STOP_DETECTOR = "detector"
STOP_SILENCE_BACKSTOP = "silence_backstop"
STOP_FORCE_STOP = "force_stop"
STOP_MANUAL = "manual"


def _is_silence_reason(reason: str | None) -> bool:
    """A `coordinator.force_stop` whose reason names silence is really the
    silence backstop firing (e.g. legacy `mic_only_silence`), not a user
    hotkey, so it must not inflate the force-stop / miss counts."""
    return bool(reason) and "silence" in reason.lower()


@dataclass
class Session:
    started_ts: datetime
    stopped_ts: datetime
    bundle_id: str  # "manual" for hotkey-only sessions (no AppSource)
    file: str
    detector_ended_ts: datetime | None = None
    # Non-detector stop causes observed inside the [started, stopped] window.
    auto_stopped: bool = False  # coordinator.auto_stop_silence fired
    force_stop_reason: str | None = None  # coordinator.force_stop reason attr
    # Filled by classify_session.
    # "detector" | "silence_backstop" | "force_stop" | "manual" | "unknown"
    stop_kind: str = "unknown"
    delta_sec: float | None = None  # stopped - detector.ended, only when detector-triggered

    @property
    def duration_sec(self) -> float:
        return (self.stopped_ts - self.started_ts).total_seconds()


@dataclass
class AppStats:
    bundle_id: str
    total: int = 0
    detector_triggered: int = 0
    silence_backstop: int = 0
    force_stop: int = 0
    manual: int = 0
    deltas: list[float] = field(default_factory=list)

    @property
    def detector_pct(self) -> float:
        return (self.detector_triggered / self.total * 100.0) if self.total else 0.0

    @property
    def backstop_pct(self) -> float:
        return (self.silence_backstop / self.total * 100.0) if self.total else 0.0

    @property
    def manual_pct(self) -> float:
        return (self.manual / self.total * 100.0) if self.total else 0.0

    @property
    def delta_p50(self) -> float | None:
        return statistics.median(self.deltas) if self.deltas else None

    @property
    def delta_p95(self) -> float | None:
        if not self.deltas:
            return None
        # statistics.quantiles needs n>=2; fall back to max for tiny samples.
        if len(self.deltas) < 2:
            return self.deltas[0]
        return statistics.quantiles(self.deltas, n=20)[18]  # 95th percentile

    @property
    def delta_max(self) -> float | None:
        return max(self.deltas) if self.deltas else None


def _parse_ts(s: str) -> datetime:
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def iter_events(path: Path) -> Iterator[dict]:
    """Yield every well-formed JSON event from ``path``.

    Skips truncated tail lines silently so a live-tailed file does not
    crash the analyzer mid-workday.
    """
    if not path.exists():
        return
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                continue


def pair_sessions(events: Iterable[dict], *, since: datetime | None = None) -> list[Session]:
    """Walk events in timestamp order, pairing each ``recording_started``
    with the next ``recording_stopped`` on the same file. Out-of-pair
    ``lifecycle.ended`` events and the non-detector stop-cause markers
    (``auto_stop_silence`` / ``force_stop``) between the two are recorded on
    the session so ``classify_session`` can tell the real stop cause apart
    from a manual stop.

    ``since`` filters by ``recording_started`` timestamp.
    """
    ordered = sorted(
        (e for e in events if "ts" in e),
        key=lambda e: e["ts"],
    )

    sessions: list[Session] = []
    open_session: Session | None = None

    for ev in ordered:
        try:
            ts = _parse_ts(str(ev["ts"]))
        except (TypeError, ValueError):
            continue
        cat = ev.get("category")
        action = ev.get("action")

        if cat == "coordinator" and action == "recording_started":
            if since is not None and ts < since:
                continue
            open_session = Session(
                started_ts=ts,
                stopped_ts=ts,  # placeholder; overwritten at stop
                bundle_id=str(ev.get("bundle_id") or "manual"),
                file=str(ev.get("file") or ""),
            )
        elif open_session is None:
            continue
        elif cat == "lifecycle" and action == "ended":
            # Record the latest lifecycle.ended inside the open window.
            # If multiple fire (debounce flutter), the last one is what
            # actually drove the stop.
            open_session.detector_ended_ts = ts
        elif cat == "coordinator" and action == "auto_stop_silence":
            open_session.auto_stopped = True
        elif cat == "coordinator" and action == "force_stop":
            open_session.force_stop_reason = str(ev.get("reason") or "")
        elif cat == "coordinator" and action == "recording_stopped":
            open_session.stopped_ts = ts
            # File attribute on `recording_stopped` is authoritative —
            # `recording_started` may have logged a placeholder if the
            # source was nil at start.
            file_attr = ev.get("file")
            if file_attr:
                open_session.file = str(file_attr)
            sessions.append(open_session)
            open_session = None

    return sessions


def classify_session(session: Session) -> Session:
    """Set ``stop_kind`` and ``delta_sec``. Pure; returns the same object.

    Priority: a detector end wins (it drove the stop); else a silence
    backstop (the auto-stop event, or a force-stop whose reason names
    silence); else a user force-stop hotkey; else a genuine manual stop,
    the only kind that counts as a miss.
    """
    if session.detector_ended_ts is not None:
        session.stop_kind = STOP_DETECTOR
        session.delta_sec = (session.stopped_ts - session.detector_ended_ts).total_seconds()
        return session

    session.delta_sec = None
    if session.auto_stopped or _is_silence_reason(session.force_stop_reason):
        session.stop_kind = STOP_SILENCE_BACKSTOP
    elif session.force_stop_reason is not None:
        session.stop_kind = STOP_FORCE_STOP
    else:
        session.stop_kind = STOP_MANUAL
    return session


def aggregate(sessions: Iterable[Session]) -> dict[str, AppStats]:
    """Group classified sessions by ``bundle_id``."""
    stats: dict[str, AppStats] = {}
    for s in sessions:
        bucket = stats.setdefault(s.bundle_id, AppStats(bundle_id=s.bundle_id))
        bucket.total += 1
        if s.stop_kind == STOP_DETECTOR:
            bucket.detector_triggered += 1
            if s.delta_sec is not None:
                bucket.deltas.append(s.delta_sec)
        elif s.stop_kind == STOP_SILENCE_BACKSTOP:
            bucket.silence_backstop += 1
        elif s.stop_kind == STOP_FORCE_STOP:
            bucket.force_stop += 1
        elif s.stop_kind == STOP_MANUAL:
            bucket.manual += 1
    return stats


def _format_delta(seconds: float | None) -> str:
    return f"{seconds:.1f}s" if seconds is not None else "n/a"


def _format_duration(seconds: float) -> str:
    if seconds < 60:
        return f"{seconds:.0f}s"
    m, s = divmod(int(seconds), 60)
    if m < 60:
        return f"{m}m{s:02d}s"
    h, m = divmod(m, 60)
    return f"{h}h{m:02d}m"


def render_report(sessions: list[Session], stats: dict[str, AppStats]) -> str:
    """Render a markdown audit report. Empty input still produces a
    valid skeleton so the caller can pipe it without branching."""
    if not sessions:
        return "# Detection Audit\n\n_No recording sessions found in event stream._\n"

    total = len(sessions)
    detector_count = sum(1 for s in sessions if s.stop_kind == STOP_DETECTOR)
    backstop_count = sum(1 for s in sessions if s.stop_kind == STOP_SILENCE_BACKSTOP)
    force_count = sum(1 for s in sessions if s.stop_kind == STOP_FORCE_STOP)
    manual_count = sum(1 for s in sessions if s.stop_kind == STOP_MANUAL)
    all_deltas = [s.delta_sec for s in sessions if s.delta_sec is not None]

    first_ts = sessions[0].started_ts.isoformat(timespec="seconds")
    last_ts = sessions[-1].stopped_ts.isoformat(timespec="seconds")

    lines: list[str] = []
    lines.append("# Detection Audit")
    lines.append("")
    lines.append(f"Window: `{first_ts}` -> `{last_ts}` · {total} session(s)")
    lines.append("")
    lines.append("## Summary")
    lines.append("")
    lines.append(f"- Detector-triggered stops: **{detector_count}** "
                 f"({detector_count / total * 100:.0f}%)")
    if backstop_count:
        lines.append(f"- Auto-stopped by silence backstop: **{backstop_count}** "
                     f"({backstop_count / total * 100:.0f}%) "
                     f"- the safety net caught a forgotten recording")
    if force_count:
        lines.append(f"- Force-stopped (hotkey): **{force_count}** "
                     f"({force_count / total * 100:.0f}%)")
    lines.append(f"- Manual stops (hotkey / quit): **{manual_count}** "
                 f"({manual_count / total * 100:.0f}%) "
                 f"- the failure mode end-detection should reduce")
    if all_deltas:
        lines.append(
            f"- Detector -> recorder-stopped delta: "
            f"p50 {statistics.median(all_deltas):.1f}s · "
            f"max {max(all_deltas):.1f}s"
        )
    lines.append("")

    lines.append("## Per-source breakdown")
    lines.append("")
    lines.append("| Source app | Sessions | Detector | Backstop | Manual | Median Δ | Max Δ |")
    lines.append("|---|---:|---:|---:|---:|---:|---:|")
    for app in sorted(stats.values(), key=lambda a: a.total, reverse=True):
        lines.append(
            f"| `{app.bundle_id}` | {app.total} "
            f"| {app.detector_triggered} ({app.detector_pct:.0f}%) "
            f"| {app.silence_backstop} ({app.backstop_pct:.0f}%) "
            f"| {app.manual} ({app.manual_pct:.0f}%) "
            f"| {_format_delta(app.delta_p50)} "
            f"| {_format_delta(app.delta_max)} |"
        )
    lines.append("")

    misses = [s for s in sessions if s.stop_kind == STOP_MANUAL]
    lines.append(f"## Detector misses ({len(misses)})")
    lines.append("")
    if not misses:
        lines.append("_None: every session was ended by the detector, the silence "
                     "backstop, a force-stop, or crash recovery._")
        lines.append("")
    else:
        lines.append("Sessions stopped without a preceding `lifecycle.ended` and "
                     "without a backstop / force-stop, so the user had to manually "
                     "stop. Grouped by source app:")
        lines.append("")
        misses_by_app: dict[str, list[Session]] = {}
        for s in misses:
            misses_by_app.setdefault(s.bundle_id, []).append(s)
        for app_id in sorted(misses_by_app.keys(),
                             key=lambda k: len(misses_by_app[k]),
                             reverse=True):
            app_misses = misses_by_app[app_id]
            lines.append(f"### `{app_id}` - {len(app_misses)} miss(es)")
            lines.append("")
            for s in app_misses:
                ts = s.started_ts.isoformat(timespec="seconds")
                dur = _format_duration(s.duration_sec)
                file_label = s.file or "(unknown)"
                lines.append(f"- `{ts}` · {dur} · `{file_label}`")
            lines.append("")

    return "\n".join(lines).rstrip() + "\n"


def _parse_since(s: str) -> datetime:
    s = s.strip()
    if s and s[-1] in "smhd" and s[:-1].isdigit():
        n = int(s[:-1])
        unit = {"s": "seconds", "m": "minutes", "h": "hours", "d": "days"}[s[-1]]
        return datetime.now(timezone.utc) - timedelta(**{unit: n})
    dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(
        prog="mp analyze-detection",
        description=(
            "Audit detector end-signal reliability. Pairs recording sessions "
            "with their detector.ended events and surfaces misses."
        ),
    )
    p.add_argument(
        "--source",
        default=str(DEFAULT_EVENTS_PATH),
        help="Path to events.jsonl (default: ~/Library/Logs/MeetingPipe/events.jsonl).",
    )
    p.add_argument(
        "--since",
        help="ISO timestamp or relative offset (e.g. 7d, 24h) to scope the audit.",
    )
    p.add_argument(
        "--output",
        help="Write the markdown report to this file. Otherwise prints to stdout.",
    )
    p.add_argument(
        "--json",
        action="store_true",
        help="Emit the per-app aggregate as JSON to stdout instead of markdown.",
    )
    args = p.parse_args(argv)

    source = Path(args.source)
    since = _parse_since(args.since) if args.since else None
    raw = list(iter_events(source))
    sessions = [classify_session(s) for s in pair_sessions(raw, since=since)]
    stats = aggregate(sessions)

    if args.json:
        payload = {
            "source": str(source),
            "total_sessions": len(sessions),
            "per_app": {
                bid: {
                    "total": a.total,
                    "detector": a.detector_triggered,
                    "silence_backstop": a.silence_backstop,
                    "force_stop": a.force_stop,
                    "manual": a.manual,
                    "delta_p50_sec": a.delta_p50,
                    "delta_p95_sec": a.delta_p95,
                    "delta_max_sec": a.delta_max,
                }
                for bid, a in stats.items()
            },
            "misses": [
                {
                    "started_ts": s.started_ts.isoformat(),
                    "bundle_id": s.bundle_id,
                    "file": s.file,
                    "duration_sec": s.duration_sec,
                }
                for s in sessions if s.stop_kind == STOP_MANUAL
            ],
        }
        sys.stdout.write(json.dumps(payload, indent=2, default=str) + "\n")
        return 0

    report = render_report(sessions, stats)
    if args.output:
        Path(args.output).write_text(report, encoding="utf-8")
    else:
        sys.stdout.write(report)
    return 0
