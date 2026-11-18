"""The five read-only tools the MCP server exposes (AUTO3, leg 2).

Deliberately separate from `mcp_serve`: everything here is plain Python over
files on disk, returning JSON-able dicts, so the half of this feature that
carries the risk (which meetings are reachable, what a withheld stem looks like,
whether returned text is fenced) is unit-testable without the `mcp` SDK and runs
on the Linux CI runner where that SDK is not installed. `mcp_serve` is then a
thin transport that adopts these payloads.

Three properties hold for every function here and are what the tests pin:

1. **Every stem comes from `visibility`.** No function enumerates the library on
   its own terms; they all take the allowlist. The gate has one owner (leg 0),
   and a tool that filtered for itself would be a second one.
2. **A withheld stem is indistinguishable from a stem that never existed.** Both
   return `NOT_FOUND`, byte for byte. Withholding a meeting is worth little if
   the refusal confirms it is there.
3. **Returned meeting text is fenced as untrusted.** An MCP client is agentic
   and acts on what it reads, and transcripts are attacker-influenced input this
   codebase already fences for its own prompts (TECH-SEC6). The fence does not
   make injection impossible; it makes the boundary explicit, and it is the same
   marker pair `prompt_safety` uses everywhere else so a later rename cannot
   leave this surface fencing against markers nothing writes. AUTO8 made it hold
   for every model-written string, not just the content blocks: a meeting
   `title`, an action's `task` and `owner` are each fenced on their own, so the
   row shapes stay plain JSON a client can read field by field. A `due` that is
   an ISO date is a value and stays bare; any other `due` is model prose and is
   fenced. Stem, date, workflow and the flags are not model text.
"""
from __future__ import annotations

import json
import re
from datetime import date
from pathlib import Path
from typing import Any

from . import actions as actions_mod
from . import embed_index, storage, visibility
from .prompt_safety import clean_due, clean_person, wrap_untrusted
from .workflow import read_meta

#: The one refusal shape. Identical for a withheld meeting and for a stem that
#: was never recorded, which is property 2 above.
NOT_FOUND = "not_found"

#: How much transcript one `get_transcript` call may return. A whole meeting can
#: be hundreds of KB, and a tool that hands an agent the entire file by default
#: has quietly made "read one meeting" mean "read everything ever said in it".
DEFAULT_TRANSCRIPT_WINDOW = 4000
MAX_TRANSCRIPT_WINDOW = 20000

#: Excerpt length per search hit. Long enough to answer "what was decided", short
#: enough that five hits are a citation list rather than a transcript dump.
SEARCH_EXCERPT_CHARS = 900
DEFAULT_SEARCH_LIMIT = 5
MAX_SEARCH_LIMIT = 20

#: AUTO8. Longest action `task` any tool returns. `ActionItem.task` has no length
#: bound, so a dictated "action" can be a paragraph addressed to whatever reads it;
#: a real task fits in a sentence or two. A longer one is cut and ends in "...".
TASK_MAX_CHARS = 300

_STEM_DATE = re.compile(r"^(\d{8})")


def not_found(stem: str) -> dict[str, Any]:
    """The refusal every lookup returns for an unreachable stem.

    One function rather than a literal at each call site, because the whole
    property is that the two callers cannot differ.
    """
    return {"error": NOT_FOUND, "stem": stem}


def _meeting_date(stem: str) -> str | None:
    """`YYYY-MM-DD` from a `YYYYMMDD-HHMMSS` stem, or None for a hand-named one."""
    m = _STEM_DATE.match(stem)
    if not m:
        return None
    raw = m.group(1)
    try:
        return date(int(raw[:4]), int(raw[4:6]), int(raw[6:8])).isoformat()
    except ValueError:
        return None


def _summary(
    root: Path, stem: str, tally: storage.UnreadableTally | None = None
) -> dict[str, Any]:
    return storage.read_library_json(root / f"{stem}.summary.json", tally) or {}


def _task(text: str) -> str:
    """An action's task text, capped at `TASK_MAX_CHARS` (unfenced)."""
    return text if len(text) <= TASK_MAX_CHARS else text[: TASK_MAX_CHARS - 3] + "..."


def _fenced(text: str | None) -> str | None:
    """`wrap_untrusted`, passing None through so an absent owner stays absent."""
    return None if text is None else wrap_untrusted(text)


def _workflow_name(root: Path, stem: str) -> str | None:
    return str(read_meta(root / f"{stem}.meta.json").get("workflow_name") or "") or None


