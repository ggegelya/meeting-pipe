"""`mp analyze-detection`: audit meeting detection from both ends.

Two dimensions. **End detection** pairs each recording session with what stopped it, and since
DET19 judges every automatic stop against evidence the end decider does not produce. A
`lifecycle.ended` is no longer a success by being there: it is the recording's own end only when it
names the recording's own bundle (another app's end is a `foreign_end`), and it is a **false end**
when that bundle's process audio still read live at the end or the same bundle prompted, recorded
or resumed within the watch window after the stop (default 10 minutes). A stop whose call span had
already ended is judged for **overrun** (stop minus the span's end) and, when a held tail was cut,
**trim error** (the cut against the span's end). The span comes from DET23's microphone-holder
ledger once it exists; until then from the per-process `signal.process_audio_is_running_input`
rows, and the report names the source it used. Held ends are accounted by route (opened, released,
confirmed by pair, lone dwell or teardown, vetoed), DET1's `mic_in_use_stop` and
`recording_ended_during_start` are their own stop kinds rather than manual misses, and stood-down
silence backstops (`auto_stop_silence_skipped`) are counted. **Start detection**
(DET3): correlates mic-busy spans (`detector.mic_busy_started` / `mic_busy_ended`, the frontmost
app the daemon stamped at grab time) against prompts, recordings, and `candidate_dropped` events,
so a call the whitelist never saw shows up as a "mic was busy, nothing fired" miss. A miss with a
`candidate_unreadable` in its window is a denied Accessibility grant (DET11: a known native was
running and not one signal could be read off it); with a `candidate_dropped` it is recognizer rot
(a known app scored too low); with only a `discovery_shadow_pick` it was suppressed (cooldown /
skip-latch / consent); with none of them it was never a candidate (an unlisted app, or a
permission denied). Brief spans below `--min-miss-sec` (default 30 s) are excluded so dictation /
voice-memo blips are not counted.

**Zero misses and zero spans are different results, and this report says which one it has** (DET10).
The mic-busy dimension exists to make silent start-detection false-negatives visible, so it must not
itself go silent when its own input dies: a window with no `mic_busy_started` at all audited nothing,
and used to render as a missing section beside a clean end-detection report. The daemon's
`mic_device_unavailable` event (it could not resolve an audio input device, so the observer was
never wired) is read here for the same reason, and names the cause when it is present.

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
# DET19: a lifecycle end that named another app (the 2026-11-11 Chrome engage that stopped a
# source-less recording mid-conversation). Never the recording's own detector success.
STOP_FOREIGN_END = "foreign_end"
# DET19 amendment: `coordinator` actions that say a lifecycle end was refused and the recording
# kept running (END11 item 4, END19 item 3). A `lifecycle.ended` within this many seconds of one
# is that refused end, not a stop.
IGNORED_END_ACTIONS = frozenset({"meeting_end_ignored_other_app", "meeting_end_ignored_sourceless"})
IGNORED_END_PAIRING_SEC = 2.0
STOP_MIC_IN_USE = "mic_in_use_stop"
STOP_ENDED_DURING_START = "ended_during_start"
STOP_SILENCE_BACKSTOP = "silence_backstop"
STOP_FORCE_STOP = "force_stop"
STOP_MANUAL = "manual"
# The stops the daemon made on its own, which the end judgement scores.
AUTOMATIC_STOPS = {STOP_DETECTOR, STOP_FOREIGN_END, STOP_MIC_IN_USE, STOP_ENDED_DURING_START}

# DET19 defaults: how long after a stop a same-app prompt, recording or resume still means the
# stop cut a live call, and how long after the call span ended a stop counts as late.
DEFAULT_WATCH_WINDOW_SEC = 600.0
DEFAULT_LATE_AFTER_SEC = 30.0
# Which rows the call span was built from (DET19 item 1). The ledger is DET23's, not yet emitted.
TRUTH_PROCESS_AUDIO = "process_audio_is_running_input"


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
    # The latest `lifecycle.ended` naming this recording's bundle (or naming none, as old rows do).
    detector_ended_ts: datetime | None = None
    # DET19: the latest `lifecycle.ended` naming a different bundle, and the own end's route.
    foreign_ended_ts: datetime | None = None
    # The controller's own `meeting_end_ignored_*` rows inside the recording: ends that did not stop it.
    ignored_end_ts: list[datetime] = field(default_factory=list)
    confirmed_by: list[str] = field(default_factory=list)
    mic_in_use_stopped: bool = False
    ended_during_start: bool = False
    # OBS5's stop cause on `recording_stopped`, when the daemon writes one; recorded, not trusted
    # over the rows above until its vocabulary lands.
    stop_cause: str | None = None
    # `held_end_trimmed.limit_sec`: where the held tail was cut, in seconds from the start.
    trim_limit_sec: float | None = None
    # Non-detector stop causes observed inside the [started, stopped] window.
    auto_stopped: bool = False  # coordinator.auto_stop_silence fired
    force_stop_reason: str | None = None  # coordinator.force_stop reason attr
    # Filled by classify_session.
    # "detector" | "silence_backstop" | "force_stop" | "manual" | "unknown"
    stop_kind: str = "unknown"
    delta_sec: float | None = None  # stopped - detector.ended, only when detector-triggered
    # Filled by judge_sessions (DET19). None means the evidence to judge was absent.
    call_up_at_end: bool | None = None
    span_ended_ts: datetime | None = None
    resighted_ts: datetime | None = None
    false_end: bool = False
    seconds_lost: float | None = None  # stop -> the same app's next recording, for a false end
    overrun_sec: float | None = None  # stop - span end, when the span had ended first
    trim_error_sec: float | None = None  # cut point - span end

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


def _sort_key(ev: dict) -> datetime:
    try:
        return _parse_ts(str(ev["ts"]))
    except (TypeError, ValueError):
        return datetime.min.replace(tzinfo=timezone.utc)


def iter_events(path: Path, skipped: events.SkipCounter | None = None) -> Iterator[dict]:
    """Yield every well-formed JSON event from ``path``.

    Skips torn lines so a live-tailed file does not crash the analyzer
    mid-workday, counting them into ``skipped`` (PERF13) so ``main`` can say
    how many rows the report could not see.
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
                if skipped is not None:
                    skipped.count += 1
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
    # Sorted on the parsed instant, not the string: "…:36.500Z" sorts before "…:36Z" as text,
    # which put a stop ahead of the end that caused it whenever precisions were mixed.
    ordered = sorted((e for e in events if "ts" in e), key=_sort_key)

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
            # Record the latest lifecycle.ended inside the open window. If multiple fire
            # (debounce flutter), the last one is what actually drove the stop. DET19: only an
            # end naming this recording's bundle is its own; another app's end is foreign. A row
            # naming no bundle (older logs) is taken as the recording's own.
            ended_bundle = ev.get("bundle_id")
            if any(abs((ts - t).total_seconds()) <= IGNORED_END_PAIRING_SEC for t in open_session.ignored_end_ts):
                continue  # the controller logged it ignored just before this row: not a stop (DET19)
            if ended_bundle and ended_bundle != open_session.bundle_id:
                open_session.foreign_ended_ts = ts
            else:
                open_session.detector_ended_ts = ts
                confirmed = ev.get("confirmed_by")
                open_session.confirmed_by = [str(c) for c in confirmed] if isinstance(confirmed, list) else []
        elif cat == "coordinator" and action in IGNORED_END_ACTIONS:
            # DET19 amendment (2026-11-17): the controller refused this end (END11's other app,
            # END19's stale source-less engage) and the recording ran on, so the `lifecycle.ended`
            # row next to it is not what stopped it. The row the engine writes lands within a
            # couple of seconds of the refusal, on either side of it.
            open_session.ignored_end_ts.append(ts)
            if (open_session.foreign_ended_ts is not None
                    and abs((ts - open_session.foreign_ended_ts).total_seconds()) <= IGNORED_END_PAIRING_SEC):
                open_session.foreign_ended_ts = None
        elif cat == "coordinator" and action == "mic_in_use_stop":
            open_session.mic_in_use_stopped = True
        elif cat == "coordinator" and action == "recording_ended_during_start":
            open_session.ended_during_start = True
        elif cat == "recorder" and action == "held_end_trimmed":
            limit = ev.get("limit_sec")
            if isinstance(limit, (int, float)):
                open_session.trim_limit_sec = float(limit)
        elif cat == "coordinator" and action == "auto_stop_silence":
            open_session.auto_stopped = True
        elif cat == "coordinator" and action == "force_stop":
            open_session.force_stop_reason = str(ev.get("reason") or "")
        elif cat == "coordinator" and action == "recording_stopped":
            open_session.stopped_ts = ts
            # File attribute on `recording_stopped` is authoritative;
            # `recording_started` may have logged a placeholder if the
            # source was nil at start.
            file_attr = ev.get("file")
            if file_attr:
                open_session.file = str(file_attr)
            cause = ev.get("cause") or ev.get("stop_cause")
            if cause:
                open_session.stop_cause = str(cause)
            sessions.append(open_session)
            open_session = None

    return sessions


