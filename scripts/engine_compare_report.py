#!/usr/bin/env python3
"""Synthesize the three-engine summarization comparison (AI2 follow-on).

Reads the dogfood comparison files (Anthropic vs MLX-14B and vs MLX-3B) plus the
Apple Intelligence summaries produced by `daemon/scripts/ai-summarize.swift`, and
emits two reports:

1. It fills provisional, objectively-computed scores into the MLX-14B dogfood
   front-matter (actions/decisions capture vs the Anthropic baseline = exactly the
   dogfood metric; hallucination = local actions absent from the baseline), so
   `mp dogfood --report --runs-dir runs/mlx-14b` produces `docs/local-llm-quality.md`.
2. `<runs>/engine-comparison.draft.md`: a per-engine extraction-count + latency
   draft. The token-overlap capture it prints is a ROUGH lower bound (differently
   phrased action items do not match), not a quality verdict; the authoritative
   report `docs/engine-comparison.md` is hand-finalized from reading the outputs.
   The draft lands in `runs/` (git-ignored) so it never clobbers the hand report.

Stdlib only. Usage: engine_compare_report.py [--runs RUNS_DIR]
"""
from __future__ import annotations

import argparse
import json
import re
import statistics
import sys
from pathlib import Path

_JSON_BLOCK = re.compile(r"```json\s*\n(.*?)\n```", re.DOTALL)
_WORD = re.compile(r"[a-z0-9]+")


def _toks(s: str) -> set[str]:
    return set(_WORD.findall(s.lower()))


def _match(a: str, b: str) -> bool:
    ta, tb = _toks(a), _toks(b)
    if not ta or not tb:
        return False
    return len(ta & tb) / len(ta | tb) >= 0.3


def capture(baseline: list[str], cand: list[str]) -> float | None:
    """Fraction of baseline items matched by some candidate item. None when the
    baseline is empty (nothing to capture, excluded from the average)."""
    if not baseline:
        return None
    return sum(1 for b in baseline if any(_match(b, c) for c in cand)) / len(baseline)


def hallucination(baseline: list[str], cand: list[str]) -> float:
    """Fraction of candidate items not matching any baseline item."""
    if not cand:
        return 0.0
    return sum(1 for c in cand if not any(_match(c, b) for b in baseline)) / len(cand)


def _action_tasks(summary: dict) -> list[str]:
    return [a.get("task", "") for a in summary.get("actions", []) if isinstance(a, dict)]


def parse_dogfood(path: Path) -> tuple[dict, dict] | None:
    blocks = _JSON_BLOCK.findall(path.read_text(encoding="utf-8"))
    if len(blocks) < 2:
        return None
    try:
        return json.loads(blocks[0]), json.loads(blocks[1])  # (anthropic, local)
    except json.JSONDecodeError:
        return None


def _counts(s: dict) -> dict:
    return {k: len(s.get(k, []) or []) for k in ("summary", "decisions", "actions", "questions", "attendees")}


def score_vs_baseline(baseline: dict, cand: dict) -> dict:
    return {
        "actions_capture": capture(_action_tasks(baseline), _action_tasks(cand)),
        "decisions_capture": capture(baseline.get("decisions", []), cand.get("decisions", [])),
        "hallucination_rate": hallucination(_action_tasks(baseline), _action_tasks(cand)),
        "counts": _counts(cand),
    }


def fill_dogfood_scores(path: Path, sc: dict) -> None:
    """Write provisional, auto-computed scores into the dogfood YAML front-matter
    so `mp dogfood --report` can aggregate them. Flagged in notes."""
    text = path.read_text(encoding="utf-8")
    def repl(key: str, val: float | None) -> None:
        nonlocal text
        v = "" if val is None else f"{val:.2f}"
        text = re.sub(rf"(?m)^(\s+{key}:).*$", rf"\g<1> {v}", text, count=1)
    repl("actions_capture", sc["actions_capture"])
    repl("decisions_capture", sc["decisions_capture"])
    repl("hallucination_rate", sc["hallucination_rate"])
    text = re.sub(r'(?m)^notes:.*$', 'notes: "auto-computed structural capture vs Anthropic baseline (provisional, owner spot-check)"', text, count=1)
    path.write_text(text, encoding="utf-8")


