#!/usr/bin/env python3
"""AI5 spike: reduce a `mp classify-meetings --llm --json` dump to aggregates.

The dump carries one row per meeting including its title, so it is the owner's
real meeting names and never belongs in git. This reducer emits only counts and
agreement rates, which is what the verdict rests on:

    mp classify-meetings --llm --json > /tmp/ai5.json
    python docs/spikes/ai5_agreement.py /tmp/ai5.json > docs/spikes/ai5-classification-results.json

The headline number is the per-label Jaccard between the two independent
labellers (heuristic and local LLM). Overall agreement flatters a taxonomy whose
mass sits in one or two easy buckets; per-label overlap does not.
"""
from __future__ import annotations

import collections
import json
import sys
from pathlib import Path

TAXONOMY = [
    "one_on_one", "standup", "planning", "retro", "interview",
    "client", "review", "brainstorm", "all_hands", "other",
]


def reduce_rows(rows: list[dict]) -> dict:
    n = len(rows)
    has_llm = any(r.get("llm_type") for r in rows)
    out: dict = {
        "meetings": n,
        "heuristic_distribution": dict(collections.Counter(r["type"] for r in rows).most_common()),
        "reason_distribution": dict(collections.Counter(r["reason"] for r in rows).most_common()),
        "attendee_distribution": dict(
            sorted(collections.Counter(r["attendees"] for r in rows).items())
        ),
        "workflow_distribution": dict(
            collections.Counter(r["workflow"] or "(none)" for r in rows).most_common()
        ),
    }
    if not has_llm:
        return out

    out["llm_distribution"] = dict(
        collections.Counter(r.get("llm_type") for r in rows).most_common()
    )
    agree = sum(1 for r in rows if r.get("llm_type") == r["type"])
    out["overall_agreement"] = {"agreed": agree, "of": n, "pct": round(100 * agree / n, 1)}

    per_label = {}
    for label in TAXONOMY:
        a = {r["stem"] for r in rows if r["type"] == label}
        b = {r["stem"] for r in rows if r.get("llm_type") == label}
        union = len(a | b)
        per_label[label] = {
            "heuristic": len(a),
            "llm": len(b),
            "both": len(a & b),
            "jaccard_pct": round(100 * len(a & b) / union, 1) if union else None,
        }
    out["per_label_agreement"] = per_label

    out["confusion_top"] = [
        {"heuristic": a, "llm": b, "n": v}
        for (a, b), v in collections.Counter(
            (r["type"], r.get("llm_type")) for r in rows if r["type"] != r.get("llm_type")
        ).most_common(15)
    ]

    # The one_on_one sanity check: a label that means "two people" should track
    # the attendee count. Measured against the meetings that really have 2.
    two = [r for r in rows if r["attendees"] == 2]
    out["one_on_one_sanity"] = {
        "meetings_with_2_attendees": len(two),
        "llm_called_them_one_on_one": sum(1 for r in two if r.get("llm_type") == "one_on_one"),
        "llm_one_on_one_total": sum(1 for r in rows if r.get("llm_type") == "one_on_one"),
        "heuristic_one_on_one_with_over_3_attendees": sum(
            1 for r in rows if r["type"] == "one_on_one" and r["attendees"] > 3
        ),
    }
    return out


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        sys.stderr.write(__doc__ or "")
        return 2
    rows = json.loads(Path(argv[0]).read_text(encoding="utf-8"))
    json.dump(reduce_rows(rows), sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
