"""`mp digest` - weekly review digest, async and on-device (AI4).

Aggregates the week's aging open action items and recent decisions from the
library (deterministic, read straight from `<stem>.summary.json`, so the facts in
the digest are grounded and never hallucinated), then asks the on-device engine
to write a short narrative "state of your week" over those facts. The result is a
`MeetingSummary` written to disk and, with `--publish`, fanned out through the
existing sinks.

AI10 bounds the action half. A roll-up of every open action ever ran to 970 items
on the real 199-meeting library, which is a dump rather than a review, so the list
is scoped to the review window (`in_review_window`), grouped by workflow, ranked
most-pressing-first, and capped (`scope_actions`). What the caps drop is counted
rather than carried, and the `SCOPE_SECTION` the digest appends says so.

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
from .schemas import ActionItem, Confidence, ExtraSection, MeetingSummary
from .markdown import render_summary_md

log = logging.getLogger("mp.digest")

DEFAULT_SINCE_DAYS = 7
# Bound the facts fed to the model (prompt size). A narrative is a summary, so
# the top slice of the review window is enough to write one from.
MAX_FACTS = 30
# AI10: how much of the action list the digest renders inline. The window scope
# below does most of the bounding; these two are the backstop for a dense week.
# Before them the digest rolled up every open action in the library, which was
# 970 items on the real 199-meeting library: past reading, and a dump rather
# than a review.
MAX_ACTIONS = 25
MAX_PER_GROUP = 5
#: Name of the section the digest appends to say what it left out and where the
#: rest is. Bounded output has to admit that it is bounded, or the number the
#: reader sees quietly becomes the number they believe.
SCOPE_SECTION = "Action scope"
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


# --------------------------------------------------------------------------
# AI10: bounding the action list
# --------------------------------------------------------------------------


@dataclass
class ActionGroup:
    """One workflow's (or one untagged meeting's) slice of the review window:
    what the digest renders inline, and how many the window actually holds."""
    name: str
    shown: list[actions_mod.OpenAction]
    total: int

    @property
    def hidden(self) -> int:
        return max(0, self.total - len(self.shown))


@dataclass
class ActionScope:
    """What the digest shows, and what it is not showing (AI10)."""
    groups: list[ActionGroup]
    #: Open actions inside the review window, shown or not.
    window_total: int
    #: Open actions anywhere in the library, in the window or not.
    library_total: int
    #: Groups the window holds, rendered or dropped by the total cap.
    group_total: int
    #: Past-due actions inside the window, shown or not. Counted here because the
    #: narrative leads with it and the shown slice cannot be counted for it.
    overdue_total: int = 0

    @property
    def shown(self) -> int:
        return sum(len(g.shown) for g in self.groups)

    @property
    def actions(self) -> list[actions_mod.OpenAction]:
        """The rendered actions, flattened in group order."""
        return [a for g in self.groups for a in g.shown]


def in_review_window(a: actions_mod.OpenAction, today: date, since_days: int) -> bool:
    """Does this open action belong to *this* review period? (AI10)

    Two ways in, and the union is deliberate:

    - it was raised in the window (its meeting is dated on or after the start), or
    - it is already overdue, due today, or due inside the window ahead.

    What that leaves out is the dormant backlog: an undated action from a meeting
    months ago that nobody closed and nothing will ever make due. That set is the
    bulk of a large library's open actions and is what turned the digest into a
    dump. Keeping overdue items regardless of age is the other half: the oldest
    broken promise is exactly what a weekly review is for, so the window bounds
    what is *dormant*, not what is *old*.
    """
    start = today - timedelta(days=max(0, since_days))
    day = _meeting_day(a.stem)
    if day is not None and day >= start:
        return True
    # `age_days` is "overdue positive", so one comparison covers overdue, due
    # today, and due inside the window ahead.
    age = a.age_days(today)
    return age is not None and age >= -max(0, since_days)


def _urgency(a: actions_mod.OpenAction, today: date) -> tuple[int, int, int]:
    """Rank key: overdue first (most overdue first), then dated and coming
    (soonest first), then undated. Higher confidence breaks a tie, so a firm
    commitment outranks a hedged one with the same deadline."""
    conf = _CONFIDENCE.index(a.confidence) if a.confidence in _CONFIDENCE else 1
    age = a.age_days(today)
    if age is None:
        return (2, 0, -conf)
    return (0 if age > 0 else 1, -age, -conf)


def rank_actions(scoped: list[actions_mod.OpenAction], today: date) -> list[actions_mod.OpenAction]:
    """Most pressing first. Recency is the last tiebreak and is applied as a
    pre-sort that the (stable) urgency sort preserves, because stems sort as
    strings and a single key would have to invert one."""
    ranked = sorted(scoped, key=lambda a: a.stem, reverse=True)
    ranked.sort(key=lambda a: _urgency(a, today))
    return ranked


def _group_name(a: actions_mod.OpenAction) -> str:
    """AI7 stamped every action with its meeting's workflow, which is the series
    key; an untagged meeting groups under its own title."""
    return a.workflow or a.title or a.stem


def scope_actions(open_actions: list[actions_mod.OpenAction], today: date, since_days: int, *,
                  max_total: int = MAX_ACTIONS,
                  max_per_group: int = MAX_PER_GROUP) -> ActionScope:
    """Scope the library's open actions to the review window, then group, rank
    and cap what the digest renders inline (AI10).

    Group order falls out of the ranking rather than a second sort: buckets are
    created in ranked order, so the group holding the single most pressing action
    comes first, and a dict keeps that insertion order. What the caps drop is
    counted, never carried, so the digest can say how much it is not showing.
    """
    scoped = [a for a in open_actions if in_review_window(a, today, since_days)]
    buckets: dict[str, list[actions_mod.OpenAction]] = {}
    for a in rank_actions(scoped, today):
        buckets.setdefault(_group_name(a), []).append(a)

    groups: list[ActionGroup] = []
    budget = max(0, max_total)
    for name, items in buckets.items():
        if budget <= 0:
            break
        shown = items[:min(max(0, max_per_group), budget)]
        if not shown:
            break
        groups.append(ActionGroup(name=name, shown=shown, total=len(items)))
        budget -= len(shown)

    return ActionScope(groups=groups, window_total=len(scoped),
                       library_total=len(open_actions), group_total=len(buckets),
                       overdue_total=sum(1 for a in scoped if a.is_overdue(today)))


def scope_section(scope: ActionScope, since_days: int) -> ExtraSection | None:
    """The section that keeps a bounded digest honest: how much of the window it
    showed, which groups are trimmed, and where the rest lives. None when the
    digest is showing everything there is, so a small library gains no noise."""
    if scope.shown == scope.window_total == scope.library_total:
        return None
    content = [
        f"Showing {scope.shown} of {scope.window_total} open action(s) from the last "
        f"{since_days} day(s), across {len(scope.groups)} of {scope.group_total} group(s)."
    ]
    content += [
        f"{g.name}: {len(g.shown)} of {g.total} shown"
        for g in scope.groups if g.hidden
    ]
    if scope.library_total > scope.window_total:
        content.append(
            f"{scope.library_total} open action(s) library-wide; the rest are dormant "
            "(undated, from before this window). Full list: the Facts rail, or `mp actions --open`."
        )
    return ExtraSection(name=SCOPE_SECTION, content=content)


def _format_facts(scope: ActionScope, decisions: list[RecentDecision], today: date) -> str:
    open_actions = scope.actions
    lines: list[str] = ["OPEN ACTIONS (most overdue first):"]
    # AI10: tell the model it is looking at a slice, so a narrative written from
    # a capped list does not assert the cap as the total.
    if scope.window_total > len(open_actions):
        lines[0] = (f"OPEN ACTIONS (most overdue first; the {len(open_actions)} most pressing of "
                    f"{scope.window_total} in this period, {scope.overdue_total} of them overdue):")
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


def _fallback_bullets(scope: ActionScope, decisions: list[RecentDecision],
                      today: date, since_days: int) -> list[str]:
    """A deterministic narrative when the engine is unavailable, so the digest
    still generates. Grounded in the same counts the facts carry, and in the
    window's totals rather than the shown slice's (AI10)."""
    overdue = [a for a in scope.actions if a.is_overdue(today)]
    bullets = [f"{scope.window_total} open action item(s) in the last {since_days} day(s), "
               f"{scope.overdue_total} overdue."]
    if overdue:
        worst = max(overdue, key=lambda a: a.age_days(today) or 0)
        bullets.append(f"Most overdue: {worst.task} ({worst.age_days(today)}d past due).")
    bullets.append(f"{len(decisions)} decision(s) recorded in the last {since_days} days.")
    return bullets[:5]


def narrate(cfg: Config, scope: ActionScope, decisions: list[RecentDecision],
            today: date, since_days: int) -> tuple[list[str], str]:
    """Ask the engine for the narrative bullets; degrade to a deterministic
    summary if it is unavailable. Returns (bullets, backend-used)."""
    if not scope.actions and not decisions:
        return (["No open actions or recent decisions this period."], "none")
    facts = _format_facts(scope, decisions, today)
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
    return (_fallback_bullets(scope, decisions, today, since_days), "none")


def _clamp_confidence(c: str) -> Confidence:
    """Coerce a confidence string read off disk onto the schema's Literal."""
    return c if c in _CONFIDENCE else "medium"


