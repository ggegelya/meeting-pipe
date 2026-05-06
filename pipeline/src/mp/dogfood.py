"""`mp dogfood` — A/B harness for comparing summarization backends.

Runs the same transcript through both Anthropic and the local MLX
backend and writes a single Markdown comparison file you can grade
by hand. Once you have ~20 such files, ``mp dogfood --report``
aggregates the manual scores and emits the ship-decision summary
required by Roadmap P2.4 acceptance.

Why hand-grading and not LLM-as-judge: the metric is *whether the
local model deserves to be the recommended default for users who
care about privacy*. Asking another LLM that same question is
self-referential. A per-meeting grade entered by the reviewer is
the trustworthy signal.

Output format (one file per transcript)::

    runs/<stem>.dogfood.md

The file contains:
  - both summaries side-by-side
  - YAML front-matter with placeholders for the four scores
  - a "Notes" free-text section

The reviewer fills in the YAML scores. ``--report`` reads every
``*.dogfood.md`` under the runs directory, aggregates, prints
results, and writes ``docs/local-llm-quality.md``.
"""
from __future__ import annotations

import argparse
import logging
import os
import re
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from .config import Config, load_secrets
from .schemas import MeetingSummary
from .summarize import (
    AnthropicSummaryClient,
    _load_system_prompt,
)
from .summarize_local import LocalSummaryClient

log = logging.getLogger("mp.dogfood")

DEFAULT_RUNS_DIR = Path("runs")
DEFAULT_REPORT_PATH = Path("docs/local-llm-quality.md")
SHIP_GATE = {
    "actions_capture_min": 0.80,
    "decisions_capture_min": 0.80,
    "hallucination_max": 0.05,
}


@dataclass
class Scorecard:
    """Per-meeting scores entered by the reviewer.

    `actions_capture` and `decisions_capture` are precision/recall-ish
    fractions in [0, 1]. `hallucination_rate` is fabricated-action-items
    over total-local-action-items. `notes` is freeform.
    """
    actions_capture: float
    decisions_capture: float
    hallucination_rate: float
    notes: str = ""


# ----- Per-meeting harness -----

def run_one(
    transcript_md: Path,
    *,
    cfg: Config,
    runs_dir: Path,
) -> Path:
    """Run both backends against `transcript_md` and write a comparison."""
    runs_dir.mkdir(parents=True, exist_ok=True)
    transcript = transcript_md.read_text(encoding="utf-8")
    if not transcript.strip():
        raise ValueError(f"empty transcript: {transcript_md}")

    sys_prompt = _load_system_prompt(
        cfg.summarization.team_context,
        cfg.summarization.summary_language,
    )

    log.info("running anthropic backend...")
    anth = AnthropicSummaryClient(api_key=os.environ["ANTHROPIC_API_KEY"]).summarize(
        system_prompt=sys_prompt, transcript=transcript,
        model=cfg.summarization.model, max_tokens=cfg.summarization.max_tokens,
    )

    log.info("running local backend...")
    with LocalSummaryClient(
        model=cfg.summarization.local_model,
    ) as local_client:
        local = local_client.summarize(
            system_prompt=sys_prompt, transcript=transcript,
            model=cfg.summarization.local_model,
            max_tokens=cfg.summarization.max_tokens,
        )

    out_path = runs_dir / f"{transcript_md.stem}.dogfood.md"
    out_path.write_text(_render_comparison(transcript_md, anth, local), encoding="utf-8")
    log.info("wrote %s", out_path)
    return out_path


_FRONTMATTER_TEMPLATE = """\
---
transcript: {transcript}
ts: {ts}
scores:
  actions_capture:    # 0.0 to 1.0
  decisions_capture:  # 0.0 to 1.0
  hallucination_rate: # 0.0 to 1.0 (lower is better)
notes: ""
---
"""


