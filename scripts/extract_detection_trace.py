#!/usr/bin/env python3
"""TECH-C6 helper: derive redaction-ready detection-corpus traces from a real
`events.jsonl` window.

The corpus (`daemon/Tests/MeetingPipeCoreTests/Fixtures/detection-corpus/`) needs
20+ REAL dogfood traces so `PromotionEngine` cannot silently regress on the apps
and endings you actually hit. Real meetings already live in the daemon's event
log: every meeting emits its `lifecycle.*` verdict transitions (starting ->
in_meeting -> ending_provisional -> ended, with the leading signal and confirmed_by
the shipped engine really decided). This tool reads those, segments the log into
meetings, and for each one it can faithfully reproduce, emits a distilled
`engine: "promotion"` trace whose replay through the pure engine reproduces that
exact verdict sequence.

What "distilled" means, and why it is honest: the committed trace is NOT a byte
copy of the noisy raw signal stream (a 1 Hz `ax_leave_button_state` poll, the
production-only AX re-walk, the idle backstop). It is the minimal signal timeline
that reproduces the real VERDICT sequence the engine logged for that meeting, with
the real leading signal, confirmed_by, provisional-flicker count, and timing
preserved. That is a characterization test of real behavior, matching how the
synthetic seeds are shaped.

It reproduces two ending families (see PromotionEngine):
  - confirm-path: `confirmed_by == ["ax_leave_rewalk"]` (the pre-END17 host
    confirm) or `["call_teardown_observed"]` (END17's), i.e. the host promoted
    the end through `confirmProvisionalEnd`. Modelled with the
    `confirm_provisional_end` pseudo-event. This is the dominant native ending.
  - tick-path: `confirmed_by == []` with a leading signal that does not require
    corroboration (shareable-window-gone, ...), which the pre-END17 engine
    promoted on its debounce, or `["lone_dwell"]`, END17's lone dwell. Since
    END17 a lone weak end confirms only on the lone dwell, so the `tick` is
    placed past it: the trace pins that the meeting still ends, at the time the
    current engine ends it, not the 2 s the old log recorded.
An ending it cannot reproduce with the pure engine is REPORTED and SKIPPED, never
faked. Two shapes land there, and neither is a corpus coverage gap (C7):
  - a lone ax-leave ended with empty confirmed_by is PRE-END2 HISTORY. Until END2
    landed (2026-06-10) the engine promoted a lone ax-leave on the debounce alone;
    it now refuses to (`requiresCorroboration` with no cross-class corroborator,
    pinned by `test_lone_ax_leave_invalid_does_not_promote_before_the_lone_dwell`),
    so replaying such a session would assert the exact behaviour END2 removed. Every
    session in this bucket in the owner's log ended on or before 2026-06-09.
  - a same-class confirmed_by (ax-leave plus window-gone) is correlated evidence,
    not independent corroboration, so it is not a promotion path either (END6/AUD-10).

The idle-stop backstop does NOT appear in this inventory at all, in any shape. It
force-stops the RECORDING, not the lifecycle: `IdleStopBackstop.onAutoStop` reaches
`MeetingSessionController.handleIdleAutoStop`, which stops the recorder and
disengages, so the log shows `coordinator.auto_stop_silence` then `lifecycle.idle`
and never a `lifecycle.ended`. `sessionize` closes a session on `lifecycle.ended`,
so a backstop-ended meeting is never even a session here.

Output carries no titles and pid 1234, so it is redaction-clean by construction;
still run every emitted file through `redact_detection_trace.py --check` before
committing (the mechanical PII gate).

RAW MODE (T8). The distilled traces above can only say what the engine of their day
decided, so a false end replays as the false end it was, and the raw flicker that
caused it is not in any of them. `--raw --from <iso> --to <iso>` instead emits an
`engine: "lifecycle"` trace: the window's raw `signal` rows mapped one-to-one onto
the engine's signal kinds, the host inputs the hold reads (`recording_started`, the
teardown watcher's snapshots, the live-call reading, the AX re-walk's result) from
the `coordinator` rows, and the window's `lifecycle` rows kept as `logged_verdicts`,
a record of what the engine of that day decided, never asserted. The last reading of
each signal from before the window, and the recording's start, are carried in at
their real negative offsets so the replay starts in the right state. The expected
outcome is the CORRECT one, which the log cannot know: `--expect no_end` (the
default, every END incident) or `--expect ended`, which writes the logged end as a
draft to confirm against the replay. Every other field is copied from a closed
vocabulary, never from a row's free text, so a title cannot reach the output.
`--check-against <committed.json>` re-extracts and reports whether the replayed
content (`context`, `until`, `events`, `source_window`) still matches, which is how a
committed raw trace is shown to be reproducible.

Usage:
  scripts/extract_detection_trace.py --inventory          # per-session breakdown, nothing written
  scripts/extract_detection_trace.py --emit-all --out-dir /tmp/traces
  scripts/extract_detection_trace.py --events <path> --inventory
  scripts/extract_detection_trace.py --raw --from 2026-10-22T12:14:50Z --to 2026-10-22T12:15:25Z --out t.json
  scripts/extract_detection_trace.py --raw --from <iso> --to <iso> --check-against <committed.json>

Stdlib only, so it runs on a clean Mac without `uv`.
"""
from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime
from pathlib import Path

