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
  - confirm-path: `confirmed_by == ["ax_leave_rewalk"]`, i.e. the AX re-walk
    (`confirmProvisionalEnd`) promoted the end. Modelled with the
    `confirm_provisional_end` pseudo-event. This is the dominant native ending.
  - tick-path: `confirmed_by == []` and a leading signal that does not require
    corroboration (shareable-window-gone, workspace-terminated, ...). Modelled
    with a `tick` past the debounce.
An ending it cannot reproduce with the pure engine (a lone ax-leave ended with
empty confirmed_by, i.e. the idle-stop backstop, or a same-class confirmed_by) is
REPORTED and SKIPPED, never faked.

Output carries no titles and pid 1234, so it is redaction-clean by construction;
still run every emitted file through `redact_detection_trace.py --check` before
committing (the mechanical PII gate).

Usage:
  scripts/extract_detection_trace.py --inventory          # per-session breakdown, nothing written
  scripts/extract_detection_trace.py --emit-all --out-dir /tmp/traces
  scripts/extract_detection_trace.py --events <path> --inventory

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
# PrimarySignalKind.endDebounceFloor: only browser-tab-title has a floor.
END_DEBOUNCE_FLOOR = {"browser_tab_title_left_meet_pattern": 120.0}
DEBOUNCE = 2.0
REWALK = "ax_leave_rewalk"


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
    if confirmed == [REWALK]:
        family = "confirm"  # the AX re-walk (confirmProvisionalEnd) promoted the end
    elif confirmed == [] and s.leading not in REQUIRES_CORROBORATION:
        family = "tick"  # a no-corroboration lead promoted on the debounce
    else:
        # A lone ax-leave ended with empty confirmed_by is the idle-stop backstop, and a
        # same-class confirmed_by is not a pure-engine promotion path. Never faked.
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
                       "kind": "confirm_provisional_end", "rewalk_signal": REWALK})
        expected.append({"after": f"events[{len(events) - 1}]", "verdict": "ended", "leading": s.leading, "confirmed_by": [REWALK]})
        shape = f"{'flicker_' if n_prov > 1 else ''}rewalk_end"
    else:  # tick
        floor = END_DEBOUNCE_FLOOR.get(s.leading, 0.0)
        tick_t = round(last_t + max(DEBOUNCE, floor) + 0.5, 2)
        events.append({"t": tick_t, "kind": "tick"})
        expected.append({"after": f"events[{len(events) - 1}]", "verdict": "ended", "leading": s.leading, "confirmed_by": []})
        shape = f"{'flicker_' if n_prov > 1 else ''}debounce_end"

    prov_note = f"{n_prov} provisional flicker(s)" if n_prov > 1 else "clean single end"
    family_note = ("ax-leave-led end confirmed by the AX re-walk (confirmProvisionalEnd)"
                   if family == "confirm" else
                   f"{RAW_TO_SHORT[s.leading]}-led end promoted on the {DEBOUNCE:.0f}s debounce")
    trace = {
        "scenario": scenario,
        "description": (f"Real dogfood session (redacted). {s.kind} {s.bundle_id}; {family_note}; {prov_note}. "
                        "Verdict sequence, leading signal, confirmed_by and relative timing preserved from the "
                        "event log; signal timeline minimally reconstructed to reproduce that sequence through the "
                        "pure engine; titles dropped and pid set to 1234."),
        "engine": "promotion",
        "debounce_seconds": DEBOUNCE,
        "context": {"bundle_id": s.bundle_id, "kind": s.kind, "pid": 1234},
        "events": events,
        "expected_verdicts": expected,
    }
    return trace, shape


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description="Derive detection-corpus traces from a real events.jsonl.")
    ap.add_argument("--events", type=Path, default=DEFAULT_EVENTS, help="events.jsonl path (rotations read too)")
    ap.add_argument("--inventory", action="store_true", help="print a per-session breakdown, write nothing")
    ap.add_argument("--emit-all", action="store_true", help="write every reproducible session as a trace")
    ap.add_argument("--out-dir", type=Path, default=None, help="destination dir for --emit-all")
    args = ap.parse_args(argv)

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