def _render_comparison(
    transcript_md: Path,
    anthropic_summary: MeetingSummary,
    local_summary: MeetingSummary,
) -> str:
    front = _FRONTMATTER_TEMPLATE.format(
        transcript=str(transcript_md),
        ts=datetime.now(timezone.utc).isoformat(timespec="seconds"),
    )
    parts: list[str] = [front]
    parts.append(f"# Dogfood comparison: `{transcript_md.name}`")
    parts.append("")
    parts.append("Score the local backend in the front-matter above, then run "
                 "`mp dogfood --report` to aggregate.")
    parts.append("")
    parts.append("## Anthropic (baseline)")
    parts.append("")
    parts.append("```json")
    parts.append(anthropic_summary.model_dump_json(indent=2, exclude_none=False))
    parts.append("```")
    parts.append("")
    parts.append("## Local (MLX)")
    parts.append("")
    parts.append("```json")
    parts.append(local_summary.model_dump_json(indent=2, exclude_none=False))
    parts.append("```")
    parts.append("")
    return "\n".join(parts) + "\n"


# ----- Aggregation -----

_SCORE_FIELDS = ("actions_capture", "decisions_capture", "hallucination_rate")
_SCORE_LINE_RE = re.compile(
    r"^\s+(?P<key>actions_capture|decisions_capture|hallucination_rate):"
    r"\s*(?P<val>[-+]?\d*\.?\d+)?(?:\s|#|$)"
)
_NOTES_LINE_RE = re.compile(r'^notes:\s*"(?P<val>.*)"\s*$')


def _read_scorecard(path: Path) -> Scorecard | None:
    """Parse the front-matter from a dogfood file. Returns None if any
    of the three score fields is unset; those rows skip the aggregate.

    The format is a hand-readable YAML-ish block we emit ourselves; we
    parse with two regex rules (one per field shape) to avoid pulling
    in PyYAML for what is effectively a six-line config table.
    """
    text = path.read_text(encoding="utf-8")
    if not text.startswith("---\n"):
        return None
    end = text.find("\n---\n", 4)
    if end == -1:
        return None
    block = text[4:end]
    scores: dict[str, float] = {}
    notes = ""
    for raw in block.splitlines():
        m = _SCORE_LINE_RE.match(raw)
        if m and m.group("val") is not None:
            scores[m.group("key")] = float(m.group("val"))
            continue
        n = _NOTES_LINE_RE.match(raw)
        if n is not None:
            notes = n.group("val")
    if any(k not in scores for k in _SCORE_FIELDS):
        return None
    return Scorecard(
        actions_capture=scores["actions_capture"],
        decisions_capture=scores["decisions_capture"],
        hallucination_rate=scores["hallucination_rate"],
        notes=notes,
    )


def aggregate(runs_dir: Path) -> dict:
    """Walk runs_dir, collect scorecards, return aggregate stats."""
    files = sorted(runs_dir.glob("*.dogfood.md"))
    cards: list[tuple[Path, Scorecard]] = []
    pending: list[Path] = []
    for f in files:
        sc = _read_scorecard(f)
        if sc is None:
            pending.append(f)
        else:
            cards.append((f, sc))
    if not cards:
        return {
            "n_total": len(files),
            "n_scored": 0,
            "n_pending": len(pending),
            "pending": [str(p) for p in pending],
            "ship": False,
            "reason": "no scorecards filled in yet",
        }
    n = len(cards)
    avg_actions = sum(c.actions_capture for _, c in cards) / n
    avg_decisions = sum(c.decisions_capture for _, c in cards) / n
    avg_hallucination = sum(c.hallucination_rate for _, c in cards) / n
    ship = (
        avg_actions >= SHIP_GATE["actions_capture_min"]
        and avg_decisions >= SHIP_GATE["decisions_capture_min"]
        and avg_hallucination <= SHIP_GATE["hallucination_max"]
    )
    reason: list[str] = []
    if avg_actions < SHIP_GATE["actions_capture_min"]:
        reason.append(f"actions_capture {avg_actions:.2f} < {SHIP_GATE['actions_capture_min']}")
    if avg_decisions < SHIP_GATE["decisions_capture_min"]:
        reason.append(f"decisions_capture {avg_decisions:.2f} < {SHIP_GATE['decisions_capture_min']}")
    if avg_hallucination > SHIP_GATE["hallucination_max"]:
        reason.append(f"hallucination_rate {avg_hallucination:.2f} > {SHIP_GATE['hallucination_max']}")
    return {
        "n_total": len(files),
        "n_scored": n,
        "n_pending": len(pending),
        "pending": [str(p) for p in pending],
        "avg_actions_capture": round(avg_actions, 3),
        "avg_decisions_capture": round(avg_decisions, 3),
        "avg_hallucination_rate": round(avg_hallucination, 3),
        "ship": ship,
        "reason": "ship gate met" if ship else "; ".join(reason),
        "files": [str(p) for p, _ in cards],
    }


