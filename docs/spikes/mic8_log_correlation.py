#!/usr/bin/env python3
"""MIC8: measure the Teams SlimCore mute log against the incumbent AX oracle.

Read-only. This is the instrument that answered MIC8's owner-owed question without
needing a live instrumented call: instead of toggling mute 3-4 times during one
meeting, it replays every mute transition already recorded on this Mac and pairs
the two oracles against each other.

  - source A (candidate): Teams' SlimCore media-stack log, `MSTeamsNM_SlimCore_*.log`
    under the Teams group container. Three line forms carry a mute transition:
        AirPodsService: Input mute event received: mute|unmute
        AirPodsService: AirPodsService::SetMuteState: true|false with cause_id: <uuid>
        AirPodsService: AirPodsService InputMuteStateChangeNotification received with value: true|false
    `AirPodsService` is a misnomer: the component logs the client transmit gate on the
    built-in mic too (see the input-device check in the spike doc).

  - source B (incumbent): meeting-pipe's own event log, the `micgate` /
    `ax_mute_button_state` events the AX label scrape emits.

TIMEZONE GOTCHA: SlimCore prints UTC but suffixes it with the machine's local offset
(a file created 16:11:07 local has a first line stamped `13:11:07+03:00`). The offset
is a lie; the clock reading is UTC. We parse the naive part and treat it as UTC. Both
the correlation below and any future LogMuteAdapter have to do this, or every reading
is silently wrong by the local offset.

Usage:
    python3 docs/spikes/mic8_log_correlation.py [--json out.json]

Prints an aggregate report. `--json` writes the same aggregates (counts, percentiles,
agreement rates, per-generation format census). No timestamps or meeting identifiers
are written, so the output is safe to commit.
"""

from __future__ import annotations

import argparse
import datetime as dt
import glob
import json
import os
import re
from collections import Counter

HOME = os.path.expanduser("~")
SLIMCORE_GLOB = (
    f"{HOME}/Library/Group Containers/UBF8T346G9.com.microsoft.teams"
    "/Library/Application Support/Logs/MSTeamsNM_SlimCore_*.log"
)
EVENTS = f"{HOME}/Library/Logs/MeetingPipe/events.jsonl"

# The transition line. Deliberately anchored on the whole message, not a bare `mute`
# token: the Teams *shell* log (MSTeams_*.log) dumps a ~100 KB ECS config blob every
# hour that contains feature-flag keys like `hfpOsUnmuteFixEnabled`, and a loose token
# match reads those as hits.
TRANSITION = re.compile(
    r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+)\S*\s+\S+\s+<INFO>\s+"
    r"AirPodsService: Input mute event received: (mute|unmute)\b"
)
SETMUTE = re.compile(r"AirPodsService::SetMuteState: (true|false) with cause_id: ")
NOTIF = re.compile(r"InputMuteStateChangeNotification received with value: (true|false)\b")

# How far either side of an AX transition we look for the matching log line. Generous
# on purpose: a lag this large is a finding to report, not a pair to discard.
PAIR_WINDOW_S = 30.0


def read_slimcore() -> tuple[list[tuple[dt.datetime, bool]], list[dict]]:
    """Return (transitions, per-generation format census)."""
    transitions: list[tuple[dt.datetime, bool]] = []
    census: list[dict] = []
    for path in sorted(glob.glob(SLIMCORE_GLOB)):
        n_transition = n_setmute = n_notif = 0
        with open(path, errors="replace") as fh:
            for line in fh:
                m = TRANSITION.match(line)
                if m:
                    # naive part only: the printed offset is wrong, the reading is UTC
                    transitions.append((dt.datetime.fromisoformat(m.group(1)), m.group(2) == "mute"))
                    n_transition += 1
                    continue
                if SETMUTE.search(line):
                    n_setmute += 1
                elif NOTIF.search(line):
                    n_notif += 1
        census.append(
            {
                "generation": os.path.basename(path),
                "input_mute_event": n_transition,
                "set_mute_state": n_setmute,
                "input_mute_state_change_notification": n_notif,
            }
        )
    transitions.sort()
    return transitions, census