def _row(
    root: Path, stem: str, tally: storage.UnreadableTally | None = None
) -> dict[str, Any]:
    """One metadata row: no summary points, no decisions, no transcript. This is
    everything `list_meetings` may say about a meeting, and keeping it a separate
    function is what stops that list from growing content by accident."""
    summary = _summary(root, stem, tally)
    return {
        "stem": stem,
        "title": wrap_untrusted(str(summary.get("title") or stem)),
        "date": _meeting_date(stem),
        "workflow": _workflow_name(root, stem),
        "has_transcript": (root / f"{stem}.md").exists(),
    }


# --------------------------------------------------------------------------
# The five tools
# --------------------------------------------------------------------------


def search_meetings(
    root: Path,
    index: embed_index.EmbeddingIndex,
    query: str,
    limit: int = DEFAULT_SEARCH_LIMIT,
) -> dict[str, Any]:
    """Cited excerpts from the on-device index (use cases 1 and 3).

    `index` is expected to have been built under the same allowlist, so the
    filtering has already happened at chunk time; this never re-checks, and it
    must not, because a second check here would suggest the first is optional.
    The caller (`mcp_serve`) is the one place that builds the index, and it
    passes the gate.
    """
    limit = max(1, min(int(limit), MAX_SEARCH_LIMIT))
    hits = index.search(query, k=limit)
    results = [
        {
            "stem": h.chunk.stem,
            "title": wrap_untrusted(h.chunk.title),
            "date": _meeting_date(h.chunk.stem),
            "score": round(float(h.score), 4),
            "excerpt": wrap_untrusted(h.chunk.text[:SEARCH_EXCERPT_CHARS]),
        }
        for h in hits
    ]
    return {"query": query, "results": results, "count": len(results)}


def no_results(query: str) -> dict[str, Any]:
    """A search that found nothing. Also what an empty allowlist answers (AUTO6),
    so a session under regulated mode cannot tell "nothing matched" from "nothing
    may be searched"."""
    return {"query": query, "results": [], "count": 0}


def get_meeting(root: Path, stem: str, allow_stems: set[str]) -> dict[str, Any]:
    """One meeting's summary-level facts (use cases 1 and 3)."""
    root = Path(root).expanduser()
    if stem not in allow_stems:
        return not_found(stem)
    tally = storage.UnreadableTally()
    summary = _summary(root, stem, tally)
    # PIPE35: a summary that is there but cannot be read (an iCloud-evicted file answers
    # EDEADLK) is not a meeting with no points; say which, rather than empty lists.
    if (reason := tally.reason_for(root / f"{stem}.summary.json")) is not None:
        tally.warn(root)
        return {"stem": stem, "unreadable": reason}
    if not summary and not (root / f"{stem}.md").exists():
        return not_found(stem)
    points = [str(p) for p in (summary.get("summary") or []) if isinstance(p, str)]
    decisions = [str(d) for d in (summary.get("decisions") or []) if isinstance(d, str)]
    actions = [
        {
            "task": _task(str(a.get("task") or "")),
            "owner": clean_person(str(a["owner"])) if a.get("owner") else None,
            "due": clean_due(str(a["due"])) if a.get("due") else None,
            "resolved": bool(a.get("resolved") or a.get("done")),
        }
        for a in (summary.get("actions") or [])
        if isinstance(a, dict) and a.get("task")
    ]
    attendees = [str(p) for p in (summary.get("attendees") or []) if isinstance(p, str)]
    return {
        **_row(root, stem),
        # One fence around the whole summary block rather than per field: the
        # points, decisions and task strings are all engine prose over meeting
        # speech, so they share one trust level and one marker pair.
        "content": wrap_untrusted(
            json.dumps(
                {
                    "summary": points,
                    "decisions": decisions,
                    "actions": actions,
                    "attendees": attendees,
                },
                ensure_ascii=False,
                indent=2,
            )
        ),
    }