def classify_session(session: Session) -> Session:
    """Set ``stop_kind`` and ``delta_sec``. Pure; returns the same object.

    Priority: the recording's own detector end wins (it drove the stop); else
    a start-time end (`recording_ended_during_start`) or DET1's mic-release stop
    (`mic_in_use_stop`), neither of which writes a `lifecycle.ended`; else
    another app's lifecycle end (`foreign_end`); else a silence backstop (the
    auto-stop event, or a force-stop whose reason names silence); else a user
    force-stop hotkey; else a genuine manual stop, the only kind that counts
    as a miss. Being a detector stop says what stopped the recording, not that
    it was right: `judge_sessions` says that (DET19).
    """
    if session.detector_ended_ts is not None:
        session.stop_kind = STOP_DETECTOR
        session.delta_sec = (session.stopped_ts - session.detector_ended_ts).total_seconds()
        return session

    session.delta_sec = None
    if session.ended_during_start:
        session.stop_kind = STOP_ENDED_DURING_START
    elif session.mic_in_use_stopped:
        session.stop_kind = STOP_MIC_IN_USE
    elif session.foreign_ended_ts is not None:
        session.stop_kind = STOP_FOREIGN_END
    elif session.auto_stopped or _is_silence_reason(session.force_stop_reason):
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


