"""PIPE32 (was LOCAL19): no `LocalSummaryClient` is built by hand outside its module.

`LocalSummaryClient.__init__` defaults every parameter, so a construction that
forgets one does not fail, it silently runs on the constant. That happened three
times: PIPE12 (`engine._local_client` dropped the adapter), LOCAL19
(`AutoFallbackClient._local` dropped `local_memory_floor_pct`, so `auto` ignored
the free-RAM floor), and `providers._local_cleanup` ran on the 120 s timeouts
whatever the config said. LOCAL19's fence checked one keyword of nine.

`LocalSummaryClient.from_config(cfg, **overrides)` threads every config-backed
parameter in one place. This walks every call under `src/mp` and asserts that no
module but `summarize_local` constructs the class directly, and that no
`from_config` call overrides `memory_floor_pct` (re-pinning the floor at a site
the user's config cannot reach is the LOCAL19 defect one step further along). It
reads the AST rather than grepping module text, so a mention in a comment or a
docstring cannot satisfy or trip it.
"""
from __future__ import annotations

import ast
from pathlib import Path

SRC = Path(__file__).resolve().parents[1] / "src" / "mp"

CLIENT = "LocalSummaryClient"
FACTORY = "from_config"
#: The one module allowed to call the constructor (the factory lives there).
HOME = "summarize_local"
FLOOR_KWARG = "memory_floor_pct"

#: Modules that build the client today. Named so a construction moving out of
#: one is a deliberate edit here rather than a silently narrower walk.
KNOWN_BUILDERS = {"summarize", "engine", "providers", "dogfood"}


def _calls(tree: ast.AST) -> list[tuple[str, ast.Call]]:
    """(`"direct"` | `"factory"`, call) for every construction in `tree`."""
    found: list[tuple[str, ast.Call]] = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        func = node.func
        if isinstance(func, ast.Name) and func.id == CLIENT:
            found.append(("direct", node))
        elif isinstance(func, ast.Attribute) and func.attr == CLIENT:
            found.append(("direct", node))
        elif (isinstance(func, ast.Attribute) and func.attr == FACTORY
              and isinstance(func.value, (ast.Name, ast.Attribute))
              and (getattr(func.value, "id", None) == CLIENT
                   or getattr(func.value, "attr", None) == CLIENT)):
            found.append(("factory", node))
    return found


def _constructions() -> list[tuple[str, int, str, ast.Call]]:
    out: list[tuple[str, int, str, ast.Call]] = []
    for path in sorted(SRC.rglob("*.py")):
        for kind, call in _calls(ast.parse(path.read_text(encoding="utf-8"))):
            out.append((path.stem, call.lineno, kind, call))
    return out


def _direct_offenders(found: list[tuple[str, int, str, ast.Call]]) -> list[str]:
    return [f"{m}.py:{line}" for m, line, kind, _ in found if kind == "direct" and m != HOME]


def _floor_overrides(found: list[tuple[str, int, str, ast.Call]]) -> list[str]:
    return [
        f"{m}.py:{line}" for m, line, kind, call in found
        if kind == "factory" and any(k.arg == FLOOR_KWARG for k in call.keywords)
    ]


def test_the_walk_finds_every_known_builder() -> None:
    """Guard the guard. If the extraction found nothing (a rename, a moved
    import), the tripwires below would be vacuously green forever."""
    modules = {m for m, _, kind, _ in _constructions() if kind == "factory"}
    assert KNOWN_BUILDERS <= modules, (
        f"the {CLIENT}.{FACTORY} walk no longer sees {sorted(KNOWN_BUILDERS - modules)}. "
        "If a construction legitimately moved, update KNOWN_BUILDERS; if the class "
        "or the factory was renamed, update CLIENT or FACTORY."
    )


def test_no_direct_construction_outside_its_module() -> None:
    offenders = _direct_offenders(_constructions())
    assert not offenders, (
        f"these build {CLIENT}(...) directly: {offenders}. Use "
        f"{CLIENT}.{FACTORY}(cfg, **overrides), which threads every config-backed "
        "parameter; a hand-built client silently runs on the constructor's defaults "
        "for whatever it forgets (PIPE12, LOCAL19, PIPE32)."
    )


def test_no_factory_call_overrides_the_memory_floor() -> None:
    offenders = _floor_overrides(_constructions())
    assert not offenders, (
        f"these override {FLOOR_KWARG}: {offenders}. The free-RAM floor is the "
        "configured one on every local path, so raising it or setting 0 means the "
        "same everywhere (LOCAL16, LOCAL19)."
    )


def test_the_tripwires_fire_on_planted_offenders() -> None:
    """The planted cases the acceptance asks for, kept as a test rather than tried
    once and reverted, so the fence cannot quietly stop detecting them."""
    planted = ast.parse(
        "a = LocalSummaryClient(model='x')\n"
        "b = sl.LocalSummaryClient()\n"
        "c = LocalSummaryClient.from_config(cfg, memory_floor_pct=0.0)\n"
        "d = LocalSummaryClient.from_config(cfg, model='y')\n"
    )
    found = [("planted", call.lineno, kind, call) for kind, call in _calls(planted)]
    assert _direct_offenders(found) == ["planted.py:1", "planted.py:2"]
    assert _floor_overrides(found) == ["planted.py:3"]
