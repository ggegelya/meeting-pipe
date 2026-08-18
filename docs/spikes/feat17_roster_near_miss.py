#!/usr/bin/env python3
"""FEAT17 spike: does FEAT14's near-miss suggestion ever fire on the real library?

Recomputes, for every finalized meeting on disk, what `RosterStore.match_detail`
would have said about each voice, and counts how many meetings would have offered
at least one near-miss suggestion. No meeting on disk carries a `near_misses` key
(every one predates FEAT14 and is embeddings schema 1), so recomputing is the only
way to answer this, which is also why FEAT14's own walkthrough could not.

Read-only. It opens `<stem>.embeddings.json` files and the roster, and writes
nothing anywhere, including no temp files. `RosterStore`'s only writers are
`enroll`, `forget` and `rename`; none is called here. Safe to run during a live
meeting, since every file it touches is already final.

Run it from the repo root, through the pipeline environment (it imports `mp.roster`):

    cd pipeline && uv run python ../docs/spikes/feat17_roster_near_miss.py

Backs `docs/spikes/feat17-roster-near-miss-coverage.md`, which carries the
pre-registered verdict thresholds this prints against.
"""
from __future__ import annotations

import argparse
import collections
import json
import sys
from pathlib import Path

from mp import entry
from mp.roster import SUGGEST_MIN, MatchResult, RosterStore

# The pre-registered primary thresholds (FEAT17, written 2026-08-18 before any
# number existed). They live here as well as in the doc so the probe's own READ
# line cannot drift from the table it is read against.
GO_MIN_MEETINGS = 21
CLOSE_MAX_MEETINGS = 2

# Secondary thresholds, over declined labels only.
BELOW_FLOOR_MATTERS_AT = 0.80
MARGIN_BLOCKED_MATTERS_AT = 0.20


def classify(result: MatchResult, suggest_min: float = SUGGEST_MIN) -> str:
    """Which bin one voice falls in. Pure, so it is testable without a library.

    The bins are exclusive and exhaustive. `margin_blocked` exists as its own bin
    because the margin gate gates the *suggestion* too: a decline whose runner-up
    is level with the top candidate yields no suggestion however high the top
    score is. Counting those as `below_floor` would blame the floor for a
    roster-ambiguity problem and point the next task at the wrong constant.
    """
    if result.name is not None:
        return "named"
    if result.similarity is None:
        return "no_candidates"
    if result.near_miss is not None:
        return "suggested"
    if result.similarity < suggest_min:
        return "below_floor"
    return "margin_blocked"


def verdict(meetings_with_a_suggestion: int) -> str:
    """Map the primary count onto the pre-registered table. No interpretation."""
    if meetings_with_a_suggestion >= GO_MIN_MEETINGS:
        return "GO"
    if meetings_with_a_suggestion <= CLOSE_MAX_MEETINGS:
        return "CLOSE"
    return "MARGINAL"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="FEAT17: near-miss suggestion coverage over the real library.")
    ap.add_argument("--dir", type=Path, default=None, help="recordings directory (default: recording.output_dir)")
    ap.add_argument("--roster", type=Path, default=None, help="roster.json (default: ~/.config/meeting-pipe/roster.json)")
    ap.add_argument(
        "--names",
        action="store_true",
        help="also print the most frequent near-miss candidate names. Off by default: this output gets pasted into a session.",
    )
    args = ap.parse_args(argv)

    cfg = entry.prepare(secrets=False)
    root = args.dir if args.dir is not None else cfg.recording.output_dir
    root = Path(root).expanduser()
    store = RosterStore(path=args.roster.expanduser() if args.roster else None)

    sidecars = sorted(root.glob("*.embeddings.json"))
    bins: collections.Counter[str] = collections.Counter()
    candidates: collections.Counter[str] = collections.Counter()
    sims: list[float] = []
    meetings_with_a_suggestion = 0
    labels_seen = 0
    unreadable = 0

    for path in sidecars:
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            unreadable += 1
            continue
        embeddings = payload.get("embeddings")
        if not isinstance(embeddings, dict):
            unreadable += 1
            continue
        suggested_here = False
        for _label, embedding in embeddings.items():
            if not isinstance(embedding, list):
                continue
            labels_seen += 1
            result = store.match_detail(embedding)
            bucket = classify(result)
            bins[bucket] += 1
            if result.similarity is not None:
                sims.append(result.similarity)
            if bucket == "suggested":
                suggested_here = True
                if result.near_miss:
                    candidates[result.near_miss] += 1
        if suggested_here:
            meetings_with_a_suggestion += 1

    # A corpus that yields no labels is a broken invocation, not a CLOSE verdict.
    print(f"scanned:            {root}")
    print(f"sidecars found:     {len(sidecars)}  (unreadable: {unreadable})")
    print(f"labels examined:    {labels_seen}")
    print(f"roster people:      {len(store.names())}")
    if labels_seen == 0:
        print()
        print("READ: NOTHING SCANNED. No voice embeddings were found, so this is not a CLOSE verdict.")
        print("      Check --dir points at the recordings directory and that meetings there are finalized.")
        return 2

    declined = bins["below_floor"] + bins["margin_blocked"] + bins["suggested"]
    print()
    print(f"named by the roster:      {bins['named']}")
    print(f"no candidates at all:     {bins['no_candidates']}  (empty roster, or no embedding)")
    print(f"declined:                 {declined}")
    if declined:
        for bucket in ("suggested", "below_floor", "margin_blocked"):
            n = bins[bucket]
            print(f"   {bucket:<16} {n:>5}  ({100.0 * n / declined:.1f}% of declines)")
    if sims:
        ordered = sorted(sims)
        pick = lambda q: ordered[min(len(ordered) - 1, int(q * len(ordered)))]  # noqa: E731
        print()
        print(f"top-candidate similarity: min {ordered[0]:.3f}  p50 {pick(0.5):.3f}  p90 {pick(0.9):.3f}  max {ordered[-1]:.3f}")

    print()
    print(f"PRIMARY: {meetings_with_a_suggestion} of {len(sidecars)} meetings would have offered a suggestion.")
    print(f"READ: {verdict(meetings_with_a_suggestion)}"
          f"   (GO >= {GO_MIN_MEETINGS}, CLOSE <= {CLOSE_MAX_MEETINGS}, MARGINAL in between)")

    if declined:
        below = bins["below_floor"] / declined
        blocked = bins["margin_blocked"] / declined
        print()
        if below >= BELOW_FLOOR_MATTERS_AT:
            print(f"SECONDARY: below_floor is {below:.0%} of declines, at or over the {BELOW_FLOOR_MATTERS_AT:.0%} mark.")
            print("           The constraint is the matcher (enrolment volume or centroid quality), not the surface.")
        elif blocked >= MARGIN_BLOCKED_MATTERS_AT:
            print(f"SECONDARY: margin_blocked is {blocked:.0%} of declines, at or over the {MARGIN_BLOCKED_MATTERS_AT:.0%} mark.")
            print("           The constraint is roster ambiguity between enrolled people. Do NOT route the")
            print("           suggestion around the margin gate; FEAT14 settled that and it is not reopened.")
        else:
            print("SECONDARY: neither bin threshold met; the roster is behaving and the primary reading stands alone.")

    if args.names and candidates:
        print()
        print("near-miss candidates by frequency (opt-in via --names):")
        for name, n in candidates.most_common(10):
            print(f"   {n:>4}  {name}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