# --- DET19: judging each automatic stop against an independent call span ------------------------


@dataclass
class HoldAccounting:
    """What the end-hold machinery did, by route (END9 to END17's rows, per app)."""
    opened: int = 0  # coordinator.lifecycle_end_held
    released: int = 0  # coordinator.lifecycle_end_hold_released: the call came back
    confirmed_pair: int = 0  # lifecycle.ended confirmed by two evidence classes
    confirmed_lone_dwell: int = 0  # ... by the lone dwell
    confirmed_teardown: int = 0  # ... by Teams' teardown line
    vetoed: int = 0  # lifecycle.end_vetoed
    backstop_stood_down: int = 0  # coordinator.auto_stop_silence_skipped


@dataclass
class EndJudgement:
    """The end dimension's verdict over a window (DET19)."""
    truth_source: str
    watch_window_sec: float
    late_after_sec: float
    holds: dict[str, HoldAccounting] = field(default_factory=dict)
    fragmented_calls: int = 0  # calls recorded as two or more stems
    extra_stems: int = 0


def _bundle_timeline(events: Iterable[dict], action: str, category: str) -> dict[str, list[tuple[datetime, dict]]]:
    out: dict[str, list[tuple[datetime, dict]]] = {}
    for ev in events:
        if ev.get("category") != category or ev.get("action") != action:
            continue
        try:
            ts = _parse_ts(str(ev["ts"]))
        except (TypeError, ValueError, KeyError):
            continue
        out.setdefault(str(ev.get("bundle_id") or ""), []).append((ts, ev))
    for rows in out.values():
        rows.sort(key=lambda pair: pair[0])
    return out


def _confirm_route(confirmed_by: list[str]) -> str | None:
    if "call_teardown_observed" in confirmed_by or "ax_leave_rewalk" in confirmed_by:
        return "teardown"
    if "lone_dwell" in confirmed_by:
        return "lone_dwell"
    if confirmed_by:
        return "pair"
    return None


