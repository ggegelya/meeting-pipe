#!/usr/bin/env python3
"""The backlog's state lives in each task's own header; the index is generated.

Every task in `docs/backlog/tasks/<ID>.md` opens with a header of plain
`key: value` lines between two `---` lines:

    ---
    id: ARCH7
    title: <the one-line task name>
    category: Architecture
    status: new
    priority: P2
    comment: <the compressed why and where it stands, one line>
    ---

plus `verification: simple|complex` while the status is `owner-verify`, and
`closed: <YYYY-MM-DD>` once it is `done`. `docs/backlog/INDEX.md` is rendered
from those headers and is never edited by hand.

Why: until 2026-10-26 every task's status lived in one hand-edited table in
`meetingpipe-q6-backlog.md` (and two more in `owner-verification.md` and
`q6-final.md`), so every filing, status change and close edited the same rows,
and two parallel sessions conflicted on almost every landing (the ToC was in
130 of the last 150 commits). Now a session edits only its own task file. The
index is marked `merge=union` in `.gitattributes`, so a rebase never stops on
it, and the landing step regenerates it; `check` fails CI when it is stale.

Links inside `comment:` are written relative to the task file, like every
other link in it, and are rewritten relative to `docs/backlog/` when the index
is rendered, so both files resolve under the CI5 link fence.

Stdlib only, so it runs under the system `python3` the way `truth_fences.py`
does.

    python3 scripts/backlog.py index             # rewrite INDEX.md
    python3 scripts/backlog.py check             # headers valid, INDEX.md fresh
    python3 scripts/backlog.py next-id UX        # next free number in a band
    python3 scripts/backlog.py list [--status S] [--priority P] [--category C]
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
BACKLOG = REPO / "docs" / "backlog"
TASKS = BACKLOG / "tasks"
INDEX = BACKLOG / "INDEX.md"

STATUSES = ("new", "partial", "watch", "deferred", "owner-verify", "done")
PRIORITIES = ("P1", "P2", "P3", "P4")
WEIGHTS = ("simple", "complex")
REQUIRED = ("id", "title", "category", "status", "priority", "comment")
OPTIONAL = ("verification", "closed")

_KEY_RE = re.compile(r"^([a-z]+): ?(.*)$")
_DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
_ID_RE = re.compile(r"^([A-Z]+)(\d*)(.*)$")
_INLINE_CODE_RE = re.compile(r"``[^`]*``|`[^`]*`")
_LINK_RE = re.compile(r"(\[[^\]]*\]\()([^)\s]+)")
_SCHEME_RE = re.compile(r"^[A-Za-z][A-Za-z0-9+.\-]*:")


@dataclass
class Task:
    id: str
    title: str
    category: str
    status: str
    priority: str
    comment: str
    verification: str = ""
    closed: str = ""


def split_header(text: str) -> tuple[dict[str, str] | None, str]:
    """The header's fields and the body after it, or (None, text) without one."""
    lines = text.split("\n")
    if not lines or lines[0] != "---":
        return None, text
    fields: dict[str, str] = {}
    for n, line in enumerate(lines[1:], start=1):
        if line == "---":
            return fields, "\n".join(lines[n + 1 :])
        m = _KEY_RE.match(line)
        if m is None:
            return None, text
        fields[m.group(1)] = m.group(2).strip()
    return None, text


def render_header(task: Task) -> str:
    out = ["---"]
    for key in REQUIRED[:5]:
        out.append(f"{key}: {getattr(task, key)}")
    if task.verification:
        out.append(f"verification: {task.verification}")
    if task.closed:
        out.append(f"closed: {task.closed}")
    out.append(f"comment: {task.comment}")
    out.append("---")
    return "\n".join(out) + "\n"


def relocate_links(text: str, src: Path, dst: Path) -> str:
    """Rewrite each relative link in `text` from base `src` to base `dst`.

    Links inside inline code are left alone, matching what the CI5 link fence
    treats as a link; URLs with a scheme and bare anchors are not paths.
    """

    def move(m: re.Match[str]) -> str:
        target = m.group(2)
        if _SCHEME_RE.match(target) or target.startswith(("#", "//")):
            return m.group(0)
        path, sep, anchor = target.partition("#")
        if not path:
            return m.group(0)
        moved = os.path.relpath(os.path.normpath(src / path), dst)
        if path.startswith("./") and not moved.startswith("."):
            moved = "./" + moved
        return m.group(1) + moved + sep + anchor

    # A link whose text is code (`[`x.md`](./x.md)`) is still a link to the
    # fence, so only a target that sits inside a code span is left alone.
    spans = [m.span() for m in _INLINE_CODE_RE.finditer(text)]

    def maybe_move(m: re.Match[str]) -> str:
        at = m.start(2)
        if any(start <= at < end for start, end in spans):
            return m.group(0)
        return move(m)

    return _LINK_RE.sub(maybe_move, text)