DEFAULT_EVENTS = Path("~/Library/Logs/MeetingPipe/events.jsonl").expanduser()

# raw PrimarySignalKind.rawValue (as logged in leading_signal / confirmed_by)
# -> the short kind the corpus loader's mapSignalKind expects in events[].kind.
RAW_TO_SHORT = {
    "shareable_content_window_gone": "shareable_content_window",
    "process_audio_is_running_input_false": "process_audio_is_running_input_false",
    "ax_leave_button_invalid": "ax_leave_button",
    "browser_tab_title_left_meet_pattern": "browser_tab_title",
    "workspace_app_terminated": "workspace_app_terminated",
    "window_title_left_pattern": "window_title",
}
# PrimarySignalKind.requiresCorroboration == true only for ax-leave.
REQUIRES_CORROBORATION = {"ax_leave_button_invalid"}
# PromotionEngine.defaultLoneDwell (END17): a lone weak end confirms only after this.
LONE_DWELL = 720.0
LONE = "lone_dwell"
REWALK = "ax_leave_rewalk"
TEARDOWN = "call_teardown_observed"


def _parse_ts(raw: object) -> datetime | None:
    if not isinstance(raw, str) or not raw:
        return None
    try:
        return datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return None


def _log_files(path: Path) -> list[Path]:
    """The base log plus rotated generations (`events.1.jsonl`, ...), oldest
    first. Stdlib mirror of valid1_check._log_files / mp.events.log_generations."""
    numbered: list[tuple[int, Path]] = []
    for g in path.parent.glob(f"{path.stem}.*{path.suffix}"):
        mid = g.name[len(path.stem) + 1 : len(g.name) - len(path.suffix)]
        if mid.isdigit():
            numbered.append((int(mid), g))
    files = [g for _, g in sorted(numbered, reverse=True)]
    if path.exists():
        files.append(path)
    return files


def _load(path: Path) -> list[dict]:
    events: list[dict] = []
    for source in _log_files(path):
        for line in source.read_text(encoding="utf-8", errors="replace").splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(event, dict) and _parse_ts(event.get("ts")) is not None:
                events.append(event)
    events.sort(key=lambda e: _parse_ts(e.get("ts")))  # type: ignore[arg-type,return-value]
    return events


class Session:
    """One meeting: lifecycle.starting..ended, with the ordered steps between."""

    def __init__(self, start_event: dict) -> None:
        self.bundle_id = start_event.get("bundle_id")
        self.kind = start_event.get("kind")
        self.start = _parse_ts(start_event.get("ts"))
        self.in_meeting = False
        # ordered steps after the first in_meeting: ("provisional", leading, t) / ("revert", t)
        self.steps: list[tuple] = []
        self.leading: str | None = None
        self.confirmed_by: list[str] = []
        self.end: datetime | None = None

    def rel(self, ts: datetime | None) -> float:
        if ts is None or self.start is None:
            return 0.0
        return max(0.0, (ts - self.start).total_seconds())


def sessionize(events: list[dict]) -> list[Session]:
    sessions: list[Session] = []
    cur: Session | None = None
    for e in events:
        if e.get("category") != "lifecycle":
            continue
        act = e.get("action")
        ts = _parse_ts(e.get("ts"))
        if act == "starting":
            cur = Session(e)
        elif cur is None:
            continue
        elif act == "in_meeting":
            if not cur.in_meeting:
                cur.in_meeting = True
            else:
                cur.steps.append(("revert", ts))  # provisional -> in_meeting flicker
        elif act == "ending_provisional":
            cur.steps.append(("provisional", e.get("leading_signal"), ts))
        elif act == "ended":
            cur.leading = e.get("leading_signal")
            cb = e.get("confirmed_by")
            cur.confirmed_by = list(cb) if isinstance(cb, list) else []
            cur.end = ts
            sessions.append(cur)
            cur = None
    return sessions