def judge_sessions(
    sessions: list[Session],
    events: Iterable[dict],
    *,
    watch_window_sec: float = DEFAULT_WATCH_WINDOW_SEC,
    late_after_sec: float = DEFAULT_LATE_AFTER_SEC,
    since: datetime | None = None,
) -> EndJudgement:
    """Judge every automatic stop against rows the end decider does not produce. Pure; fills the
    sessions' judgement fields and returns the window's hold accounting and fragmentation.

    The call span is the recording bundle's `process_audio_is_running_input` readings (DET23's
    ledger replaces them once it exists): the last reading at or before the end decides whether
    the call was still up, and a `false` reading is the span's end. A re-sighting of the same
    bundle (a prompt, a recording start, a resume) within `watch_window_sec` after the stop is the
    other proof of a false end, and the only one when the span has no readings. Every end is scored
    against the recording's own bundle only."""
    rows = list(events)
    audio = _bundle_timeline(rows, "process_audio_is_running_input", "signal")
    sightings: dict[str, list[datetime]] = {}
    for action in ("prompt_shown", "recording_started", "recording_resumed_after_end"):
        for bundle, pairs in _bundle_timeline(rows, action, "coordinator").items():
            sightings.setdefault(bundle, []).extend(ts for ts, _ in pairs)
    for bundle in sightings:
        sightings[bundle].sort()
    window = timedelta(seconds=watch_window_sec)

    for s in sessions:
        if s.stop_kind not in AUTOMATIC_STOPS or s.bundle_id == "manual":
            continue
        end_ts = s.detector_ended_ts or s.foreign_ended_ts or s.stopped_ts
        readings = [(ts, ev) for ts, ev in audio.get(s.bundle_id, []) if s.started_ts <= ts <= end_ts]
        if readings:
            last_ts, last = readings[-1]
            s.call_up_at_end = bool(last.get("value"))
            if not s.call_up_at_end:
                s.span_ended_ts = last_ts
        after = [ts for ts in sightings.get(s.bundle_id, []) if s.stopped_ts < ts <= s.stopped_ts + window]
        s.resighted_ts = after[0] if after else None
        s.false_end = bool(s.call_up_at_end) or s.resighted_ts is not None
        if s.false_end:
            restarts = [ts for ts, _ in _bundle_timeline(rows, "recording_started", "coordinator").get(s.bundle_id, [])
                        if s.stopped_ts < ts <= s.stopped_ts + window]
            s.seconds_lost = (restarts[0] - s.stopped_ts).total_seconds() if restarts else None
        elif s.span_ended_ts is not None:
            s.overrun_sec = (s.stopped_ts - s.span_ended_ts).total_seconds()
        if s.trim_limit_sec is not None and s.span_ended_ts is not None:
            cut = s.started_ts + timedelta(seconds=s.trim_limit_sec)
            s.trim_error_sec = (cut - s.span_ended_ts).total_seconds()

    judgement = EndJudgement(TRUTH_PROCESS_AUDIO, watch_window_sec, late_after_sec)
    for ev in rows:
        try:
            ts = _parse_ts(str(ev["ts"]))
        except (TypeError, ValueError, KeyError):
            continue
        if since is not None and ts < since:
            continue
        cat, action = ev.get("category"), ev.get("action")
        bucket = judgement.holds.setdefault(str(ev.get("bundle_id") or "manual"), HoldAccounting())
        if cat == "coordinator" and action == "lifecycle_end_held":
            bucket.opened += 1
        elif cat == "coordinator" and action == "lifecycle_end_hold_released":
            bucket.released += 1
        elif cat == "coordinator" and action == "auto_stop_silence_skipped":
            bucket.backstop_stood_down += 1
        elif cat == "lifecycle" and action == "end_vetoed":
            bucket.vetoed += 1
        elif cat == "lifecycle" and action == "ended":
            confirmed = ev.get("confirmed_by")
            route = _confirm_route([str(c) for c in confirmed] if isinstance(confirmed, list) else [])
            if route == "pair":
                bucket.confirmed_pair += 1
            elif route == "lone_dwell":
                bucket.confirmed_lone_dwell += 1
            elif route == "teardown":
                bucket.confirmed_teardown += 1
    judgement.holds = {k: v for k, v in judgement.holds.items() if v != HoldAccounting()}

    # Fragments: one call recorded as several stems, chained by a same-app restart inside the window.
    by_bundle: dict[str, list[Session]] = {}
    for s in sessions:
        if s.bundle_id != "manual":
            by_bundle.setdefault(s.bundle_id, []).append(s)
    for runs in by_bundle.values():
        runs.sort(key=lambda r: r.started_ts)
        chain = 1
        for prev, nxt in zip(runs, runs[1:]):
            if nxt.started_ts - prev.stopped_ts <= window:
                chain += 1
                continue
            if chain > 1:
                judgement.fragmented_calls += 1
                judgement.extra_stems += chain - 1
            chain = 1
        if chain > 1:
            judgement.fragmented_calls += 1
            judgement.extra_stems += chain - 1
    return judgement


