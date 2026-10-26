"""The backlog index is generated from per-task headers; pin the generator.

Task state used to live in one hand-edited table that every parallel session
rewrote, so landings conflicted on almost every rebase. `scripts/backlog.py`
moved the state into each `tasks/<ID>.md` header and renders
`docs/backlog/INDEX.md` from them. These tests pin the parts that would fail
quietly: the header contract, the link rewrite between the two base
directories, the section a task lands in, and the staleness check CI relies on.

`scripts/backlog.py` is a script rather than a package module, so it is loaded
by path, following `test_link_fence.py`.
"""
from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

_SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "backlog.py"


def _load():
    spec = importlib.util.spec_from_file_location("backlog", _SCRIPT)
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    # `@dataclass` resolves string annotations through sys.modules.
    sys.modules["backlog"] = mod
    spec.loader.exec_module(mod)
    return mod


bl = _load()


def _task(**over):
    fields = dict(
        id="UX1", title="A task", category="UX", status="new", priority="P2", comment="Filed."
    )
    fields.update(over)
    return bl.Task(**fields)


def _write(tasks_dir: Path, task, body: str = "# body\n") -> None:
    (tasks_dir / f"{task.id}.md").write_text(bl.render_header(task) + "\n" + body, encoding="utf-8")


# --- the header ---------------------------------------------------------------


def test_header_round_trips_and_keeps_the_body():
    task = _task(status="owner-verify", verification="simple", comment="a: colon | kept")
    fields, body = bl.split_header(bl.render_header(task) + "\n# UX1: A task\n")
    assert fields == {
        "id": "UX1",
        "title": "A task",
        "category": "UX",
        "status": "owner-verify",
        "priority": "P2",
        "verification": "simple",
        "comment": "a: colon | kept",
    }
    assert body == "\n# UX1: A task\n"


def test_a_file_without_a_header_is_reported_not_skipped(tmp_path):
    (tmp_path / "UX1.md").write_text("# UX1: no header\n", encoding="utf-8")
    tasks, errors = bl.load(tmp_path)
    assert tasks == []
    assert errors and "no header" in errors[0]


def test_invalid_headers_name_each_defect(tmp_path):
    _write(tmp_path, _task(id="UX2", status="started"))
    _write(tmp_path, _task(id="UX3", status="done"))
    _write(tmp_path, _task(id="UX4", verification="simple"))
    (tmp_path / "UX5.md").write_text(bl.render_header(_task(id="UX9")), encoding="utf-8")
    _, errors = bl.load(tmp_path)
    joined = "\n".join(errors)
    assert "UX2.md: status `started`" in joined
    assert "UX3.md: `closed:` is set exactly when status is done" in joined
    assert "UX4.md: `verification:` is set exactly when status is owner-verify" in joined
    assert "UX5.md: id `UX9` does not match the file name" in joined


# --- links move between the task file and the index ----------------------------


def test_links_are_rebased_from_the_task_dir_to_the_index_dir(tmp_path):
    tasks_dir = tmp_path / "docs" / "backlog" / "tasks"
    index_dir = tasks_dir.parent
    text = (
        "see [DET13](./DET13.md), [spike](../../spikes/x.md#leg-2), "
        "[ov](../owner-verification.md), [web](https://example.com/a.md), "
        "[here](#anchor), [`code text`](./DET13.md), and `[not a link](./DET13.md)`"
    )
    moved = bl.relocate_links(text, tasks_dir, index_dir)
    assert moved == (
        "see [DET13](./tasks/DET13.md), [spike](../spikes/x.md#leg-2), "
        "[ov](owner-verification.md), [web](https://example.com/a.md), "
        "[here](#anchor), [`code text`](./tasks/DET13.md), and `[not a link](./DET13.md)`"
    )
    assert bl.relocate_links(moved, index_dir, tasks_dir).startswith("see [DET13](./DET13.md)")


# --- the index ----------------------------------------------------------------


def test_each_task_lands_in_exactly_one_section(tmp_path):
    tasks = [
        _task(id="UX10", priority="P1"),
        _task(id="UX9", priority="P1"),
        _task(id="DET1", priority="P2", status="partial"),
        _task(id="CAP1", priority="P3", status="watch"),
        _task(id="DOC13", status="owner-verify", verification="simple"),
        _task(id="REC12", status="owner-verify", verification="complex", priority="P1"),
        _task(id="HYG9", status="done", closed="2026-10-26"),
    ]
    text = bl.render_index(tasks, tmp_path / "tasks", tmp_path)
    sections = {
        s.split("\n", 1)[0]: s for s in text.split("\n## ")[1:]
    }
    assert set(sections) == {
        "Active (P1 and P2): 3",
        "Owner verification: 2",
        "Parked (P3 and P4): 1",
        "Done: 1",
    }
    active = sections["Active (P1 and P2): 3"]
    # P1 before P2, and the ID number sorts as a number, not as text.
    assert active.index("[UX9]") < active.index("[UX10]") < active.index("[DET1]")
    verify = sections["Owner verification: 2"]
    assert verify.index("### Simple") < verify.index("[DOC13]") < verify.index("### Complex")
    assert verify.index("### Complex") < verify.index("[REC12]")
    assert "| [CAP1](./tasks/CAP1.md) | A task | UX | watch | P3 |" in sections["Parked (P3 and P4): 1"]
    assert "| 2026-10-26 | P2 |" in sections["Done: 1"]
    for task in tasks:
        assert text.count(f"[{task.id}]") == 1


def test_check_passes_a_fresh_index_and_fails_a_stale_one(tmp_path):
    tasks_dir = tmp_path / "tasks"
    tasks_dir.mkdir()
    _write(tasks_dir, _task())
    index = tmp_path / "INDEX.md"
    tasks, _ = bl.load(tasks_dir)
    index.write_text(bl.render_index(tasks, tasks_dir, tmp_path), encoding="utf-8")
    assert bl.check(tasks_dir, index, minimum=1) == []

    _write(tasks_dir, _task(status="partial"))
    errors = bl.check(tasks_dir, index, minimum=1)
    assert len(errors) == 1 and "is stale" in errors[0]


def test_check_refuses_an_empty_walk(tmp_path):
    errors = bl.check(tmp_path, tmp_path / "INDEX.md")
    assert errors and "walker is stale" in errors[0]
