"""`mp analyze-detection`: audit meeting detection from both ends.

Two dimensions. **End detection** (the original): pairs each recording session with its
`lifecycle.ended` event and flags the sessions the user had to stop manually. **Start detection**
(DET3): correlates mic-busy spans (`detector.mic_busy_started` / `mic_busy_ended`, the frontmost
app the daemon stamped at grab time) against prompts, recordings, and `candidate_dropped` events,
so a call the whitelist never saw shows up as a "mic was busy, nothing fired" miss. A miss with a
`candidate_dropped` in its window is recognizer rot (a known app scored too low); with only a
`discovery_shadow_pick` it was suppressed (cooldown / skip-latch / consent); with neither it was
never a candidate (an unlisted app, or Accessibility / Screen Recording denied). Brief spans below
`--min-miss-sec` (default 30 s) are excluded so dictation / voice-memo blips are not counted.

Audits how often meeting-end detection misses the "meeting ended" signal.

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

from . import events

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


# DET3: how far outside a mic-busy span a prompt / recording / candidate event may fall and
# still be treated as belonging to it. The meeting app grabs the mic when you join, a beat before
# the detector fires and the prompt shows; the recorder's stop flush also trails. 10 s absorbs
# that skew without letting an unrelated later event count.
MIC_MATCH_GRACE = timedelta(seconds=10)


@dataclass
class MicBusySpan:
    """A stretch where another process held the mic (DET3). Paired from
    ``detector.mic_busy_started`` / ``mic_busy_ended``; ``bundle_id`` is the
    best-effort frontmost-app attribution the daemon stamped at grab time."""
    started_ts: datetime
    ended_ts: datetime
    bundle_id: str
    display_name: str
    # Filled by classify_mic_spans.
    handled: bool = False  # a prompt fired or a recording overlapped it
    miss_reason: str = ""  # why nothing fired, when it is a miss

    @property
    def duration_sec(self) -> float:
        return (self.ended_ts - self.started_ts).total_seconds()


def pair_mic_spans(events: Iterable[dict], *, since: datetime | None = None) -> list[MicBusySpan]:
    """Pair each ``mic_busy_started`` with the next ``mic_busy_ended``. There is one system mic,
    so spans never overlap; a still-open span at the tail (analysis ran mid-call) is dropped, like
    an unterminated recording session. ``since`` filters by the span's start."""
    ordered = sorted((e for e in events if "ts" in e), key=lambda e: e["ts"])
    spans: list[MicBusySpan] = []
    open_start: tuple[datetime, str, str] | None = None
    for ev in ordered:
        if ev.get("category") != "detector":
            continue
        action = ev.get("action")
        try:
            ts = _parse_ts(str(ev["ts"]))
        except (TypeError, ValueError):
            continue
        if action == "mic_busy_started":
            if since is not None and ts < since:
                open_start = None
                continue
            open_start = (ts, str(ev.get("bundle_id") or "unknown"), str(ev.get("display_name") or ""))
        elif action == "mic_busy_ended" and open_start is not None:
            start_ts, bundle, name = open_start
            spans.append(MicBusySpan(started_ts=start_ts, ended_ts=ts, bundle_id=bundle, display_name=name))
            open_start = None
    return spans


def _in_span(ts: datetime, span: MicBusySpan) -> bool:
    return (span.started_ts - MIC_MATCH_GRACE) <= ts <= (span.ended_ts + MIC_MATCH_GRACE)


def classify_mic_spans(
    spans: Iterable[MicBusySpan],
    sessions: Iterable[Session],
    *,
    prompts: list[datetime],
    dropped: list[tuple[datetime, str, str]],  # (ts, bundle_id, reason)
    picks: list[datetime],
) -> list[MicBusySpan]:
    """Mark each span handled (a recording overlapped it or a prompt fired) or a miss, and for a
    miss pick the most informative reason. Pure; mutates and returns the spans.

    Reason precedence, most-actionable first: a ``candidate_dropped`` in the window means a known
    app WAS seen but scored below threshold (recognizer rot / a scoring gap); a
    ``discovery_shadow_pick`` with no prompt means it was discovered but suppressed (cooldown /
    skip-latch / consent); neither means nothing was ever a candidate (an unlisted app, or AX /
    Screen-Recording denied)."""
    session_list = list(sessions)
    for span in spans:
        handled = any(
            s.started_ts <= (span.ended_ts + MIC_MATCH_GRACE)
            and (s.stopped_ts + MIC_MATCH_GRACE) >= span.started_ts
            for s in session_list
        ) or any(_in_span(p, span) for p in prompts)
        span.handled = handled
        if handled:
            span.miss_reason = ""
            continue
        drop = next((d for d in dropped if _in_span(d[0], span)), None)
        if drop is not None:
            span.miss_reason = f"candidate dropped ({drop[2]})"
        elif any(_in_span(pk, span) for pk in picks):
            span.miss_reason = "discovered but not prompted (cooldown / skip-latch / consent)"
        else:
            span.miss_reason = "no candidate (unlisted app, or Accessibility / Screen Recording denied)"
    return list(spans)