def judgement_rows(sessions: list[Session], late_after_sec: float = DEFAULT_LATE_AFTER_SEC) -> dict[str, dict]:
    """Per-app end-judgement figures: false ends and their seconds lost, late ends and overrun."""
    out: dict[str, dict] = {}
    for s in sessions:
        if s.stop_kind not in AUTOMATIC_STOPS:
            continue
        row = out.setdefault(s.bundle_id, {
            "automatic_stops": 0, "false_ends": 0, "foreign_ends": 0, "seconds_lost": 0.0,
            "late_ends": 0, "overrun_min": 0.0, "unjudged": 0,
        })
        row["automatic_stops"] += 1
        if s.stop_kind == STOP_FOREIGN_END:
            row["foreign_ends"] += 1
        if s.false_end:
            row["false_ends"] += 1
            row["seconds_lost"] += s.seconds_lost or 0.0
        if s.overrun_sec is not None and s.overrun_sec > late_after_sec:
            row["late_ends"] += 1
        if s.overrun_sec is not None and s.overrun_sec > 0:
            row["overrun_min"] += s.overrun_sec / 60.0
        if s.call_up_at_end is None and s.resighted_ts is None:
            row["unjudged"] += 1
    return out


def weekly_rows(sessions: list[Session]) -> dict[str, dict]:
    """The same figures per ISO week of the recording's start, so a build's effect reads over time.
    Per build era waits on OBS5's launch row."""
    out: dict[str, dict] = {}
    for s in sessions:
        year, week, _ = s.started_ts.isocalendar()
        row = out.setdefault(f"{year}-W{week:02d}", {"sessions": 0, "false_ends": 0, "seconds_lost": 0.0,
                                                      "overrun_min": 0.0})
        row["sessions"] += 1
        if s.false_end:
            row["false_ends"] += 1
            row["seconds_lost"] += s.seconds_lost or 0.0
        if s.overrun_sec is not None and s.overrun_sec > 0:
            row["overrun_min"] += s.overrun_sec / 60.0
    return dict(sorted(out.items()))


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
    unreadable: list[tuple[datetime, str]] | None = None,  # (ts, bundle_id), DET11
) -> list[MicBusySpan]:
    """Mark each span handled (a recording overlapped it or a prompt fired) or a miss, and for a
    miss pick the most informative reason. Pure; mutates and returns the spans.

    Reason precedence, most-actionable first: a ``candidate_unreadable`` in the window means a
    known native was running and Accessibility was denied, so nothing could be read off it (DET11)
    and the fix is a permission, not a recognizer; a ``candidate_dropped`` means a known app WAS
    seen but scored below threshold (recognizer rot / a scoring gap); a ``discovery_shadow_pick``
    with no prompt means it was discovered but suppressed (cooldown / skip-latch / consent); none
    of them means nothing was ever a candidate (an unlisted app, or a permission denied).

    The first two never co-occur in practice, since a drop needs a signal and every native signal
    is gated on the same AX trust the unreadable marker reports missing. The order still matters
    for a mixed window (an AX-denied native beside a browser the whitelist saw earlier)."""
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
        blind = next((u for u in (unreadable or []) if _in_span(u[0], span)), None)
        drop = next((d for d in dropped if _in_span(d[0], span)), None)
        if blind is not None:
            span.miss_reason = f"unreadable ({blind[1]} was running, Accessibility denied)"
        elif drop is not None:
            span.miss_reason = f"candidate dropped ({drop[2]})"
        elif any(_in_span(pk, span) for pk in picks):
            span.miss_reason = "discovered but not prompted (cooldown / skip-latch / consent)"
        else:
            span.miss_reason = "no candidate (unlisted app, or Accessibility / Screen Recording denied)"
    return list(spans)


def collect_correlation_markers(
    events: Iterable[dict],
) -> tuple[
    list[datetime],
    list[tuple[datetime, str, str]],
    list[datetime],
    list[tuple[datetime, str]],
]:
    """Pull the timestamps DET3 correlates a mic-busy span against: ``prompt_shown`` (a prompt
    fired), ``candidate_dropped`` (a known app scored below threshold; carries bundle + reason),
    ``discovery_shadow_pick`` (a winner was found), and ``candidate_unreadable`` (DET11: a known
    native was running while Accessibility was denied, so no signal could be read off it at all).
    Returns ``(prompts, dropped, picks, unreadable)``."""
    prompts: list[datetime] = []
    dropped: list[tuple[datetime, str, str]] = []
    picks: list[datetime] = []
    unreadable: list[tuple[datetime, str]] = []
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
        elif cat == "detector" and action == "candidate_unreadable":
            unreadable.append((ts, str(ev.get("bundle_id") or "unknown")))
    return prompts, dropped, picks, unreadable


# DET10: what the mic-busy dimension actually measured, which is not the same question as how many
# misses it found. Three states, because "no misses" is only a result under the first one.
MIC_INPUT_OBSERVED = "observed"  # spans exist: the input is alive and a zero-miss count is real
MIC_INPUT_DEVICE_UNAVAILABLE = "device_unavailable"  # no spans, and the daemon said why
MIC_INPUT_NO_SPANS = "no_spans"  # no spans, no stated reason: quiet window, or a silently dead input