def _avg(xs: list[float | None]) -> float | None:
    vals = [x for x in xs if x is not None]
    return round(statistics.mean(vals), 3) if vals else None


def _fmt(x: float | None) -> str:
    return "n/a" if x is None else f"{x:.2f}"


def load_latency(runs: Path) -> dict[str, dict[str, float]]:
    out: dict[str, dict[str, float]] = {}
    f = runs / "latency.tsv"
    if not f.exists():
        return out
    for line in f.read_text(encoding="utf-8").splitlines()[1:]:
        parts = line.split("\t")
        if len(parts) != 3:
            continue
        stem, engine, sec = parts
        try:
            out.setdefault(stem, {})[engine] = float(sec)
        except ValueError:
            pass
    return out


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description="Three-engine comparison synthesis.")
    ap.add_argument("--runs", type=Path, default=Path("pipeline/runs"))
    args = ap.parse_args(argv)

    runs = args.runs.expanduser()
    d14 = runs / "mlx-14b"
    d3 = runs / "mlx-3b"
    dai = runs / "ai"
    latency = load_latency(runs)

    # per-engine per-meeting scores, keyed by engine name
    rows: dict[str, list[dict]] = {"mlx-14b": [], "mlx-3b": [], "apple-intelligence": [], "anthropic": []}
    anth_counts: list[dict] = []

    for f in sorted(d14.glob("*.dogfood.md")):
        stem = f.name[: -len(".dogfood.md")]
        parsed = parse_dogfood(f)
        if not parsed:
            continue
        anth, mlx14 = parsed
        anth_counts.append(_counts(anth))
        sc14 = score_vs_baseline(anth, mlx14)
        fill_dogfood_scores(f, sc14)  # provisional scores for `mp dogfood --report`
        rows["mlx-14b"].append({"stem": stem, **sc14})

        f3 = d3 / f.name
        if f3.exists() and (p3 := parse_dogfood(f3)):
            rows["mlx-3b"].append({"stem": stem, **score_vs_baseline(anth, p3[1])})

        fai = dai / f"{stem}.summary.ai.json"
        if fai.exists():
            try:
                ai = json.loads(fai.read_text(encoding="utf-8"))
                rows["apple-intelligence"].append({"stem": stem, **score_vs_baseline(anth, ai)})
            except json.JSONDecodeError:
                pass

    def agg(engine: str) -> dict:
        rs = rows[engine]
        lat = [latency.get(r["stem"], {}).get(_lat_key(engine)) for r in rs]
        return {
            "n": len(rs),
            "actions_capture": _avg([r["actions_capture"] for r in rs]),
            "decisions_capture": _avg([r["decisions_capture"] for r in rs]),
            "hallucination_rate": _avg([r["hallucination_rate"] for r in rs]),
            "avg_bullets": _avg([float(r["counts"]["summary"]) for r in rs]),
            "avg_actions": _avg([float(r["counts"]["actions"]) for r in rs]),
            "latency_sec": _avg([x for x in lat if x is not None]),
        }

    summary = {e: agg(e) for e in ("mlx-14b", "mlx-3b", "apple-intelligence")}
    anth_avg = {
        "avg_bullets": _avg([float(c["summary"]) for c in anth_counts]),
        "avg_actions": _avg([float(c["actions"]) for c in anth_counts]),
        "n": len(anth_counts),
    }

    runs.mkdir(parents=True, exist_ok=True)
    draft = runs / "engine-comparison.draft.md"
    draft.write_text(render(summary, anth_avg, latency), encoding="utf-8")
    print(f"wrote draft {draft} (hand-finalize into docs/engine-comparison.md)")
    print(json.dumps({"anthropic": anth_avg, **summary}, indent=2))
    return 0