def synthesize(s: Session, scenario: str) -> tuple[dict | None, str]:
    """Return (trace, shape_tag) if the session's ending is reproducible by the
    pure engine, else (None, skip_reason)."""
    if not s.in_meeting:
        return None, "never armed the recorder (no in_meeting)"
    if s.leading is None or s.leading not in RAW_TO_SHORT:
        return None, f"unknown leading signal {s.leading!r}"

    provisionals = [st for st in s.steps if st[0] == "provisional"]
    if not provisionals:
        return None, "ended without a logged ending_provisional"
    if any(p[1] not in RAW_TO_SHORT for p in provisionals):
        return None, "a provisional has an unknown leading signal"

    # Only the ENDING has to be pure-engine reproducible. Intermediate provisionals
    # (with any leading, in any evidence class) reproduce fine: each emits an
    # ending_provisional verdict and each revert flips back to in_meeting, so a real
    # flicker-recover-end (the END6/END8 fragmentation path) is faithfully modelled.
    confirmed = sorted(s.confirmed_by)
    if confirmed in ([REWALK], [TEARDOWN]):
        family = "confirm"  # the host promoted the end through confirmProvisionalEnd
    elif confirmed == [LONE] or (confirmed == [] and s.leading not in REQUIRES_CORROBORATION):
        family = "tick"  # a lone weak lead, confirmed on END17's lone dwell
    elif confirmed == [] and s.leading in REQUIRES_CORROBORATION:
        # Pre-END2 history, reported under its own reason so an inventory run cannot read it
        # as a coverage gap (C7). See the module docstring for why replaying one would be wrong.
        return None, f"pre-END2 lone {s.leading} end; the engine no longer promotes this"
    else:
        # A same-class confirmed_by is correlated evidence, not a pure-engine promotion path
        # (END6/AUD-10). Never faked.
        return None, f"ending not pure-engine reproducible (leading={s.leading}, confirmed_by={confirmed})"

    # The ended verdict promotes the LAST provisional, so its leading must match; if the
    # log is inconsistent (a non-engine end path), skip rather than emit a wrong trace.
    if provisionals[-1][1] != s.leading:
        return None, "final provisional leading disagrees with the ended verdict"

    n_prov = len(provisionals)
    # Canonical, provably well-formed reconstruction: L1 live (idle -> starting -> in_meeting),
    # then for each provisional Li an `Li ended` (in_meeting -> ending_provisional), with a
    # same-kind `Li live` revert inserted BETWEEN consecutive provisionals (ending_provisional
    # -> in_meeting; same evidence class, so END8 reverts it), and finally the family promotion
    # from the last ending_provisional. This drops the raw log's exact revert positions (a
    # trailing/leading revert can't be an engine end path) but preserves the essentials: the
    # count and order of provisional leadings, the flicker count, the ending family, and timing.
    start_short = RAW_TO_SHORT[provisionals[0][1]]
    events: list[dict] = [{"t": 0.0, "kind": start_short, "state": "live"}]
    expected: list[dict] = [
        {"after": "events[0]", "verdict": "starting"},
        {"after": "events[0]", "verdict": "in_meeting"},
    ]
    last_t = 0.0
    for i, prov in enumerate(provisionals):
        lead, prov_ts = prov[1], prov[2]  # steps are ("provisional", leading, ts)
        short = RAW_TO_SHORT[lead]
        t = round(s.rel(prov_ts), 2)
        if t <= last_t:
            t = round(last_t + 1.0, 2)
        events.append({"t": t, "kind": short, "state": "ended"})
        expected.append({"after": f"events[{len(events) - 1}]", "verdict": "ending_provisional", "leading": lead})
        last_t = t
        if i < n_prov - 1:  # flicker back to in_meeting before the next provisional
            nxt = s.rel(provisionals[i + 1][2])
            rt = round(min(t + 0.8, (t + nxt) / 2), 2) if nxt > t else round(t + 0.8, 2)
            if rt <= last_t:
                rt = round(last_t + 0.4, 2)
            events.append({"t": rt, "kind": short, "state": "live"})
            expected.append({"after": f"events[{len(events) - 1}]", "verdict": "in_meeting"})
            last_t = rt

    if family == "confirm":
        et = round(s.rel(s.end), 2)
        events.append({"t": et if et > last_t else round(last_t + 0.1, 2),
                       "kind": "confirm_provisional_end", "rewalk_signal": confirmed[0]})
        expected.append({"after": f"events[{len(events) - 1}]", "verdict": "ended", "leading": s.leading, "confirmed_by": confirmed})
        shape = f"{'flicker_' if n_prov > 1 else ''}rewalk_end"
    else:  # tick
        tick_t = round(last_t + LONE_DWELL + 0.5, 2)
        events.append({"t": tick_t, "kind": "tick"})
        expected.append({"after": f"events[{len(events) - 1}]", "verdict": "ended", "leading": s.leading, "confirmed_by": [LONE]})
        shape = f"{'flicker_' if n_prov > 1 else ''}lone_dwell_end"

    prov_note = f"{n_prov} provisional flicker(s)" if n_prov > 1 else "clean single end"
    family_note = (f"{RAW_TO_SHORT[s.leading]}-led end confirmed by the host ({confirmed[0]})"
                   if family == "confirm" else
                   f"lone {RAW_TO_SHORT[s.leading]}-led end, confirmed on the {LONE_DWELL:.0f}s lone dwell (END17)")
    trace = {
        "scenario": scenario,
        "description": (f"Real dogfood session (redacted). {s.kind} {s.bundle_id}; {family_note}; {prov_note}. "
                        "Verdict sequence, leading signal, confirmed_by and relative timing preserved from the "
                        "event log; signal timeline minimally reconstructed to reproduce that sequence through the "
                        "pure engine; titles dropped and pid set to 1234."),
        "engine": "promotion",
        "context": {"bundle_id": s.bundle_id, "kind": s.kind, "pid": 1234},
        "events": events,
        "expected_verdicts": expected,
    }
    return trace, shape