def collect_mic_input_faults(
    events: Iterable[dict], *, since: datetime | None = None
) -> list[datetime]:
    """Timestamps of ``detector.mic_device_unavailable``: the daemon could not resolve an audio
    input device, so `MeetingDiscoveryWatcher` never wired the mic-busy observer and both DET3's
    spans and DET1's catch-all tier were off for that whole daemon run (DET10).

    Kept separate from ``collect_correlation_markers`` because it is not a correlation marker: it
    does not explain one span, it says the whole dimension was blind."""
    out: list[datetime] = []
    for ev in events:
        if ev.get("category") != "detector" or ev.get("action") != "mic_device_unavailable":
            continue
        try:
            ts = _parse_ts(str(ev["ts"]))
        except (TypeError, ValueError, KeyError):
            continue
        if since is not None and ts < since:
            continue
        out.append(ts)
    return sorted(out)


def mic_input_status(spans: Iterable[MicBusySpan], faults: Iterable[datetime]) -> str:
    """Whether the mic-busy dimension measured anything, and if not whether the daemon said why.

    The fault list only enriches the answer; it never gates it. A daemon that started before
    ``--since`` and has been dead-input ever since logged its fault outside the window, so a report
    that leaned on the event would call that window clean. Zero spans is the gate, and zero spans
    is never "clean"."""
    if list(spans):
        return MIC_INPUT_OBSERVED
    return MIC_INPUT_DEVICE_UNAVAILABLE if list(faults) else MIC_INPUT_NO_SPANS


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
    mic_input_faults: list[datetime] | None = None,
    judgement: EndJudgement | None = None,
) -> str:
    """Render a markdown audit report. Empty input still produces a
    valid skeleton so the caller can pipe it without branching."""
    spans = list(mic_spans or [])
    faults = list(mic_input_faults or [])
    if not sessions and not spans and not faults:
        return "# Detection Audit\n\n_No recording sessions or mic activity found in event stream._\n"

    lines: list[str] = []
    lines.append("# Detection Audit")
    lines.append("")

    # Window spans whatever we have: a missed meeting produces mic-busy spans but no session, so
    # the report must not be gated on sessions existing (that would hide the misses DET3 exists for).
    # A dead-input event is the third case, and it can be the only thing in the window (DET10).
    starts = [s.started_ts for s in sessions] + [s.started_ts for s in spans] + faults
    ends = [s.stopped_ts for s in sessions] + [s.ended_ts for s in spans] + faults
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
        other_auto = {kind: sum(1 for s in sessions if s.stop_kind == kind)
                      for kind in (STOP_FOREIGN_END, STOP_MIC_IN_USE, STOP_ENDED_DURING_START)}
        all_deltas = [s.delta_sec for s in sessions if s.delta_sec is not None]

        lines.append("## Summary")
        lines.append("")
        lines.append(f"- Detector-triggered stops: **{detector_count}** "
                     f"({detector_count / total * 100:.0f}%) - what stopped the recording, not "
                     f"whether it was right; the end judgement below says that")
        labels = {STOP_FOREIGN_END: "Stopped by another app's lifecycle end",
                  STOP_MIC_IN_USE: "Stopped on mic release (`mic_in_use_stop`)",
                  STOP_ENDED_DURING_START: "Ended while the recording was starting"}
        for kind, n in other_auto.items():
            if n:
                lines.append(f"- {labels[kind]}: **{n}** ({n / total * 100:.0f}%)")
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

        if judgement is not None:
            lines.extend(_render_judgement(sessions, judgement))

        misses = [s for s in sessions if s.stop_kind == STOP_MANUAL]
        lines.append(f"## Detector misses ({len(misses)})")
        lines.append("")
        if not misses:
            lines.append("_None: every session was ended by the detector, the silence "
                         "backstop, a force-stop, or another automatic stop._")
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

    # DET3: mic-busy misses - the mic was held by another process but nothing recorded and no
    # prompt fired. This is the false-negative class the whitelist can't see on its own.
    #
    # DET10: the section renders with no spans too. It used to be gated on `if spans:`, so a window
    # whose mic-busy input was dead produced no section at all, beside an end-detection report that
    # read fine - the instrument built to expose silent false-negatives going silent itself. A
    # heading of "Mic-busy misses (0)" would be no better, because 0 of 0 is not the same claim as
    # 0 of N.
    status = mic_input_status(spans, faults)
    if status != MIC_INPUT_OBSERVED:
        lines.append("## Mic-busy misses (not audited)")
        lines.append("")
        lines.append("**No mic-busy span was observed in this window, so start-detection was not "
                     "audited at all.** This is not the zero-misses result: nothing was measured. "
                     "The mic-busy dimension has one producer, "
                     "`AVCaptureDevice.isInUseByAnotherApplication`, and a dead one is silent "
                     "rather than loud.")
        lines.append("")
        if status == MIC_INPUT_DEVICE_UNAVAILABLE:
            first = min(faults).isoformat(timespec="seconds")
            lines.append(f"The daemon logged **{len(faults)}** `mic_device_unavailable` event(s) "
                         f"(first `{first}`): it could not resolve an audio input device, so the "
                         "mic-busy observer was never wired. That resolve is not retried, so DET1's "
                         "catch-all prompt and this whole dimension were off for the rest of each "
                         "of those daemon runs. Check the microphone permission first; the event "
                         "carries the TCC status it saw.")
        else:
            lines.append("No `mic_device_unavailable` event was logged either, so nothing here says "
                         "the input was missing (a daemon older than that event would say nothing "
                         "either). So: nothing held the microphone in this window, or the signal "
                         "does not observe mic contention on this Mac at all. Those are different "
                         "findings and this report cannot tell them apart. "
                         "`daemon/scripts/det10-mic-busy-probe.swift` is what settles it (DET10).")
        lines.append("")
    else:
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