def get_transcript(
    root: Path,
    stem: str,
    allow_stems: set[str],
    *,
    around: str | None = None,
    window: int = DEFAULT_TRANSCRIPT_WINDOW,
) -> dict[str, Any]:
    """A bounded transcript window (use cases 1 and 3).

    `around` is a literal substring to centre on; without it the window starts at
    the top. Never the whole file by default, and never more than
    `MAX_TRANSCRIPT_WINDOW` even when asked: an agentic client that can pull an
    entire transcript in one call has the same reach as a client that can pull
    the library, one meeting at a time.
    """
    root = Path(root).expanduser()
    if stem not in allow_stems:
        return not_found(stem)
    path = root / f"{stem}.md"
    if not path.exists():
        return not_found(stem)
    # The overlaid view, not the raw file: speaker renames and text corrections
    # are applied at read time everywhere else (PIPE9 / FEAT3), so a client that
    # read the raw file would be quoting text the Library no longer shows.
    from .transcript_corrections import overlaid_markdown

    overlaid = overlaid_markdown(path)
    text = overlaid if overlaid is not None else path.read_text(encoding="utf-8", errors="ignore")
    window = max(200, min(int(window), MAX_TRANSCRIPT_WINDOW))

    start = 0
    if around:
        found = text.find(around)
        if found < 0:
            lowered = text.lower().find(around.lower())
            found = lowered
        if found >= 0:
            start = max(0, found - window // 2)
    excerpt = text[start : start + window]
    return {
        **_row(root, stem),
        "offset": start,
        "window": len(excerpt),
        "total_chars": len(text),
        "truncated": start + len(excerpt) < len(text) or start > 0,
        "content": wrap_untrusted(excerpt),
    }


def list_meetings(
    root: Path,
    allow_stems: set[str],
    *,
    since: str | None = None,
    until: str | None = None,
    workflow: str | None = None,
    limit: int = 100,
) -> dict[str, Any]:
    """Metadata rows only, no content (use case 2).

    ISO dates sort lexicographically, so `since` / `until` are string compares
    against the stem's own date; a hand-named stem has no date and is dropped by
    either bound rather than silently passing both.
    """
    root = Path(root).expanduser()
    rows = []
    tally = storage.UnreadableTally()
    for stem in sorted(visibility.library_stems(root), reverse=True):
        if stem not in allow_stems:
            continue
        row = _row(root, stem, tally)
        day = row["date"]
        if (since or until) and day is None:
            continue
        if since and day is not None and day < since:
            continue
        if until and day is not None and day > until:
            continue
        if workflow and (row["workflow"] or "").lower() != workflow.lower():
            continue
        rows.append(row)
        if len(rows) >= max(1, int(limit)):
            break
    tally.warn(root)
    # PIPE35: rows whose summary could not be read still list (titled by stem), and this
    # says how many, by reason, so a client knows those titles are not the meetings' own.
    return {"meetings": rows, "count": len(rows), "skipped_unreadable": tally.as_dict()}


def list_actions(
    root: Path,
    allow_stems: set[str],
    *,
    open_only: bool = True,
    since: str | None = None,
    today: date | None = None,
    limit: int = 200,
) -> dict[str, Any]:
    """Open commitments across the visible set (use case 2).

    Reuses `mp actions`' discovery and lifecycle filter rather than re-reading
    the summaries, so "open" means here exactly what it means in the app.

    AUTO8: every row that passes the filters is collected and ranked before the
    cut, then `limit` keeps the top: dated actions first by soonest `due`, then
    undated ones newest meeting first (ties inside a group also newest first). A
    `due` that is not an ISO date ranks as undated.
    Discovery walks the library oldest first, and it used to stop at `limit`
    there, so a library with more open actions than the limit answered with its
    oldest ones, re-sorted to look complete. `total` and `truncated` say when the
    answer is a page.
    """
    root = Path(root).expanduser()
    today = today or date.today()
    tally = storage.UnreadableTally()
    found = actions_mod.discover(root, allow_stems=allow_stems, tally=tally)
    tally.warn(root)
    if open_only:
        found = actions_mod.filter_actions(found, lifecycle="open", today=today)
    rows = []
    for a in found:
        day = _meeting_date(a.stem)
        if since and (day is None or day < since):
            continue
        # An ISO `due` is a date and ranks as one; "end of week" is model prose,
        # fenced, and ranks with the undated rows rather than above them all.
        dated = a.age_days(today) is not None
        rows.append({
            "stem": a.stem,
            "title": wrap_untrusted(a.title),
            "date": day,
            "task": wrap_untrusted(_task(a.task)),
            "owner": _fenced(a.owner),
            "due": a.due if dated else _fenced(a.due),
            "_rank_due": a.due if dated else None,
            "resolved": a.resolved,
            "overdue": a.is_overdue(today),
            "age_days": a.age_days(today),
            "workflow": a.workflow,
        })
    # Two stable sorts: newest meeting first, then dated before undated by due.
    rows.sort(key=lambda r: r["stem"], reverse=True)
    rows.sort(key=lambda r: (r["_rank_due"] is None, r["_rank_due"] or ""))
    for r in rows:
        del r["_rank_due"]
    page = rows[: max(1, int(limit))]
    # PIPE35: meetings whose summary could not be read contribute no actions; say how many.
    return {"actions": page, "count": len(page), "total": len(rows),
            "truncated": len(rows) > len(page), "skipped_unreadable": tally.as_dict()}
