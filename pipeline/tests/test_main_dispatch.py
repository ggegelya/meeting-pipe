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
import os
import signal
import subprocess
import sys
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


# --- Ctrl-C (PIPE13) -------------------------------------------------------
#
# An unhandled `KeyboardInterrupt` used to reach the interpreter and print a
# six-frame traceback, which reads as a crash on a path AI11's walkthrough
# explicitly tells the owner to take. Interrupting is supported, so it exits
# 130 (128 + 2) with one line.


def _raise_interrupt(_argv: list[str]) -> int:
    raise KeyboardInterrupt


def test_interrupt_exits_130_with_one_line(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """`mp ask` is the reported case, and its line carries the resume clause:
    the index checkpoint survives, which is the non-obvious part."""
    monkeypatch.setattr("mp.ask.main", _raise_interrupt)

    rc = _run(["ask", "what did we decide"], monkeypatch)

    err = capsys.readouterr().err
    assert rc == 130
    assert err.splitlines() == [
        "mp ask: interrupted; the index keeps what it finished, "
        "so the next run resumes from there"
    ]
    assert "Traceback" not in err


def test_interrupt_is_caught_at_the_dispatch_level(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """Raised from a different subcommand, so the coverage above cannot be read
    as ask-specific: the handler sits at the router, not inside `mp ask`."""
    monkeypatch.setattr("mp.digest.main", _raise_interrupt)

    rc = _run(["digest"], monkeypatch)

    err = capsys.readouterr().err
    assert rc == 130
    assert err.splitlines() == ["mp digest: interrupted"]
    assert "Traceback" not in err


CHILD = """
import sys, time
import mp.logs_cmd

def blocking_main(argv):
    print("READY", flush=True)
    time.sleep(60)
    return 0

mp.logs_cmd.main = blocking_main
sys.argv = ["mp", "logs"]
from mp.__main__ import main
sys.exit(main())
"""


def test_real_sigint_prints_no_traceback() -> None:
    """The regression only exists at the interpreter's top level: an in-process
    call sees an exception, a real `mp` prints a stack trace. So drive a real
    subprocess and interrupt it for real."""
    proc = subprocess.Popen(
        [sys.executable, "-c", CHILD],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )
    try:
        assert proc.stdout is not None
        ready = proc.stdout.readline()
        assert ready.strip() == "READY", f"child never started: {proc.communicate()[1]}"

        proc.send_signal(signal.SIGINT)
        _out, err = proc.communicate(timeout=60)
    except BaseException:
        proc.kill()
        raise

    assert proc.returncode == 130
    assert "Traceback" not in err
    assert err.splitlines() == ["mp logs: interrupted"]


# --- SIGTERM (PIPE22) --------------------------------------------------------
#
# The daemon's Cancel and its watchdog both SIGTERM `mp`. Python's default
# disposition kills the interpreter without unwinding, so no `finally` ran and a
# local summary's setsid'd `mlx_lm.server` was orphaned. The router now turns it
# into `SystemExit(143)`, which runs every `finally` on the way out.

SIGTERM_CHILD = """
import os, sys, time
import mp.logs_cmd

def blocking_main(argv):
    try:
        print("READY", flush=True)
        time.sleep(60)
    finally:
        with open(os.environ["MP_TEST_SENTINEL"], "w") as f:
            f.write("finally ran")
    return 0

mp.logs_cmd.main = blocking_main
sys.argv = ["mp", "logs"]
from mp.__main__ import main
sys.exit(main())
"""


def _start_child(script: str, env: dict[str, str] | None = None) -> subprocess.Popen[str]:
    """Run `script` as a real `mp`-shaped interpreter and wait for its READY.

    Real processes, because the defect only exists at the interpreter's top
    level: in-process, a signal handler is just a function. `env` is overlaid on
    this process's environment (PIPE37's `MP_SUPERVISED` rides in here), and
    stdin is a pipe the caller may close."""
    proc = subprocess.Popen(
        [sys.executable, "-c", script],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        env={**os.environ, **(env or {})},
    )
    assert proc.stdout is not None
    ready = proc.stdout.readline()
    if ready.strip() != "READY":
        proc.kill()
        raise AssertionError(f"child never started: {proc.communicate()[1]}")
    return proc


def test_sigterm_runs_every_finally_and_exits_143(tmp_path: Path) -> None:
    sentinel = tmp_path / "finally.txt"
    proc = _start_child(SIGTERM_CHILD, {"MP_TEST_SENTINEL": str(sentinel)})
    try:
        proc.send_signal(signal.SIGTERM)
        _out, err = proc.communicate(timeout=30)
    except BaseException:
        proc.kill()
        raise

    assert sentinel.read_text(encoding="utf-8") == "finally ran"
    assert proc.returncode == 143  # not -15: the interpreter unwound, it was not killed
    assert err.splitlines() == ["mp logs: terminated"]


SIGTERM_TWICE_CHILD = """
import os, sys, time
import mp.logs_cmd

def blocking_main(argv):
    try:
        print("READY", flush=True)
        time.sleep(60)
    finally:
        # A cleanup that takes a while, like `close()` waiting on a model
        # server. The second SIGTERM lands in here.
        print("CLEANING", flush=True)
        time.sleep(1.0)
        with open(os.environ["MP_TEST_SENTINEL"], "w") as f:
            f.write("cleanup finished")
    return 0

mp.logs_cmd.main = blocking_main
sys.argv = ["mp", "logs"]
from mp.__main__ import main
sys.exit(main())
"""


def test_a_second_sigterm_does_not_abort_the_cleanup(tmp_path: Path) -> None:
    """One-shot: the daemon's Cancel and PIPE37's stdin-EOF self-signal can both
    arrive, and a second `SystemExit` raised inside a `finally` would abandon the
    cleanup the first one started (a model server half-way through its kill)."""
    sentinel = tmp_path / "finally.txt"
    proc = _start_child(SIGTERM_TWICE_CHILD, {"MP_TEST_SENTINEL": str(sentinel)})
    try:
        assert proc.stdout is not None
        proc.send_signal(signal.SIGTERM)
        assert proc.stdout.readline().strip() == "CLEANING"
        proc.send_signal(signal.SIGTERM)
        _out, err = proc.communicate(timeout=30)
    except BaseException:
        proc.kill()
        raise

    assert sentinel.read_text(encoding="utf-8") == "cleanup finished"
    assert proc.returncode == 143
    assert "Traceback" not in err


def test_the_handler_leaves_other_system_exits_alone(monkeypatch: pytest.MonkeyPatch) -> None:
    """argparse exits through `SystemExit(2)`; only 143 is the router's to name."""
    def _usage_error(_argv: list[str]) -> int:
        raise SystemExit(2)

    monkeypatch.setattr("mp.digest.main", _usage_error)
    with pytest.raises(SystemExit) as exc:
        _run(["digest"], monkeypatch)
    assert exc.value.code == 2


# --- stdin-EOF supervision (PIPE37) ------------------------------------------
#
# The daemon's SIGTERM on Quit only covers an orderly exit. For a crash, a
# SIGKILL or the termination ceiling's `exit`, a supervised `mp` gets a stdin
# pipe whose only write end the daemon holds, plus `MP_SUPERVISED=1`; EOF on it
# means the daemon is gone, and `mp` SIGTERMs itself into PIPE22's unwind.

SUPERVISED = {"MP_SUPERVISED": "1"}


def _close_stdin(proc: subprocess.Popen[str]) -> None:
    """Close our write end the way the kernel does when the daemon dies.
    `communicate()` would try to flush a closed handle, so forget it too."""
    assert proc.stdin is not None
    proc.stdin.close()
    proc.stdin = None


def test_a_supervised_run_unwinds_when_its_stdin_closes(tmp_path: Path) -> None:
    sentinel = tmp_path / "finally.txt"
    proc = _start_child(SIGTERM_CHILD, {"MP_TEST_SENTINEL": str(sentinel), **SUPERVISED})
    try:
        _close_stdin(proc)
        _out, err = proc.communicate(timeout=10)
    except BaseException:
        proc.kill()
        raise

    assert sentinel.read_text(encoding="utf-8") == "finally ran"
    assert proc.returncode == 143
    assert err.splitlines() == ["mp logs: terminated"]


def test_an_unsupervised_run_ignores_its_stdin_closing(tmp_path: Path) -> None:
    """Without the variable nothing watches stdin: a manual `mp` run, or a spawn
    the daemon deliberately leaves to finish (a backup, a restore)."""
    sentinel = tmp_path / "finally.txt"
    proc = _start_child(SIGTERM_CHILD, {"MP_TEST_SENTINEL": str(sentinel), "MP_SUPERVISED": ""})
    try:
        _close_stdin(proc)
        with pytest.raises(subprocess.TimeoutExpired):
            proc.wait(timeout=1.5)
        assert not sentinel.exists()
    finally:
        proc.kill()
        proc.communicate()


def test_a_supervised_run_survives_the_loss_of_all_three_pipes(tmp_path: Path) -> None:
    """A dead daemon takes stdout and stderr with stdin, so the unwind's own
    stderr line has no reader. The cleanup must still run, and promptly."""
    sentinel = tmp_path / "finally.txt"
    proc = _start_child(SIGTERM_CHILD, {"MP_TEST_SENTINEL": str(sentinel), **SUPERVISED})
    try:
        assert proc.stdout is not None and proc.stderr is not None
        proc.stdout.close()
        proc.stderr.close()
        _close_stdin(proc)
        proc.wait(timeout=10)
    except BaseException:
        proc.kill()
        raise

    assert sentinel.read_text(encoding="utf-8") == "finally ran"
    # 120 is CPython failing to flush stderr at interpreter exit, which is what a
    # reader-less pipe does; nobody is left to read the code either way. What
    # matters is that it unwound rather than being killed (a negative code).
    assert proc.returncode in (143, 120)


SUPERVISED_RETURNS_CHILD = """
import os, sys
import mp.logs_cmd

def quick_main(argv):
    print("READY", flush=True)
    with open(os.environ["MP_TEST_SENTINEL"], "w") as f:
        f.write(repr(os.environ.get("MP_SUPERVISED")))
    return 0

mp.logs_cmd.main = quick_main
sys.argv = ["mp", "logs"]
from mp.__main__ import main
sys.exit(main())
"""


def test_a_supervised_run_that_finishes_exits_cleanly(tmp_path: Path) -> None:
    """Every normal supervised run: stdin stays open, the command returns, and
    the parked watcher thread neither delays the exit nor says anything. The
    variable is consumed, so nothing the run spawns inherits it (a descendant
    on a `/dev/null` stdin would read EOF and stop itself)."""
    sentinel = tmp_path / "env.txt"
    proc = _start_child(
        SUPERVISED_RETURNS_CHILD, {"MP_TEST_SENTINEL": str(sentinel), **SUPERVISED}
    )
    try:
        # Not `communicate()`: it closes stdin first, which is the EOF under test.
        proc.wait(timeout=10)
        assert proc.stderr is not None
        err = proc.stderr.read()
    except BaseException:
        proc.kill()
        raise
    finally:
        _close_stdin(proc)

    assert proc.returncode == 0
    assert err == ""
    assert sentinel.read_text(encoding="utf-8") == "None"