def _lat_key(engine: str) -> str:
    return {"mlx-14b": "mlx-14b+anthropic", "mlx-3b": "mlx-3b+anthropic",
            "apple-intelligence": "apple-intelligence"}[engine]


def render(summary: dict, anth_avg: dict, latency: dict) -> str:
    L = []
    L.append("# Three-engine summarization comparison")
    L.append("")
    L.append("Quality (capture vs the Anthropic cloud baseline), latency, and privacy across the")
    L.append("three summarization backends, over real meetings (duration > 5 min, transcript")
    L.append("< 13k chars for 14B memory safety). Capture is objective set-overlap of action")
    L.append("tasks / decisions against the Anthropic baseline (token Jaccard >= 0.3); the")
    L.append("narrative read is provisional (Claude-graded, owner spot-check).")
    L.append("")
    L.append("## Per-engine aggregate")
    L.append("")
    L.append("Capture below is a ROUGH token-overlap lower bound (differently phrased items do")
    L.append("not match); use the hand grades in docs/engine-comparison.md as the quality verdict.")
    L.append("")
    L.append("| Engine | n | actions capture | decisions capture | hallucination | avg bullets | avg actions | latency (s) | privacy |")
    L.append("|---|---|---|---|---|---|---|---|---|")
    L.append(f"| Anthropic (baseline) | {anth_avg['n']} | 1.00 | 1.00 | 0.00 | {_fmt(anth_avg['avg_bullets'])} | {_fmt(anth_avg['avg_actions'])} | fast (cloud) | cloud egress |")
    for e, label, priv in (
        ("mlx-14b", "MLX 14B (local)", "on-device"),
        ("mlx-3b", "MLX 3B (local)", "on-device"),
        ("apple-intelligence", "Apple Intelligence", "on-device"),
    ):
        s = summary[e]
        L.append(f"| {label} | {s['n']} | {_fmt(s['actions_capture'])} | {_fmt(s['decisions_capture'])} | "
                 f"{_fmt(s['hallucination_rate'])} | {_fmt(s['avg_bullets'])} | {_fmt(s['avg_actions'])} | "
                 f"{_fmt(s['latency_sec'])} | {priv} |")
    L.append("")
    L.append("Capture/hallucination are vs the Anthropic baseline (so Anthropic is 1.00/0.00 by")
    L.append("definition). Latency is summarization wall-clock on this Mac (the MLX numbers")
    L.append("include a fresh per-meeting model load; Apple Intelligence is the map+reduce total).")
    L.append("")
    L.append("## Notes per engine")
    L.append("")
    L.append("- Anthropic: the quality baseline; fast; the only backend that egresses (cloud).")
    L.append("- MLX 14B: the recommended local model; closest to Anthropic; memory-bound on this")
    L.append("  Mac (OOM-unsafe above ~13k-char / ~16k-token transcripts, see the AI2 spike).")
    L.append("- MLX 3B: fast and light; lower capture; the practical default when RAM is tight.")
    L.append("- Apple Intelligence: native, free, zero-egress, but a 4096-token context forces")
    L.append("  heavy chunking on real meetings (Ukrainian tokenizes at ~1.7 tokens/char), so it")
    L.append("  is slow (minutes per meeting) and the map/reduce loses detail; it also mislabels")
    L.append("  Ukrainian as English and ignores the bullet-count cap. See LOCAL3 (hierarchical")
    L.append("  reduce) for the reduce-overflow this run had to work around.")
    L.append("")
    L.append("## Recommendation")
    L.append("")
    L.append("_Hand-finalized in docs/engine-comparison.md from reading the side-by-side outputs._")
    L.append("")
    return "\n".join(L) + "\n"


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
