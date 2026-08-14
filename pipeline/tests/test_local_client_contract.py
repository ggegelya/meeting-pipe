"""LOCAL19: a memory-floor tripwire over every `LocalSummaryClient` construction.

`summarization.local_memory_floor_pct` is the free-RAM floor a local run aborts
under (LOCAL16), and `LocalSummaryClient.__init__` defaults it to
`resource_guard.DEFAULT_FLOOR_PCT`. So a construction that forgets the keyword
does not fail, it silently runs at 10.0. `_AutoFallbackClient._local` did exactly
that, which meant the whole `auto` backend ignored a floor `diarize_cleanup`
documents as universal ("means the same thing on every local path") and that both
`README.md` and `config.example.toml` promise `0` turns off.

Nothing else could see it. CI5's dead-knob fence compares the config models
against the docs, and the key is genuinely read at four other sites, so a fence
built on set comparison is structurally blind to one site out of five.

This walks every `LocalSummaryClient(...)` call under `src/mp` and asserts each
one passes the configured floor, so a fifth construction cannot forget either.
It reads the call out of the AST rather than grepping module text, so a mention
in a comment or a docstring cannot satisfy it; `test_entry_contract.py`'s own
walk is a substring test and CI6 covers strengthening that one.
"""
from __future__ import annotations

import ast
from pathlib import Path

SRC = Path(__file__).resolve().parents[1] / "src" / "mp"

CLIENT = "LocalSummaryClient"
#: The constructor keyword, and the config field its value has to come from.
FLOOR_KWARG = "memory_floor_pct"
CONFIGURED_FLOOR = "local_memory_floor_pct"

#: Modules that build the client today. Named so a construction moving out of
#: one is a deliberate edit here rather than a silently narrower walk.
KNOWN_CONSTRUCTORS = {"summarize", "engine", "diarize_cleanup", "dogfood"}


def _called_name(func: ast.expr) -> str | None:
    """The callee's name for a plain call or an attribute call, else None."""
    if isinstance(func, ast.Name):
        return func.id
    if isinstance(func, ast.Attribute):
        return func.attr
    return None


def _client_constructions() -> list[tuple[str, int, ast.Call]]:
    """Every `LocalSummaryClient(...)` call under `src/mp`, as (module, line, call)."""
    found: list[tuple[str, int, ast.Call]] = []
    for path in sorted(SRC.rglob("*.py")):
        tree = ast.parse(path.read_text(encoding="utf-8"))
        for node in ast.walk(tree):
            if isinstance(node, ast.Call) and _called_name(node.func) == CLIENT:
                found.append((path.stem, node.lineno, node))
    return found


def _threads_configured_floor(call: ast.Call) -> bool:
    """True when the call passes `memory_floor_pct=<...>.local_memory_floor_pct`.

    The value has to be the config attribute, not just any expression: a literal
    would re-pin the floor at a site the user's config cannot reach, which is the
    same defect one step further along.
    """
    for keyword in call.keywords:
        if keyword.arg != FLOOR_KWARG:
            continue
        return isinstance(keyword.value, ast.Attribute) and keyword.value.attr == CONFIGURED_FLOOR
    return False


def test_the_walk_finds_every_known_constructor() -> None:
    """Guard the guard. If the extraction found nothing (a rename, a moved
    import), the tripwire below would be vacuously green forever."""
    modules = {module for module, _, _ in _client_constructions()}
    assert KNOWN_CONSTRUCTORS <= modules, (
        f"the {CLIENT} walk no longer sees {sorted(KNOWN_CONSTRUCTORS - modules)}. "
        "If a construction legitimately moved, update KNOWN_CONSTRUCTORS; if the "
        "class was renamed, update CLIENT, or this tripwire stops checking anything."
    )


def test_every_local_client_construction_threads_the_configured_floor() -> None:
    offenders = [
        f"{module}.py:{lineno}"
        for module, lineno, call in _client_constructions()
        if not _threads_configured_floor(call)
    ]
    assert not offenders, (
        f"these {CLIENT} constructions do not pass "
        f"{FLOOR_KWARG}=<cfg>.summarization.{CONFIGURED_FLOOR}: {offenders}. "
        "Without it the free-RAM watchdog runs at resource_guard.DEFAULT_FLOOR_PCT "
        "on that path, so raising the floor does nothing there and setting it to 0 "
        "does not turn the watchdog off, both of which the docs promise it does "
        "(LOCAL19)."
    )