def build_digest_summary(
    scope: ActionScope,
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
    checkbox + aging, plus its AI10 group so the list renders as named groups
    rather than one long run). The scope section says what the caps left out."""
    start = today - timedelta(days=max(0, since_days))
    title = f"Weekly review ({start.isoformat()} to {today.isoformat()})"
    action_items = [
        ActionItem(task=a.task, owner=a.owner, due=a.due,
                   confidence=_clamp_confidence(a.confidence), resolved=False,
                   group=g.name)
        for g in scope.groups for a in g.shown
    ]
    decision_strings = [f"{d.text} ({d.title})" for d in decisions]
    note = scope_section(scope, since_days)
    return MeetingSummary(
        title=title[:120],
        summary=bullets or ["No activity this period."],
        decisions=decision_strings,
        actions=action_items,
        questions=[],
        attendees=[],
        detected_language="en",
        extra_sections=[note] if note else [],
    )


@dataclass
class DigestResult:
    """A generated digest plus the counts behind it, so a caller can report what
    was bounded away without recomputing the scope."""
    summary: MeetingSummary
    backend: str
    scope: ActionScope


def generate(cfg: Config, root: Path, *, since_days: int = DEFAULT_SINCE_DAYS,
             today: date | None = None) -> DigestResult:
    """Aggregate the week's facts, bound them to the review window, and narrate."""
    today = today or date.today()
    scope = scope_actions(collect_open_actions(root, today), today, since_days)
    decisions = collect_recent_decisions(root, today, since_days)
    # Narrate over the window (ranked, most pressing first), not the library: a
    # narrative that names a commitment the list below does not carry reads as a
    # hallucination even when it is true. The facts carry the window's totals so
    # the narrative can still say how much sits behind the shown slice.
    bullets, backend = narrate(cfg, scope, decisions, today, since_days)
    summary = build_digest_summary(scope, decisions, bullets, today=today, since_days=since_days)
    return DigestResult(summary=summary, backend=backend, scope=scope)


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

    result = generate(cfg, Path(root), since_days=args.since, today=today)
    summary, backend, scope = result.summary, result.backend, result.scope

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

    # AI10: `actions` is what the digest renders; the two totals say what it was
    # bounded down from, so a run that hid 900 items is visible in the event log.
    events.emit("pipeline", "digest_generated", actions=len(summary.actions),
                actions_in_window=scope.window_total, actions_open=scope.library_total,
                decisions=len(summary.decisions), backend=backend, published=published,
                publish_failed=publish_failed)

    if args.as_json:
        print(json.dumps({
            "stem": stem, "json": str(json_path), "md": str(md_path),
            "actions": len(summary.actions), "actions_in_window": scope.window_total,
            "actions_open": scope.library_total, "decisions": len(summary.decisions),
            "backend": backend, "published": published, "publish_failed": publish_failed,
        }, indent=2))
    else:
        print(f"Wrote {md_path}")
        print(f"  {len(summary.actions)} of {scope.window_total} open action(s) from the last "
              f"{args.since} day(s) ({scope.library_total} open library-wide), "
              f"{len(summary.decisions)} recent decision(s); "
              f"narrative via {backend}" + ("; published" if published else ""))
        if publish_failed:
            print("  publish failed: every configured sink errored", file=sys.stderr)

    if publish_failed:
        from .publish_router import EXIT_PUBLISH_FAILED
        return EXIT_PUBLISH_FAILED
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main(sys.argv[1:]))
