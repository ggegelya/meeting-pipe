"""T3: `mp`'s front door. Every registered command name resolves to a real
`main`, and the router's own conventions hold.

`__main__.main` is a flat if-ladder of string comparisons with lazy per-branch
imports (deliberately: `--help` and `--version` should not pay a package's
import cost). Nothing tested it, so a subcommand could be registered under a
name whose module had been renamed and the only symptom would be a user typing
the command and getting `unknown subcommand`.

The command names are AST-extracted from the router rather than transcribed, the
same idiom `test_entry_contract.py` uses, so this file cannot go stale against a
newly added subcommand: a new one is picked up and tested automatically.
"""
from __future__ import annotations

import ast
import importlib
import inspect
from pathlib import Path

import pytest

SRC = Path(__file__).resolve().parents[1] / "src" / "mp"
MAIN = SRC / "__main__.py"

# Names handled before the dispatch ladder, so they have no target module.
PRE_DISPATCH = {"", "-h", "--help", "help", "--version"}


def _dispatch_table() -> dict[str, str]:
    """Map every accepted command spelling to the module it dispatches to.

    Walks the `if cmd == "x":` / `if cmd in {"x", "y"}:` branches and pairs each
    with the `from .<module> import main as run` inside that branch's body.
    """
    tree = ast.parse(MAIN.read_text(encoding="utf-8"))
    table: dict[str, str] = {}

    for node in ast.walk(tree):
        if not isinstance(node, ast.If):
            continue

        names: list[str] = []
        test = node.test
        if isinstance(test, ast.Compare) and len(test.ops) == 1:
            left, op, right = test.left, test.ops[0], test.comparators[0]
            if not (isinstance(left, ast.Name) and left.id == "cmd"):
                continue
            if isinstance(op, ast.Eq) and isinstance(right, ast.Constant):
                names = [right.value]
            elif isinstance(op, ast.In) and isinstance(right, (ast.Set, ast.Tuple, ast.List)):
                names = [
                    e.value for e in right.elts
                    if isinstance(e, ast.Constant) and isinstance(e.value, str)
                ]
        if not names:
            continue

        module = None
        for child in ast.walk(node):
            if (
                isinstance(child, ast.ImportFrom)
                and child.level == 1
                and child.module
                and any(a.name == "main" for a in child.names)
            ):
                module = child.module
                break
        if module:
            for name in names:
                table[name] = module

    return table


TABLE = _dispatch_table()


def test_dispatch_table_is_discoverable() -> None:
    """Guard the guard. An extractor that silently stops matching would make
    every parametrized test below vacuously green."""
    assert len(TABLE) >= 30, f"only found {len(TABLE)} command spellings"
    assert len(set(TABLE.values())) >= 20


@pytest.mark.parametrize("name", sorted(TABLE))
def test_every_registered_command_resolves_to_a_real_main(name: str) -> None:
    """The load-bearing assertion: the name a user types reaches a callable.

    This is what a lazy-import router cannot tell you at startup. A renamed or
    deleted module stays invisible until someone runs that exact subcommand.
    """
    module = importlib.import_module(f"mp.{TABLE[name]}")
    assert hasattr(module, "main"), f"mp.{TABLE[name]} has no main()"
    assert callable(module.main)


@pytest.mark.parametrize("name", sorted(TABLE))
def test_every_main_takes_an_argv_list(name: str) -> None:
    """`main(argv: list[str]) -> int` is the subcommand contract; the router
    passes `rest` positionally to all of them."""
    sig = inspect.signature(importlib.import_module(f"mp.{TABLE[name]}").main)
    positional = [
        p for p in sig.parameters.values()
        if p.kind in (p.POSITIONAL_ONLY, p.POSITIONAL_OR_KEYWORD)
    ]
    assert len(positional) >= 1, f"mp.{TABLE[name]}.main takes no argv"


def test_multiword_commands_carry_both_spellings() -> None:
    """The documented convention (`pipeline/CLAUDE.md`): register the dash form
    AND the snake_case alias. A dash-only multi-word command breaks anyone who
    reached for the underscore, and the failure is a bare `unknown subcommand`."""
    missing: list[str] = []
    for name, module in TABLE.items():
        if "-" not in name:
            continue
        if TABLE.get(name.replace("-", "_")) != module:
            missing.append(name)
    assert not missing, f"multi-word commands missing their snake_case alias: {missing}"


def test_no_command_name_collides_with_a_flag() -> None:
    """A subcommand named `--foo` would be swallowed by the pre-dispatch help and
    version handling before the ladder ever sees it."""
    assert not [n for n in TABLE if n.startswith("-")]
    assert not (set(TABLE) & PRE_DISPATCH)


def test_usage_text_documents_every_command() -> None:
    """`mp --help` is the only discovery surface for a lazy router. A command
    absent from USAGE exists but cannot be found."""
    from mp.__main__ import USAGE

    undocumented = sorted(
        name for name in TABLE
        if "_" not in name and name not in USAGE
    )
    assert not undocumented, (
        f"these subcommands are registered but absent from USAGE: {undocumented}"
    )


def _run(argv: list[str], monkeypatch: pytest.MonkeyPatch) -> int:
    """`main()` is a console-script entry point: it takes no arguments and reads
    `sys.argv` itself, so driving it means setting argv."""
    from mp.__main__ import main

    monkeypatch.setattr("sys.argv", ["mp", *argv])
    return main()


def test_unknown_subcommand_exits_two_not_one(monkeypatch: pytest.MonkeyPatch) -> None:
    """Usage errors are exit 2, distinct from 1 (any other failure) and 3 (the
    publish-failed contract), so a caller can tell a typo from a real failure."""
    assert _run(["definitely-not-a-command"], monkeypatch) == 2


@pytest.mark.parametrize("argv", [["--help"], ["-h"], ["help"], []])
def test_help_paths_exit_zero(argv: list[str], monkeypatch: pytest.MonkeyPatch) -> None:
    assert _run(argv, monkeypatch) == 0


def test_version_flag_exits_zero(monkeypatch: pytest.MonkeyPatch) -> None:
    assert _run(["--version"], monkeypatch) == 0