# ---------------------------------------------------------------------------------- raw (T8)

# The engine's state rows, one per `onChange` its signal fires (the signals log each edge
# and only the edges). Mapped to the corpus loader's short kinds.
def _signal_event(row: dict, context_kind: str) -> dict | None:
    act = row.get("action")
    if act == "ax_leave_button_state" and row.get("state") in ("healthy", "invalid"):
        return {"kind": "ax_leave_button", "state": "live" if row["state"] == "healthy" else "ended"}
    if act == "process_audio_is_running_input" and isinstance(row.get("value"), bool):
        return {"kind": "process_audio_is_running_input_false", "state": "live" if row["value"] else "ended"}
    if act == "shareable_content_window_present" and isinstance(row.get("value"), bool):
        # The browser adapter wires the same ScreenCaptureKit signal as the tab-title kind.
        kind = "browser_tab_title" if context_kind == "browser" else "shareable_content_window"
        return {"kind": kind, "state": "live" if row["value"] else "ended"}
    if act == "workspace_app_terminated":
        return {"kind": "workspace_app_terminated", "state": "ended"}
    return None


# Signal rows the raw mode cannot map without content it must not copy. `window_title_changed`
# decides live or ended by matching the title, and the title is exactly what never leaves.
UNMAPPABLE_SIGNALS = {"window_title_changed"}
LIVE_SIGNALS = {"call_is_up", "call_is_down", "unknown"}
VERDICTS = {"idle", "starting", "in_meeting", "ending_provisional", "ended"}


