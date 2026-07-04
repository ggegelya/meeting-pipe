#!/usr/bin/env python3
"""DV2 spike: attendee data-quality audit for a possible People pivot.

Reads every `<stem>.summary.json` under a recordings directory and measures
whether `attendees[]` carries stable, real, cross-meeting person identities, or
diarization artifacts (`speaker_unknown`, a bare index) that no People view
could dedup. Stdlib only; re-run as the corpus grows:

    python3 docs/spikes/dv2_attendee_audit.py [--dir ~/Documents/Meetings/raw] [--json]

The read this produces backs `docs/spikes/dv2-attendee-quality.md`.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from pathlib import Path

# A raw diarization label or placeholder, never a person the user would name.
# `speaker_user` / `speaker_other` / `speaker_unknown` / `speaker3` come straight
# from FluidAudio's channel + diarization labels; a bare integer is a raw speaker
# index; the rest are obvious non-identities.
_ARTIFACT_RE = re.compile(
    r"^(speaker[_\- ]?(user|other|unknown|\d+)?|\d+|unknown|unassigned|n/?a|none|null|me|test|тест)$"
)


def normalize(name: str) -> str:
    """Casefolded, whitespace-collapsed key for cross-meeting dedup. Two spellings
    that differ only by case or spacing collapse to one identity here (a generous
    definition of "the same person" - the real world is messier)."""
    return re.sub(r"\s+", " ", name.strip()).casefold()


def is_artifact(name: str) -> bool:
    return bool(_ARTIFACT_RE.match(normalize(name)))


@dataclass
class Audit:
    summaries_total: int = 0
    summaries_with_attendees: int = 0            # non-empty attendees[]
    mentions_total: int = 0                      # every attendee string, with repeats
    artifact_mentions: int = 0
    name_mentions: int = 0
    # normalized name -> set of meeting stems it appears in (real names only)
    name_to_stems: dict[str, set[str]] = field(default_factory=lambda: defaultdict(set))
    artifact_values: Counter = field(default_factory=Counter)
    per_meeting: list[dict] = field(default_factory=list)

    @property
    def distinct_names(self) -> int:
        return len(self.name_to_stems)

    @property
    def names_in_multiple_meetings(self) -> int:
        return sum(1 for stems in self.name_to_stems.values() if len(stems) >= 2)

    @property
    def dedup_hit_rate(self) -> float:
        """Share of distinct real names that recur across >=2 meetings - the number
        a People view lives or dies on. Undefined (0.0) with no real names."""
        return (self.names_in_multiple_meetings / self.distinct_names) if self.distinct_names else 0.0

    @property
    def artifact_ratio(self) -> float:
        return (self.artifact_mentions / self.mentions_total) if self.mentions_total else 0.0

    def to_json(self) -> dict:
        return {
            "summaries_total": self.summaries_total,
            "summaries_with_attendees": self.summaries_with_attendees,
            "mentions_total": self.mentions_total,
            "artifact_mentions": self.artifact_mentions,
            "name_mentions": self.name_mentions,
            "artifact_ratio": round(self.artifact_ratio, 3),
            "distinct_names": self.distinct_names,
            "names_in_multiple_meetings": self.names_in_multiple_meetings,
            "dedup_hit_rate": round(self.dedup_hit_rate, 3),
            "artifact_values": dict(self.artifact_values.most_common()),
            "recurring_names": {
                name: sorted(stems)
                for name, stems in self.name_to_stems.items()
                if len(stems) >= 2
            },
            "per_meeting": self.per_meeting,
        }


def audit(root: Path) -> Audit:
    root = root.expanduser()
    a = Audit()
    if not root.is_dir():
        return a
    for summary_json in sorted(root.glob("*.summary.json")):
        stem = summary_json.name.split(".", 1)[0]
        try:
            obj = json.loads(summary_json.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if not isinstance(obj, dict):
            continue
        a.summaries_total += 1
        attendees = [x for x in (obj.get("attendees") or []) if isinstance(x, str) and x.strip()]
        if attendees:
            a.summaries_with_attendees += 1
        names_here: list[str] = []
        for raw in attendees:
            a.mentions_total += 1
            if is_artifact(raw):
                a.artifact_mentions += 1
                a.artifact_values[normalize(raw)] += 1
            else:
                a.name_mentions += 1
                key = normalize(raw)
                a.name_to_stems[key].add(stem)
                names_here.append(raw)
        a.per_meeting.append({
            "stem": stem,
            "title": str(obj.get("title") or stem),
            "attendees_raw": attendees,
            "real_names": names_here,
        })
    return a


def _print_report(a: Audit, root: Path) -> None:
    print(f"DV2 attendee audit  root={root}")
    print("-" * 64)
    print(f"summaries scanned:            {a.summaries_total}")
    print(f"  with a non-empty attendees[]: {a.summaries_with_attendees}")
    print(f"attendee mentions (w/ repeats): {a.mentions_total}")
    print(f"  diarization artifacts:        {a.artifact_mentions}  ({a.artifact_ratio:.0%})")
    print(f"  candidate real names:         {a.name_mentions}")
    print(f"distinct real names:            {a.distinct_names}")
    print(f"  recurring across >=2 meetings: {a.names_in_multiple_meetings}")
    print(f"cross-meeting dedup hit-rate:   {a.dedup_hit_rate:.0%}"
          + ("" if a.distinct_names else "   (undefined: no real names)"))
    if a.artifact_values:
        print()
        print("artifact values seen:")
        for val, n in a.artifact_values.most_common():
            print(f"  {n:>3}x  {val!r}")
    if a.per_meeting:
        print()
        print("per meeting:")
        for m in a.per_meeting:
            shown = ", ".join(m["attendees_raw"]) if m["attendees_raw"] else "(none)"
            print(f"  [{m['stem']}] {m['title']}")
            print(f"      attendees: {shown}")


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(prog="dv2_attendee_audit", description=__doc__)
    ap.add_argument("--dir", type=Path, default=Path("~/Documents/Meetings/raw"),
                    help="recordings directory (default ~/Documents/Meetings/raw)")
    ap.add_argument("--json", action="store_true", dest="as_json", help="emit JSON")
    args = ap.parse_args(argv)
    a = audit(args.dir)
    if args.as_json:
        print(json.dumps(a.to_json(), indent=2, ensure_ascii=False))
    else:
        _print_report(a, args.dir.expanduser())
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
