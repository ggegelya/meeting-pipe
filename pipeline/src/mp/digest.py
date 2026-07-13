"""`mp digest` - weekly review digest, async and on-device (AI4).

Aggregates the week's aging open action items and recent decisions from the
library (deterministic, read straight from `<stem>.summary.json`, so the facts in
the digest are grounded and never hallucinated), then asks the on-device engine
to write a short narrative "state of your week" over those facts. The result is a
`MeetingSummary` written to disk and, with `--publish`, fanned out through the
existing sinks.

Zero-egress + backend: narration runs through `engine.complete_text`, so it
honours `effective_backend()` and the egress guard clamps it under regulated /
NDA; the facts stay on-device unless you publish to a cloud sink. If the engine
is unavailable, the digest still generates with a deterministic narrative, so a
scheduled run never fails to produce output.

Latency-tolerant by design (a background / scheduled run, not interactive), so
there is no live-latency budget. No new always-on egress: this is a command you
run or schedule (e.g. a weekly launchd timer), not a daemon.
"""
from __future__ import annotations

import argparse
import json
import logging
import re
import sys
from dataclasses import dataclass
from datetime import date, timedelta
from pathlib import Path

from . import actions as actions_mod
from . import engine, entry, events
from .config import Config
from .schemas import ActionItem, Confidence, MeetingSummary
from .markdown import render_summary_md

log = logging.getLogger("mp.digest")

DEFAULT_SINCE_DAYS = 7
# Bound only the facts fed to the model (prompt size); the digest's own action
# list stays complete. A narrative is a summary, so the top-aging slice is enough.
MAX_FACTS = 30
_CONFIDENCE: tuple[Confidence, ...] = ("low", "medium", "high")
_STEM_DATE = re.compile(r"^(\d{8})")

_NARRATE_SYSTEM = (
    "You write a brief weekly review for one person from the facts below: their "
    "open action items (with aging) and recent decisions. Write at most 5 short "
    "bullet lines. Lead with what is overdue and needs attention, then the main "
    "themes, then notable decisions. Use ONLY the facts given: do not invent "
    "tasks, owners, dates, or decisions. No preamble and no closing, one bullet "
    "per line starting with '- '."
)


@dataclass
class RecentDecision:
    stem: str
    title: str
    day: date
    text: str


def _meeting_day(stem: str) -> date | None:
    """The meeting date from a `YYYYMMDD-HHMMSS` stem, or None when the stem does
    not start with a date (so a stray digest / hand-named file is skipped)."""
    m = _STEM_DATE.match(stem)
    if not m:
        return None
    try:
        return date(int(m.group(1)[:4]), int(m.group(1)[4:6]), int(m.group(1)[6:8]))
    except ValueError:
        return None


def collect_open_actions(root: Path, today: date) -> list[actions_mod.OpenAction]:
    """Every open action across the library, most-overdue / soonest-due first
    (undated last). Reuses `mp actions`' discovery + open filter (AI1)."""
    opens = actions_mod.filter_actions(
        actions_mod.discover(Path(root)), lifecycle="open", today=today
    )
    opens.sort(key=lambda a: (a.due is None, a.due or "", a.stem))
    return opens


