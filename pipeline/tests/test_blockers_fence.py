"""OBS7 Fence B: main-thread blockers in daemon view and controller files.

`scripts/truth_fences.py` is a script, so it is loaded by path (the `test_link_fence.py` precedent).
Every case runs against a scratch tree, never the real sources, so a change to the real allowlist
cannot make these pass or fail by accident.
"""
from __future__ import annotations

import importlib.util
from pathlib import Path

import pytest

_FENCES = Path(__file__).resolve().parents[2] / "scripts" / "truth_fences.py"
_spec = importlib.util.spec_from_file_location("truth_fences_blockers", _FENCES)
assert _spec and _spec.loader
fences = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(fences)


def _tree(tmp_path: Path, files: dict[str, str]) -> Path:
    for rel, text in files.items():
        path = tmp_path / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    return tmp_path


def _passes(root: Path, allowlist: dict, capsys) -> tuple[bool, str]:
    ok = fences.check_blockers(root, allowlist)
    return ok, capsys.readouterr().out


def test_a_new_waitUntilExit_in_a_view_fails(tmp_path, capsys):
    root = _tree(tmp_path, {"FooView.swift": "func go() { p.run(); p.waitUntilExit() }\n"})
    ok, out = _passes(root, {}, capsys)
    assert not ok
    assert "FooView.swift:1" in out and "waitUntilExit" in out


@pytest.mark.parametrize("line", [
    "DispatchQueue.main.sync { }",
    "sem.wait()",
    "group.wait(timeout: .now() + 1)",
    "let d = try Data(contentsOf: url)",
    "let x = try FileManager.default.contentsOfDirectory(atPath: p)",
])
def test_each_pattern_is_caught_in_each_kind_of_file(tmp_path, capsys, line):
    for name in ("A" + "View.swift", "BWindow.swift", "CController.swift", "DPane.swift", "EMenu.swift"):
        _tree(tmp_path, {name: line + "\n"})
    ok, out = _passes(tmp_path, {}, capsys)
    assert not ok
    for name in ("AView.swift", "BWindow.swift", "CController.swift", "DPane.swift", "EMenu.swift"):
        assert name in out


def test_an_allowlisted_site_with_a_reason_passes(tmp_path, capsys):
    root = _tree(tmp_path, {"FooView.swift": "p.waitUntilExit()\n"})
    ok, _ = _passes(root, {("FooView.swift", "waitUntilExit"): (1, "inside a Task.detached")}, capsys)
    assert ok


def test_an_allowlist_entry_with_no_reason_fails(tmp_path, capsys):
    root = _tree(tmp_path, {"FooView.swift": "p.waitUntilExit()\n"})
    ok, out = _passes(root, {("FooView.swift", "waitUntilExit"): (1, "  ")}, capsys)
    assert not ok and "no reason" in out


def test_a_removed_listed_site_fails_as_stale(tmp_path, capsys):
    root = _tree(tmp_path, {"FooView.swift": "let x = 1\n"})
    ok, out = _passes(root, {("FooView.swift", "waitUntilExit"): (1, "inside a Task.detached")}, capsys)
    assert not ok and "stale" in out


def test_a_second_site_in_an_allowlisted_file_fails(tmp_path, capsys):
    root = _tree(tmp_path, {"FooView.swift": "p.waitUntilExit()\nq.waitUntilExit()\n"})
    ok, out = _passes(root, {("FooView.swift", "waitUntilExit"): (1, "inside a Task.detached")}, capsys)
    assert not ok and "expects 1" in out


def test_comments_and_files_outside_the_glob_are_ignored(tmp_path, capsys):
    root = _tree(tmp_path, {
        "FooView.swift": "// waitUntilExit() would block\n/* Data(contentsOf: x) */\nlet u = \"http://x\" // sem.wait()\n",
        "Helper.swift": "p.waitUntilExit()\n",
    })
    ok, _ = _passes(root, {}, capsys)
    assert ok


def test_the_real_tree_passes():
    assert fences.check_blockers()