def collect_correlation_markers(
    events: Iterable[dict],
) -> tuple[list[datetime], list[tuple[datetime, str, str]], list[datetime]]:
    """Pull the timestamps DET3 correlates a mic-busy span against: ``prompt_shown`` (a prompt
    fired), ``candidate_dropped`` (a known app scored below threshold; carries bundle + reason),
    and ``discovery_shadow_pick`` (a winner was found). Returns ``(prompts, dropped, picks)``."""
    prompts: list[datetime] = []
    dropped: list[tuple[datetime, str, str]] = []
    picks: list[datetime] = []
    for ev in events:
        try:
            ts = _parse_ts(str(ev["ts"]))
        except (TypeError, ValueError, KeyError):
            continue
        cat, action = ev.get("category"), ev.get("action")
        if cat == "coordinator" and action == "prompt_shown":
            prompts.append(ts)
        elif cat == "detector" and action == "candidate_dropped":
            dropped.append((ts, str(ev.get("bundle_id") or "unknown"), str(ev.get("reason") or "")))
        elif cat == "detector" and action == "discovery_shadow_pick":
            picks.append(ts)
    return prompts, dropped, picks


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


def render_report(
    sessions: list[Session],
    stats: dict[str, AppStats],
    mic_spans: list[MicBusySpan] | None = None,
    min_miss_sec: float = 30.0,
) -> str:
    """Render a markdown audit report. Empty input still produces a
    valid skeleton so the caller can pipe it without branching."""
    spans = list(mic_spans or [])
    if not sessions and not spans:
        return "# Detection Audit\n\n_No recording sessions or mic activity found in event stream._\n"

    lines: list[str] = []
    lines.append("# Detection Audit")
    lines.append("")

    # Window spans whatever we have: a missed meeting produces mic-busy spans but no session, so
    # the report must not be gated on sessions existing (that would hide the misses DET3 exists for).
    starts = [s.started_ts for s in sessions] + [s.started_ts for s in spans]
    ends = [s.stopped_ts for s in sessions] + [s.ended_ts for s in spans]
    first_ts = min(starts).isoformat(timespec="seconds")
    last_ts = max(ends).isoformat(timespec="seconds")
    lines.append(f"Window: `{first_ts}` -> `{last_ts}` · {len(sessions)} session(s)")
    lines.append("")

    if sessions:
        total = len(sessions)
        detector_count = sum(1 for s in sessions if s.stop_kind == STOP_DETECTOR)
        backstop_count = sum(1 for s in sessions if s.stop_kind == STOP_SILENCE_BACKSTOP)
        force_count = sum(1 for s in sessions if s.stop_kind == STOP_FORCE_STOP)
        manual_count = sum(1 for s in sessions if s.stop_kind == STOP_MANUAL)
        all_deltas = [s.delta_sec for s in sessions if s.delta_sec is not None]

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

    # DET3: mic-busy misses — the mic was held by another process but nothing recorded and no
    # prompt fired. This is the false-negative class the whitelist can't see on its own.
    if spans:
        handled_n = sum(1 for s in spans if s.handled)
        mic_misses = [s for s in spans if not s.handled and s.duration_sec >= min_miss_sec]
        lines.append(f"## Mic-busy misses ({len(mic_misses)})")
        lines.append("")
        lines.append(f"Mic-busy spans observed: **{len(spans)}** ({handled_n} handled, "
                     f"{len(spans) - handled_n} unhandled). Misses below list unhandled spans "
                     f">= {min_miss_sec:.0f}s, so brief dictation / voice-memo blips are excluded.")
        lines.append("")
        if not mic_misses:
            lines.append("_None: every sustained mic-busy span was recorded or prompted._")
            lines.append("")
        else:
            lines.append("The mic was held but nothing recorded and no prompt fired - a whitelist "
                         "gap or recognizer rot:")
            lines.append("")
            lines.append("| App | Duration | When | Reason |")
            lines.append("|---|---:|---|---|")
            for s in sorted(mic_misses, key=lambda sp: sp.duration_sec, reverse=True):
                app = s.display_name or s.bundle_id
                when = s.started_ts.isoformat(timespec="seconds")
                lines.append(f"| `{app}` | {_format_duration(s.duration_sec)} | `{when}` | {s.miss_reason} |")
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
    p.add_argument(
        "--min-miss-sec",
        type=float,
        default=30.0,
        help="Minimum mic-busy span duration (seconds) to count as a miss (default 30), so brief "
             "dictation / voice-memo blips are not reported as missed meetings.",
    )
    args = p.parse_args(argv)

    source = Path(args.source)
    since = _parse_since(args.since) if args.since else None
    # PERF7: read the base log plus its rotated generations. pair_sessions sorts
    # by ts, so concatenation order does not matter, only that no session in the
    # recent window is lost across a rotation boundary.
    raw = [ev for p in events.log_generations(source) for ev in iter_events(p)]
    sessions = [classify_session(s) for s in pair_sessions(raw, since=since)]
    stats = aggregate(sessions)

    # DET3: correlate mic-busy spans against prompts / recordings / candidate drops.
    prompts, dropped, picks = collect_correlation_markers(raw)
    mic_spans = classify_mic_spans(
        pair_mic_spans(raw, since=since), sessions,
        prompts=prompts, dropped=dropped, picks=picks,
    )

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
            "mic_busy": {
                "spans_observed": len(mic_spans),
                "handled": sum(1 for s in mic_spans if s.handled),
                "misses": [
                    {
                        "started_ts": s.started_ts.isoformat(),
                        "bundle_id": s.bundle_id,
                        "display_name": s.display_name,
                        "duration_sec": s.duration_sec,
                        "reason": s.miss_reason,
                    }
                    for s in mic_spans
                    if not s.handled and s.duration_sec >= args.min_miss_sec
                ],
            },
        }
        sys.stdout.write(json.dumps(payload, indent=2, default=str) + "\n")
        return 0

    report = render_report(sessions, stats, mic_spans=mic_spans, min_miss_sec=args.min_miss_sec)
    if args.output:
        Path(args.output).write_text(report, encoding="utf-8")
    else:
        sys.stdout.write(report)
    return 0