def read_ax_transitions() -> list[tuple[dt.datetime, bool, str]]:
    """AX mute reads where the state actually changed. Returns (ts, muted, reason)."""
    out: list[tuple[dt.datetime, bool, str]] = []
    if not os.path.exists(EVENTS):
        return out
    with open(EVENTS, errors="replace") as fh:
        for line in fh:
            if '"micgate"' not in line or '"ax_mute_button_state"' not in line:
                continue
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if d.get("action") != "ax_mute_button_state":
                continue
            state, previous = d.get("state"), d.get("previous")
            if state not in ("muted", "unmuted") or previous is None:
                continue  # `previous is None` is the initial read, not a transition
            muted = state == "muted"
            if previous.startswith("muted") == muted:
                continue  # re-assertion of the same state, not a transition
            out.append(
                (
                    dt.datetime.strptime(d["ts"], "%Y-%m-%dT%H:%M:%S.%fZ"),
                    muted,
                    str(d.get("reason")),
                )
            )
    out.sort()
    return out


def percentile(values: list[float], p: float) -> float:
    if not values:
        return float("nan")
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(round((p / 100.0) * (len(ordered) - 1))))]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--json", dest="json_path", help="write aggregates to this path")
    args = ap.parse_args()

    log_transitions, census = read_slimcore()
    ax_transitions = read_ax_transitions()

    if not log_transitions:
        print("No SlimCore mute transitions found. Is the native Teams client in use on this Mac?")
        return 1
    if not ax_transitions:
        print("No AX mute transitions in the event log; nothing to correlate against.")
        return 1

    print(f"SlimCore mute transitions: {len(log_transitions)} "
          f"({log_transitions[0][0]:%Y-%m-%d} .. {log_transitions[-1][0]:%Y-%m-%d}) "
          f"across {len(census)} log generations")
    print(f"AX mute transitions:       {len(ax_transitions)} "
          f"({ax_transitions[0][0]:%Y-%m-%d} .. {ax_transitions[-1][0]:%Y-%m-%d})")

    print("\nFormat census per log generation (does the line survive client updates?)")
    for row in census:
        print(f"  {row['generation']:<52} event={row['input_mute_event']:<5}"
              f" setstate={row['set_mute_state']:<5} notif={row['input_mute_state_change_notification']}")

    deltas: list[float] = []            # signed ms, negative = log line arrived first
    agree = disagree = unmatched = 0
    by_reason: Counter[str] = Counter()
    for ts, muted, reason in ax_transitions:
        nearest = min(log_transitions, key=lambda x: abs((x[0] - ts).total_seconds()))
        delta_ms = (nearest[0] - ts).total_seconds() * 1000.0
        if abs(delta_ms) > PAIR_WINDOW_S * 1000.0:
            unmatched += 1
            continue
        deltas.append(delta_ms)
        if nearest[1] == muted:
            agree += 1
        else:
            disagree += 1
        by_reason[reason] += 1

    abs_deltas = [abs(x) for x in deltas]
    log_led = sum(1 for x in deltas if x < 0)
    summary = {
        "slimcore_transitions": len(log_transitions),
        "slimcore_generations": len(census),
        "ax_transitions": len(ax_transitions),
        "paired": len(deltas),
        "agree": agree,
        "disagree": disagree,
        "unmatched_beyond_window": unmatched,
        "pair_window_s": PAIR_WINDOW_S,
        "log_led_ax": log_led,
        "log_lagged_ax": len(deltas) - log_led,
        "abs_delta_ms": {
            "min": round(min(abs_deltas), 1) if abs_deltas else None,
            "p50": round(percentile(abs_deltas, 50), 1),
            "p90": round(percentile(abs_deltas, 90), 1),
            "max": round(max(abs_deltas), 1) if abs_deltas else None,
        },
        "ax_reason_breakdown": dict(by_reason),
        "format_census": census,
    }

    print(f"\npaired={summary['paired']}  agree={agree}  disagree={disagree}"
          f"  unmatched(>{PAIR_WINDOW_S:.0f}s)={unmatched}")
    print(f"log line led the AX read in {log_led}/{len(deltas)} pairs")
    d = summary["abs_delta_ms"]
    print(f"|delta| ms: min={d['min']}  p50={d['p50']}  p90={d['p90']}  max={d['max']}")

    if args.json_path:
        with open(args.json_path, "w") as fh:
            json.dump(summary, fh, indent=2)
            fh.write("\n")
        print(f"\nwrote {args.json_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