def load(tasks_dir: Path = TASKS) -> tuple[list[Task], list[str]]:
    """Every task header under `tasks_dir`, plus one error per invalid file."""
    tasks: list[Task] = []
    errors: list[str] = []
    for path in sorted(tasks_dir.glob("*.md")):
        name = path.name
        fields, _ = split_header(path.read_text(encoding="utf-8"))
        if fields is None:
            errors.append(f"{name}: no header (a `---` block of `key: value` lines on line 1)")
            continue
        missing = [k for k in REQUIRED if not fields.get(k)]
        unknown = sorted(set(fields) - set(REQUIRED) - set(OPTIONAL))
        if missing:
            errors.append(f"{name}: header is missing {', '.join(missing)}")
        if unknown:
            errors.append(f"{name}: header has unknown keys {', '.join(unknown)}")
        if missing:
            continue
        task = Task(**{k: v for k, v in fields.items() if k in REQUIRED + OPTIONAL})
        if task.id != path.stem:
            errors.append(f"{name}: id `{task.id}` does not match the file name")
        if task.status not in STATUSES:
            errors.append(f"{name}: status `{task.status}` is not one of {', '.join(STATUSES)}")
        if task.priority not in PRIORITIES:
            errors.append(f"{name}: priority `{task.priority}` is not one of {', '.join(PRIORITIES)}")
        if (task.status == "owner-verify") != bool(task.verification):
            errors.append(f"{name}: `verification:` is set exactly when status is owner-verify")
        elif task.verification and task.verification not in WEIGHTS:
            errors.append(f"{name}: verification `{task.verification}` is not simple or complex")
        if (task.status == "done") != bool(task.closed):
            errors.append(f"{name}: `closed:` is set exactly when status is done")
        elif task.closed and not _DATE_RE.match(task.closed):
            errors.append(f"{name}: closed `{task.closed}` is not a YYYY-MM-DD date")
        tasks.append(task)
    return tasks, errors


def id_key(task_id: str) -> tuple[str, int, str]:
    m = _ID_RE.match(task_id)
    if m is None:
        return (task_id, 0, "")
    return (m.group(1), int(m.group(2) or 0), m.group(3))


def _row(task: Task, fourth: str, tasks_dir: Path, index_dir: Path) -> str:
    link = os.path.relpath(tasks_dir / f"{task.id}.md", index_dir)
    comment = relocate_links(task.comment, tasks_dir, index_dir)
    return (
        f"| [{task.id}](./{link}) | {task.title} | {task.category} | {fourth} "
        f"| {task.priority} | {comment} |"
    )


def _table(rows: list[str], fourth: str) -> list[str]:
    if not rows:
        return ["_None._", ""]
    return [
        f"| ID | Task | Category | {fourth} | Priority | Comment |",
        "|---|---|---|---|---|---|",
        *rows,
        "",
    ]