def render_report(stats: dict) -> str:
    lines: list[str] = []
    lines.append("# Local-LLM quality dogfood report")
    lines.append("")
    lines.append(f"_Generated: {datetime.now(timezone.utc).isoformat(timespec='seconds')}_")
    lines.append("")
    lines.append(f"- Total transcripts:   {stats.get('n_total', 0)}")
    lines.append(f"- Scored:              {stats.get('n_scored', 0)}")
    lines.append(f"- Pending grade:       {stats.get('n_pending', 0)}")
    if "avg_actions_capture" in stats:
        lines.append("")
        lines.append("## Aggregate scores")
        lines.append("")
        lines.append(f"- Action items captured (vs Anthropic):   {stats['avg_actions_capture']:.2f}  "
                     f"(gate: ≥ {SHIP_GATE['actions_capture_min']:.2f})")
        lines.append(f"- Decisions captured (vs Anthropic):      {stats['avg_decisions_capture']:.2f}  "
                     f"(gate: ≥ {SHIP_GATE['decisions_capture_min']:.2f})")
        lines.append(f"- Hallucination rate:                     {stats['avg_hallucination_rate']:.2f}  "
                     f"(gate: ≤ {SHIP_GATE['hallucination_max']:.2f})")
    lines.append("")
    lines.append("## Ship decision")
    lines.append("")
    decision = "SHIP" if stats.get("ship") else "DO NOT SHIP"
    lines.append(f"**{decision}** ({stats.get('reason', '?')})")
    if stats.get("pending"):
        lines.append("")
        lines.append("## Pending (no scores filled in)")
        lines.append("")
        for p in stats["pending"]:
            lines.append(f"- {p}")
    return "\n".join(lines) + "\n"


# ----- CLI -----

def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(prog="mp dogfood",
                                description="A/B harness for Anthropic vs local summarization.")
    p.add_argument("transcript", nargs="?", help="Transcript .md to compare.")
    p.add_argument("--runs-dir", type=Path, default=DEFAULT_RUNS_DIR,
                   help=f"Where dogfood comparison files live (default: {DEFAULT_RUNS_DIR}).")
    p.add_argument("--report", action="store_true",
                   help="Aggregate scores from runs-dir and write a ship-decision report.")
    p.add_argument("--report-out", type=Path, default=DEFAULT_REPORT_PATH,
                   help=f"Where to write the report (default: {DEFAULT_REPORT_PATH}).")
    args = p.parse_args(argv)

    logging.basicConfig(level=logging.INFO,
                         format="%(asctime)s %(levelname)s %(name)s: %(message)s")

    if args.report:
        stats = aggregate(args.runs_dir)
        out = render_report(stats)
        args.report_out.parent.mkdir(parents=True, exist_ok=True)
        args.report_out.write_text(out, encoding="utf-8")
        sys.stdout.write(out)
        return 0 if stats.get("ship") else 1

    if not args.transcript:
        p.error("transcript path required (or pass --report)")
    cfg = Config.load()
    load_secrets()
    transcript_md = Path(args.transcript).expanduser().resolve()
    if not transcript_md.exists():
        sys.stderr.write(f"no such file: {transcript_md}\n")
        return 1
    if not os.environ.get("ANTHROPIC_API_KEY"):
        sys.stderr.write("ANTHROPIC_API_KEY required to run the baseline.\n")
        return 1
    run_one(transcript_md, cfg=cfg, runs_dir=args.runs_dir)
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main(sys.argv[1:]))