def _host_events(row: dict, t: float, report: list[str]) -> list[dict]:
    """The host inputs one `coordinator` row carries, as lifecycle-trace events."""
    act = row.get("action")
    out: list[dict] = []
    if act == "recording_started":
        out.append({"kind": "recording_started"})
    elif act == "lifecycle_end_held":
        # The hold row records the watcher's view when the hold opened. Rows older than END17
        # lack `oracle_available`; the snapshot is then left to later rows.
        available = row.get("oracle_available")
        ago = row.get("log_written_sec_ago")
        if isinstance(available, bool):
            out.append({"kind": "teardown_snapshot", "available": available, "teardown_at": None,
                        "log_written_at": round(t - ago, 3) if isinstance(ago, (int, float)) else None})
        if row.get("live_signal") in LIVE_SIGNALS:
            out.append({"kind": "live_signal", "value": row["live_signal"]})
    elif act == "lifecycle_provisional_end_confirmed":
        oracle = row.get("oracle")
        if oracle == "teardown_observed":
            # The old host's consult saw the teardown line here, so it was on disk by now; the
            # replay consults on a snapshot row, which reproduces the logged moment.
            out.append({"kind": "teardown_snapshot", "available": True, "teardown_at": t, "log_written_at": None})
        else:
            # oracle_unavailable, hold_cap_reached, live_signal_ceiling_reached, or the pre-END9
            # empty re-walk: retired confirms, none of them evidence a teardown happened.
            report.append(f"t={t}: retired confirm ({oracle or 'pre-END9 re-walk'}) is not teardown evidence; not replayed")
    elif act == "lifecycle_provisional_end_rescued":
        out.append({"kind": "rewalk", "found": True})
    elif act == "call_teardown_source_missing":
        out.append({"kind": "teardown_snapshot", "available": False, "teardown_at": None, "log_written_at": None})
    return out


def _verdict_record(row: dict, t: float) -> dict | None:
    act = row.get("action")
    if act not in VERDICTS:
        return None
    rec: dict = {"t": t, "verdict": act}
    if isinstance(row.get("leading_signal"), str):
        rec["leading"] = row["leading_signal"]
    if act == "ended" and isinstance(row.get("confirmed_by"), list):
        rec["confirmed_by"] = [c for c in row["confirmed_by"] if isinstance(c, str)]
    return rec


def _engagement(events: list[dict], start: datetime, bundle: str | None) -> tuple[str | None, int, int | None]:
    """For the engagement still open at `start`: (bundle, index of the first row after the
    previous engagement closed, index of its `lifecycle.starting`), or (None, 0, None).
    An `idle` or `ended` row closes an engagement. The first signal reading lands a few
    milliseconds BEFORE the `starting` row it causes, so carried state is read from the
    boundary, not from `starting`."""
    open_bundle: str | None = None
    open_index: int | None = None
    boundary = 0
    for i, e in enumerate(events):
        ts = _parse_ts(e.get("ts"))
        if ts is None or ts >= start:
            break
        if e.get("category") != "lifecycle":
            continue
        if e.get("action") == "starting" and (bundle is None or e.get("bundle_id") == bundle):
            open_bundle, open_index = e.get("bundle_id"), i
        elif e.get("action") in ("idle", "ended"):
            open_bundle, open_index, boundary = None, None, i + 1
    return open_bundle, boundary, open_index