def render_index(tasks: list[Task], tasks_dir: Path = TASKS, index_dir: Path = BACKLOG) -> str:
    def rows(selected: list[Task], fourth: str) -> list[str]:
        return [_row(t, getattr(t, fourth), tasks_dir, index_dir) for t in selected]

    by_priority = lambda t: (t.priority, id_key(t.id))  # noqa: E731
    open_tasks = [t for t in tasks if t.status not in ("owner-verify", "done")]
    active = sorted((t for t in open_tasks if t.priority in ("P1", "P2")), key=by_priority)
    parked = sorted((t for t in open_tasks if t.priority in ("P3", "P4")), key=by_priority)
    verify = [t for t in tasks if t.status == "owner-verify"]
    done = sorted(
        (t for t in tasks if t.status == "done"),
        key=lambda t: (t.closed, id_key(t.id)),
        reverse=True,
    )

    out = [
        "# MeetingPipe backlog index",
        "",
        "Generated by `python3 scripts/backlog.py index` from the header of every "
        "[`tasks/<ID>.md`](./tasks/). Do not edit it by hand: change the task's header "
        "and regenerate. CI fails when this file is stale. Process rules, priority bands "
        "and band origins live in [`meetingpipe-q6-backlog.md`](./meetingpipe-q6-backlog.md); "
        "the owner-verification gate lives in [`owner-verification.md`](./owner-verification.md).",
        "",
        f"## Active (P1 and P2): {len(active)}",
        "",
        *_table(rows(active, "status"), "Status"),
        f"## Owner verification: {len(verify)}",
        "",
        "Shipped and green, waiting on the owner to confirm it behaves. Not work a session "
        "picks up; see the gate in [`owner-verification.md`](./owner-verification.md).",
        "",
    ]
    for weight in WEIGHTS:
        selected = sorted((t for t in verify if t.verification == weight), key=by_priority)
        out += [f"### {weight.capitalize()}", "", *_table(rows(selected, "verification"), "Verification")]
    out += [
        f"## Parked (P3 and P4): {len(parked)}",
        "",
        "Parked by the P3 rule in the root `CLAUDE.md`: leave these alone unless a task "
        "explicitly promotes one.",
        "",
        *_table(rows(parked, "status"), "Status"),
        f"## Done: {len(done)}",
        "",
        "Closed tasks keep their file in `tasks/`, newest first. Tasks closed before "
        "2026-10-26 are in the quarter archives (`q3-final.md` to `q6-final.md`).",
        "",
        *_table(rows(done, "closed"), "Closed"),
    ]
    return "\n".join(out).rstrip("\n") + "\n"


def next_id(band: str, repo: Path = REPO) -> str:
    """The next unused `<band><n>`, searched across every tracked file."""
    pattern = rf"\b{re.escape(band)}[0-9]+"
    try:
        found = subprocess.run(
            ["git", "-C", str(repo), "grep", "-ohE", pattern],
            capture_output=True,
            text=True,
            check=False,
        ).stdout
    except FileNotFoundError:
        found = ""
    numbers = [int(m[len(band) :]) for m in re.findall(pattern, found)]
    numbers += [id_key(p.stem)[1] for p in TASKS.glob(f"{band}[0-9]*.md") if id_key(p.stem)[0] == band]
    return f"{band}{max(numbers, default=0) + 1}"


def check(tasks_dir: Path = TASKS, index: Path = INDEX, minimum: int = 50) -> list[str]:
    tasks, errors = load(tasks_dir)
    # Staleness guard, as in truth_fences.py: a walker that stops finding the
    # tree would otherwise pass an empty index as fresh.
    if len(tasks) + len(errors) < minimum:
        errors.append(f"only found {len(tasks) + len(errors)} task files; the walker is stale")
    if errors:
        return errors
    expected = render_index(tasks, tasks_dir, index.parent)
    actual = index.read_text(encoding="utf-8") if index.exists() else ""
    if actual != expected:
        errors.append(
            f"{index.relative_to(REPO) if index.is_relative_to(REPO) else index} is stale; "
            "run `python3 scripts/backlog.py index` and commit the result"
        )
    return errors


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="backlog.py", description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("index", help="rewrite docs/backlog/INDEX.md from the task headers")
    sub.add_parser("check", help="fail on an invalid header or a stale INDEX.md")
    nid = sub.add_parser("next-id", help="next free number in a band, e.g. UX")
    nid.add_argument("band")
    ls = sub.add_parser("list", help="print matching tasks, one per line")
    ls.add_argument("--status")
    ls.add_argument("--priority")
    ls.add_argument("--category")
    args = parser.parse_args(argv)

    if args.cmd == "next-id":
        print(next_id(args.band.upper()))
        return 0
    if args.cmd == "check":
        errors = check()
        for e in errors:
            print(f"::error::backlog: {e}")
        return 1 if errors else 0

    tasks, errors = load()
    if errors:
        for e in errors:
            print(f"error: {e}", file=sys.stderr)
        return 1
    if args.cmd == "index":
        INDEX.write_text(render_index(tasks), encoding="utf-8")
        print(f"wrote {INDEX.relative_to(REPO)} ({len(tasks)} tasks)")
        return 0
    for t in sorted(tasks, key=lambda t: (t.priority, id_key(t.id))):
        if args.status and t.status != args.status:
            continue
        if args.priority and t.priority != args.priority:
            continue
        if args.category and t.category.lower() != args.category.lower():
            continue
        print(f"{t.id}\t{t.priority}\t{t.status}\t{t.category}\t{t.title}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