def collect_recent_decisions(root: Path, today: date, since_days: int) -> list[RecentDecision]:
    """Decisions from meetings dated within the last `since_days`, newest first.
    Decisions are undated, so "recent" is by the meeting's date (like DV1)."""
    root = Path(root).expanduser()
    if not root.is_dir():
        return []
    cutoff = today - timedelta(days=max(0, since_days))
    out: list[RecentDecision] = []
    for summary_json in sorted(root.glob("*.summary.json")):
        stem = summary_json.name.split(".", 1)[0]
        day = _meeting_day(stem)
        if day is None or day < cutoff:
            continue
        try:
            obj = json.loads(summary_json.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if not isinstance(obj, dict):
            continue
        title = str(obj.get("title") or stem)
        for d in obj.get("decisions") or []:
            if isinstance(d, str) and d.strip():
                out.append(RecentDecision(stem=stem, title=title, day=day, text=d.strip()))
    out.sort(key=lambda d: d.day, reverse=True)
    return out


def _format_facts(open_actions: list[actions_mod.OpenAction], decisions: list[RecentDecision], today: date) -> str:
    lines: list[str] = ["OPEN ACTIONS (most overdue first):"]
    for a in open_actions[:MAX_FACTS]:
        owner = a.owner or "unassigned"
        age = a.age_days(today)
        age_str = ""
        if age is not None:
            age_str = f", {age}d overdue" if age > 0 else (", due today" if age == 0 else f", due in {-age}d")
        lines.append(f"- {a.task} (owner: {owner}{age_str})")
    if not open_actions:
        lines.append("- (none)")
    lines.append("")
    lines.append("RECENT DECISIONS:")
    for d in decisions[:MAX_FACTS]:
        lines.append(f"- {d.text} ({d.title})")
    if not decisions:
        lines.append("- (none)")
    return "\n".join(lines)


def _parse_bullets(text: str) -> list[str]:
    """Pull `- ` / `* ` bullet lines out of the model's reply; fall back to the
    first non-empty lines if it ignored the format. Capped at 5."""
    bullets: list[str] = []
    for line in text.splitlines():
        s = line.strip()
        if s[:2] in ("- ", "* "):
            bullets.append(s[2:].strip())
        elif s.startswith(("-", "*")) and len(s) > 1:
            bullets.append(s[1:].strip())
    if not bullets:
        bullets = [s.strip() for s in text.splitlines() if s.strip()]
    return [b for b in bullets if b][:5]


def _fallback_bullets(open_actions: list[actions_mod.OpenAction], decisions: list[RecentDecision],
                      today: date, since_days: int) -> list[str]:
    """A deterministic narrative when the engine is unavailable, so the digest
    still generates. Grounded in the same counts the facts carry."""
    overdue = [a for a in open_actions if a.is_overdue(today)]
    bullets = [f"{len(open_actions)} open action item(s), {len(overdue)} overdue."]
    if overdue:
        worst = max(overdue, key=lambda a: a.age_days(today) or 0)
        bullets.append(f"Most overdue: {worst.task} ({worst.age_days(today)}d past due).")
    bullets.append(f"{len(decisions)} decision(s) recorded in the last {since_days} days.")
    return bullets[:5]


def narrate(cfg: Config, open_actions: list[actions_mod.OpenAction],
            decisions: list[RecentDecision], today: date, since_days: int) -> tuple[list[str], str]:
    """Ask the engine for the narrative bullets; degrade to a deterministic
    summary if it is unavailable. Returns (bullets, backend-used)."""
    if not open_actions and not decisions:
        return (["No open actions or recent decisions this period."], "none")
    facts = _format_facts(open_actions, decisions, today)
    try:
        result = engine.complete_text(
            cfg, system_prompt=_NARRATE_SYSTEM, user_message=facts, max_tokens=400
        )
        bullets = _parse_bullets(result.text)
        if bullets:
            return (bullets, result.backend)
        log.warning("digest narration returned no usable bullets; using a deterministic summary")
    except Exception as e:  # noqa: BLE001 - a scheduled digest must still generate if narration fails
        log.warning("digest narration engine unavailable (%s); using a deterministic summary", e)
    return (_fallback_bullets(open_actions, decisions, today, since_days), "none")


def _clamp_confidence(c: str) -> Confidence:
    """Coerce a confidence string read off disk onto the schema's Literal."""
    return c if c in _CONFIDENCE else "medium"


def build_digest_summary(
    open_actions: list[actions_mod.OpenAction],
    decisions: list[RecentDecision],
    bullets: list[str],
    *,
    today: date,
    since_days: int,
) -> MeetingSummary:
    """Assemble the digest as a `MeetingSummary` so it fans out through the same
    sinks a meeting does. The narrative is the `summary`; the decisions and
    actions are the deterministic, grounded facts (each decision keeps its source
    meeting title; every action carries its owner + due so a sink renders the
    checkbox + aging)."""
    start = today - timedelta(days=max(0, since_days))
    title = f"Weekly review ({start.isoformat()} to {today.isoformat()})"
    action_items = [
        ActionItem(task=a.task, owner=a.owner, due=a.due,
                   confidence=_clamp_confidence(a.confidence), resolved=False)
        for a in open_actions
    ]
    decision_strings = [f"{d.text} ({d.title})" for d in decisions]
    return MeetingSummary(
        title=title[:120],
        summary=bullets or ["No activity this period."],
        decisions=decision_strings,
        actions=action_items,
        questions=[],
        attendees=[],
        detected_language="en",
    )


def generate(cfg: Config, root: Path, *, since_days: int = DEFAULT_SINCE_DAYS,
             today: date | None = None) -> tuple[MeetingSummary, str]:
    """Aggregate the week's facts and narrate them. Returns (digest, backend)."""
    today = today or date.today()
    open_actions = collect_open_actions(root, today)
    decisions = collect_recent_decisions(root, today, since_days)
    bullets, backend = narrate(cfg, open_actions, decisions, today, since_days)
    return build_digest_summary(open_actions, decisions, bullets, today=today, since_days=since_days), backend


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(
        prog="mp digest",
        description="Generate a weekly review digest of aging actions + recent decisions (AI4).",
    )
    ap.add_argument("--dir", type=Path, default=None, help="override the recordings (library) directory")
    ap.add_argument("--out-dir", type=Path, default=None,
                    help="where to write the digest (default: a `digests` sibling of the library)")
    ap.add_argument("--since", type=int, default=DEFAULT_SINCE_DAYS,
                    help=f"decisions window in days (default {DEFAULT_SINCE_DAYS})")
    ap.add_argument("--publish", action="store_true", help="also fan the digest out to the configured sinks")
    ap.add_argument("--json", action="store_true", dest="as_json", help="emit JSON instead of text")
    args = ap.parse_args(argv)

    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")

    cfg = entry.prepare()  # SEC13: arm, then secrets. Library-wide, so no meeting anchor.

    root = Path(args.dir) if args.dir is not None else cfg.recording.output_dir
    out_dir = Path(args.out_dir) if args.out_dir is not None else Path(root).expanduser().parent / "digests"
    today = date.today()

    summary, backend = generate(cfg, Path(root), since_days=args.since, today=today)

    out_dir = out_dir.expanduser()
    out_dir.mkdir(parents=True, exist_ok=True)
    stem = f"digest-{today.strftime('%Y%m%d')}"
    json_path = out_dir / f"{stem}.summary.json"
    md_path = out_dir / f"{stem}.summary.md"
    json_path.write_text(summary.model_dump_json(indent=2, exclude_none=False), encoding="utf-8")
    md_path.write_text(render_summary_md(summary), encoding="utf-8")

    published = False
    publish_failed = False
    if args.publish:
        from .publish_router import all_sinks_failed, fanout
        pub = fanout(summary_json=json_path, cfg=cfg, transcript_md=None)
        published = True
        # PIPE8: honour the exit-3 contract every other fanout caller respects
        # (run-all / publish / publish-from-paste / merge), so a digest that
        # landed nowhere fails the run rather than reporting success. Zero sinks
        # configured is not a failure (`all_sinks_failed` is False there).
        publish_failed = all_sinks_failed(pub)

    events.emit("pipeline", "digest_generated", actions=len(summary.actions),
                decisions=len(summary.decisions), backend=backend, published=published,
                publish_failed=publish_failed)

    if args.as_json:
        print(json.dumps({
            "stem": stem, "json": str(json_path), "md": str(md_path),
            "actions": len(summary.actions), "decisions": len(summary.decisions),
            "backend": backend, "published": published, "publish_failed": publish_failed,
        }, indent=2))
    else:
        print(f"Wrote {md_path}")
        print(f"  {len(summary.actions)} open action(s), {len(summary.decisions)} recent decision(s); "
              f"narrative via {backend}" + ("; published" if published else ""))
        if publish_failed:
            print("  publish failed: every configured sink errored", file=sys.stderr)

    if publish_failed:
        from .publish_router import EXIT_PUBLISH_FAILED
        return EXIT_PUBLISH_FAILED
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main(sys.argv[1:]))