def extract_raw(
    events: list[dict],
    start: datetime,
    end: datetime,
    bundle: str | None = None,
    scenario: str | None = None,
    expect: str = "no_end",
) -> tuple[dict, list[str]]:
    """Build a raw lifecycle trace for [start, end] from a time-sorted event list.

    Returns (trace, report). Raises ValueError when the window names no single meeting app."""
    report: list[str] = []
    window = [e for e in events if (ts := _parse_ts(e.get("ts"))) is not None and start <= ts <= end]

    if bundle is None:
        in_window = {e.get("bundle_id") for e in window if e.get("category") == "lifecycle" and e.get("bundle_id")}
        if len(in_window) == 1:
            bundle = next(iter(in_window))
        elif not in_window:
            bundle, _, _ = _engagement(events, start, None)
        if bundle is None:
            raise ValueError(f"window names {sorted(in_window) or 'no'} meeting app(s); pass --bundle")

    engaged_bundle, boundary, _ = _engagement(events, start, bundle)
    # The context kind: the window's own lifecycle rows first, then the newest one before it.
    before = [e for e in events if (ts := _parse_ts(e.get("ts"))) is not None and ts < start]
    kind = None
    for e in window + before[::-1]:
        if e.get("category") == "lifecycle" and e.get("bundle_id") == bundle and e.get("kind") in ("native", "browser"):
            kind = e["kind"]
            break
    if kind is None:
        raise ValueError(f"no lifecycle row says what kind of meeting {bundle} is in or before the window")

    def rel(e: dict) -> float:
        ts = _parse_ts(e.get("ts"))
        assert ts is not None
        return round((ts - start).total_seconds(), 3)

    out: list[dict] = []

    # Carried state: the last reading of each signal, and the recording's start, from the
    # engagement still open when the window begins.
    if engaged_bundle is not None:
        last: dict[str, tuple[int, dict]] = {}
        for i in range(boundary, len(events)):
            e = events[i]
            ts = _parse_ts(e.get("ts"))
            if ts is None or ts >= start:
                break
            if e.get("bundle_id") != bundle:
                continue
            if e.get("category") == "signal" and (sig := _signal_event(e, kind)) is not None:
                last[sig["kind"]] = (i, {"t": rel(e), **sig, "carried": True})
            elif e.get("category") == "coordinator" and e.get("action") == "recording_started":
                last["recording_started"] = (i, {"t": rel(e), "kind": "recording_started", "carried": True})
        out.extend(ev for _, ev in sorted(last.values(), key=lambda pair: pair[0]))

    logged: list[dict] = []
    dropped: dict[str, int] = {}
    for e in window:
        cat, act, own = e.get("category"), e.get("action"), e.get("bundle_id")
        t = rel(e)
        if cat == "signal" and own == bundle:
            sig = _signal_event(e, kind)
            if sig is not None:
                out.append({"t": t, **sig})
            elif act in UNMAPPABLE_SIGNALS:
                dropped[act] = dropped.get(act, 0) + 1
        elif cat == "coordinator" and (own == bundle or (own is None and act == "call_teardown_source_missing")):
            out.extend({"t": t, **ev} for ev in _host_events(e, t, report))
        elif cat == "lifecycle" and (own == bundle or own is None):
            rec = _verdict_record(e, t)
            if rec is not None:
                logged.append(rec)
    for act, n in sorted(dropped.items()):
        report.append(f"dropped {n} {act} row(s): they decide on a title, which never leaves the log")

    app = "teams" if bundle == "com.microsoft.teams2" else bundle.split(".")[-1]
    trace: dict = {
        "scenario": scenario or f"{app}_{kind}_raw_{start.strftime('%Y%m%dT%H%M%SZ')}",
        "description": (f"Raw lifecycle trace (redacted), extracted by scripts/extract_detection_trace.py --raw: "
                        f"{bundle} {kind}, {len(out)} events. Titles dropped and pid set to 1234; readings from "
                        "before the window are carried at their real offsets; logged_verdicts is what the engine "
                        "of that day decided, kept as a record and never asserted."),
        "engine": "lifecycle",
        "origin": "raw",
        "source_window": {"from": _iso(start), "to": _iso(end)},
        "expected_outcome": expect,
    }
    if expect == "ended":
        ends = [v["t"] for v in logged if v["verdict"] == "ended"]
        if not ends:
            raise ValueError("--expect ended, but the window logs no end")
        trace["ended_at"] = ends[-1]
        trace["trim_at"] = None
        report.append("ended_at is the logged end and trim_at is null: confirm both against the replay before committing")
    trace["context"] = {"bundle_id": bundle, "kind": kind, "pid": 1234}
    trace["until"] = round((end - start).total_seconds(), 3)
    trace["events"] = out
    trace["logged_verdicts"] = logged
    return trace, report


def _iso(ts: datetime) -> str:
    return ts.isoformat().replace("+00:00", "Z")


# What a re-extraction must reproduce. `scenario`, `description` and the expectation are the
# session's to write, so they are not compared.
REPRODUCED_KEYS = ("source_window", "context", "until", "events")


def reproduction_drift(fresh: dict, committed: dict) -> list[str]:
    return [k for k in REPRODUCED_KEYS if fresh.get(k) != committed.get(k)]