def _render_judgement(sessions: list[Session], judgement: EndJudgement) -> list[str]:
    """The DET19 section: every automatic stop judged against the call span and the watch window."""
    lines = ["## End judgement", ""]
    lines.append(f"Call span from `{judgement.truth_source}` rows (DET23's microphone-holder ledger is not "
                 f"in this log); a stop is a false end when the call still read live at the end or the "
                 f"same app prompted, recorded or resumed within {judgement.watch_window_sec / 60:.0f} min "
                 f"after it, and late when the span had ended more than {judgement.late_after_sec:.0f}s "
                 f"before the stop.")
    lines.append("")
    rows = judgement_rows(sessions, judgement.late_after_sec)
    if rows:
        lines.append("| Source app | Automatic stops | False ends | Foreign | Seconds lost | Late ends "
                     "| Overrun | Unjudged |")
        lines.append("|---|---:|---:|---:|---:|---:|---:|---:|")
        for app, r in sorted(rows.items(), key=lambda kv: kv[1]["automatic_stops"], reverse=True):
            lines.append(f"| `{app}` | {r['automatic_stops']} | {r['false_ends']} | {r['foreign_ends']} "
                         f"| {r['seconds_lost']:.0f}s | {r['late_ends']} | {r['overrun_min']:.1f} min "
                         f"| {r['unjudged']} |")
        lines.append("")
    else:
        lines.append("_No automatic stop in this window._")
        lines.append("")
    if judgement.fragmented_calls:
        lines.append(f"- Calls recorded as several stems: **{judgement.fragmented_calls}** "
                     f"({judgement.extra_stems} extra stem(s))")
    trims = [s.trim_error_sec for s in sessions if s.trim_error_sec is not None]
    if trims:
        lines.append(f"- Held-tail trim error against the span end: median {statistics.median(trims):.1f}s, "
                     f"worst {max(trims, key=abs):.1f}s over {len(trims)} trim(s)")
    if judgement.holds:
        lines.append("")
        lines.append("| Source app | Holds opened | Released | Pair | Lone dwell | Teardown | Vetoed "
                     "| Backstop stood down |")
        lines.append("|---|---:|---:|---:|---:|---:|---:|---:|")
        for app, h in sorted(judgement.holds.items()):
            lines.append(f"| `{app}` | {h.opened} | {h.released} | {h.confirmed_pair} | "
                         f"{h.confirmed_lone_dwell} | {h.confirmed_teardown} | {h.vetoed} | "
                         f"{h.backstop_stood_down} |")
    weeks = weekly_rows(sessions)
    if len(weeks) > 1:
        lines.append("")
        lines.append("| Week | Sessions | False ends | Seconds lost | Overrun |")
        lines.append("|---|---:|---:|---:|---:|")
        for week, w in weeks.items():
            lines.append(f"| {week} | {w['sessions']} | {w['false_ends']} | {w['seconds_lost']:.0f}s "
                         f"| {w['overrun_min']:.1f} min |")
    false_ends = [s for s in sessions if s.false_end]
    if false_ends:
        lines.append("")
        lines.append("False ends:")
        lines.append("")
        for s in false_ends:
            why = "call still live at the end" if s.call_up_at_end else "same app back within the window"
            lost = f", {s.seconds_lost:.0f}s lost" if s.seconds_lost is not None else ""
            lines.append(f"- `{s.started_ts.isoformat(timespec='seconds')}` `{s.bundle_id}` "
                         f"({s.stop_kind}): {why}{lost} · `{s.file or '(unknown)'}`")
    lines.append("")
    return lines


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
    p.add_argument(
        "--watch-window-sec",
        type=float,
        default=DEFAULT_WATCH_WINDOW_SEC,
        help="After an automatic stop, how long a same-app prompt, recording or resume still marks it "
             "a false end (default 600).",
    )
    p.add_argument(
        "--late-after-sec",
        type=float,
        default=DEFAULT_LATE_AFTER_SEC,
        help="A stop this long after the call span ended counts as a late end (default 30).",
    )
    args = p.parse_args(argv)

    source = Path(args.source)
    since = _parse_since(args.since) if args.since else None
    # PERF7: read the base log plus its rotated generations. pair_sessions sorts
    # by ts, so concatenation order does not matter, only that no session in the
    # recent window is lost across a rotation boundary.
    #
    # No mp.events.drop_test_residue call here, deliberately. The rotated generations do
    # carry test residue (see CONVENTIONS.md "Event log schema"), but none of it lands on
    # the actions this report pairs on: the residue is pipeline_*/engine_*/republish_*,
    # and there is not one residue `recording_started`, `recording_stopped`, `force_stop`
    # or `mic_busy_*` row in the log. Filtering here would buy nothing and would strip the
    # synthetic sessions this module's own tests feed through main().
    skipped = events.SkipCounter()
    raw = [ev for p in events.log_generations(source) for ev in iter_events(p, skipped)]
    skipped.report()
    sessions = [classify_session(s) for s in pair_sessions(raw, since=since)]
    stats = aggregate(sessions)
    judgement = judge_sessions(sessions, raw, watch_window_sec=args.watch_window_sec,
                               late_after_sec=args.late_after_sec, since=since)

    # DET3: correlate mic-busy spans against prompts / recordings / candidate drops, and (DET11)
    # against the natives an untrusted Accessibility grant made unreadable.
    prompts, dropped, picks, unreadable = collect_correlation_markers(raw)
    mic_spans = classify_mic_spans(
        pair_mic_spans(raw, since=since), sessions,
        prompts=prompts, dropped=dropped, picks=picks, unreadable=unreadable,
    )
    # DET10: and read whether the producer of those spans was alive at all.
    mic_faults = collect_mic_input_faults(raw, since=since)

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
            "end_judgement": {
                "truth_source": judgement.truth_source,
                "watch_window_sec": judgement.watch_window_sec,
                "late_after_sec": judgement.late_after_sec,
                "per_app": judgement_rows(sessions, judgement.late_after_sec),
                "per_week": weekly_rows(sessions),
                "fragmented_calls": judgement.fragmented_calls,
                "extra_stems": judgement.extra_stems,
                "holds": {bid: vars(h) for bid, h in judgement.holds.items()},
                "stops": [
                    {
                        "started_ts": s.started_ts.isoformat(),
                        "bundle_id": s.bundle_id,
                        "file": s.file,
                        "stop_kind": s.stop_kind,
                        "stop_cause": s.stop_cause,
                        "call_up_at_end": s.call_up_at_end,
                        "false_end": s.false_end,
                        "seconds_lost": s.seconds_lost,
                        "overrun_sec": s.overrun_sec,
                        "trim_error_sec": s.trim_error_sec,
                    }
                    for s in sessions if s.stop_kind in AUTOMATIC_STOPS
                ],
            },
            "mic_busy": {
                # DET10: `spans_observed: 0` with `misses: []` used to be the only thing a machine
                # reader saw, and it reads identically to a clean week. `input_status` is the
                # discriminator: only "observed" means the misses list is a measurement.
                "input_status": mic_input_status(mic_spans, mic_faults),
                "device_unavailable_events": len(mic_faults),
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

    report = render_report(
        sessions, stats,
        mic_spans=mic_spans, min_miss_sec=args.min_miss_sec, mic_input_faults=mic_faults,
        judgement=judgement,
    )
    if args.output:
        Path(args.output).write_text(report, encoding="utf-8")
    else:
        sys.stdout.write(report)
    return 0