def _main_raw(args: argparse.Namespace) -> int:
    start, end = _parse_ts(args.start), _parse_ts(args.end)
    if start is None or end is None or end <= start:
        print("error: --raw needs --from and --to as ISO timestamps, --to after --from", file=sys.stderr)
        return 2
    try:
        trace, report = extract_raw(_load(args.events), start, end, bundle=args.bundle,
                                    scenario=args.scenario, expect=args.expect)
    except ValueError as e:
        print(f"error: {e}", file=sys.stderr)
        return 2
    for line in report:
        print(f"note: {line}", file=sys.stderr)
    if args.check_against is not None:
        committed = json.loads(args.check_against.read_text(encoding="utf-8"))
        drift = reproduction_drift(trace, committed)
        if drift:
            print(f"DRIFT  {args.check_against.name}: {', '.join(drift)} differ from a fresh extraction", file=sys.stderr)
            return 1
        print(f"OK: {args.check_against.name} reproduces from the event log.")
        return 0
    text = json.dumps(trace, indent=2, ensure_ascii=False) + "\n"
    if args.out is not None:
        args.out.write_text(text, encoding="utf-8")
        print(f"wrote {args.out}; now run scripts/redact_detection_trace.py {args.out} --check", file=sys.stderr)
    else:
        sys.stdout.write(text)
    return 0


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description="Derive detection-corpus traces from a real events.jsonl.")
    ap.add_argument("--events", type=Path, default=DEFAULT_EVENTS, help="events.jsonl path (rotations read too)")
    ap.add_argument("--inventory", action="store_true", help="print a per-session breakdown, write nothing")
    ap.add_argument("--emit-all", action="store_true", help="write every reproducible session as a trace")
    ap.add_argument("--out-dir", type=Path, default=None, help="destination dir for --emit-all")
    ap.add_argument("--raw", action="store_true", help="T8: emit a raw lifecycle trace for --from..--to")
    ap.add_argument("--from", dest="start", default=None, help="--raw window start (ISO, UTC)")
    ap.add_argument("--to", dest="end", default=None, help="--raw window end (ISO, UTC)")
    ap.add_argument("--bundle", default=None, help="--raw: the meeting app, when the window names several")
    ap.add_argument("--scenario", default=None, help="--raw: scenario name (default derived from app and window)")
    ap.add_argument("--expect", choices=("no_end", "ended"), default="no_end",
                    help="--raw: the correct outcome (default no_end, every END incident)")
    ap.add_argument("--out", type=Path, default=None, help="--raw: write here instead of stdout")
    ap.add_argument("--check-against", type=Path, default=None,
                    help="--raw: compare a fresh extraction with this committed trace, write nothing")
    args = ap.parse_args(argv)

    if args.raw:
        return _main_raw(args)

    events = _load(args.events)
    sessions = sessionize(events)
    armed = [s for s in sessions if s.in_meeting]

    # Classify every armed session.
    rows: list[tuple[Session, dict | None, str]] = []
    shape_counts: dict[str, int] = {}
    for i, s in enumerate(armed):
        trace, tag = synthesize(s, scenario=f"pending_{i}")
        rows.append((s, trace, tag))
        if trace is not None:
            shape_counts[tag] = shape_counts.get(tag, 0) + 1

    reproducible = [(s, t, tag) for (s, t, tag) in rows if t is not None]
    skipped = [(s, tag) for (s, t, tag) in rows if t is None]

    if args.inventory or not args.emit_all:
        print(f"lifecycle sessions: {len(sessions)}; armed (in_meeting): {len(armed)}")
        print(f"reproducible: {len(reproducible)}; skipped: {len(skipped)}")
        print("\n== reproducible by shape ==")
        for tag, n in sorted(shape_counts.items(), key=lambda x: -x[1]):
            print(f"  {n:4d}  {tag}")
        print("\n== skip reasons ==")
        skip_reasons: dict[str, int] = {}
        for _, tag in skipped:
            skip_reasons[tag] = skip_reasons.get(tag, 0) + 1
        for tag, n in sorted(skip_reasons.items(), key=lambda x: -x[1]):
            print(f"  {n:4d}  {tag}")
        if not args.emit_all:
            return 0

    if args.emit_all:
        if args.out_dir is None:
            print("error: --emit-all needs --out-dir", file=sys.stderr)
            return 2
        args.out_dir.mkdir(parents=True, exist_ok=True)
        # Deterministic per-shape sequence names; the caller curates the final set + INDEX.
        seq: dict[str, int] = {}
        manifest: list[dict] = []
        for s, trace, tag in reproducible:
            seq[tag] = seq.get(tag, 0) + 1
            app = (s.bundle_id or "app").split(".")[-1]
            scenario = f"{'teams' if s.bundle_id == 'com.microsoft.teams2' else app}_{s.kind}_{tag}_{seq[tag]:02d}"
            assert trace is not None
            trace["scenario"] = scenario
            out = args.out_dir / f"{scenario}.json"
            out.write_text(json.dumps(trace, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
            dur = round(s.rel(s.end), 1)
            manifest.append({"scenario": scenario, "shape": tag, "duration_s": dur,
                             "provisionals": len([st for st in s.steps if st[0] == "provisional"])})
        (args.out_dir / "MANIFEST.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        print(f"\nwrote {len(reproducible)} traces + MANIFEST.json to {args.out_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
