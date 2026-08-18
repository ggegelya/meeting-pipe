"""PIPE8: an entry-contract tripwire.

SEC13 requires every `mp` subcommand that can reach a sink, an engine, or a
token to arm the egress guard through `mp.entry.prepare` before it does anything
else. That was enforced by convention (a reviewer noticing). This test walks
every dispatch target in `__main__.py` and asserts the module either calls
`entry.prepare` or sits on a small named allowlist of read-only / diagnostic
commands, so the next forgotten arm is a red build instead of a silent leak.

**It reads the AST, not the module text (CI6).** The original walk was
`if "entry.prepare" not in src`, a raw substring test over the file: a mention in
a docstring, a comment, or a `# TODO: call entry.prepare` satisfied it, and it
said nothing at all about *when* the call ran, which is the entire contract
(`entry.py`: "before it does anything else", and arming after a client exists is
the leak the module was written to close). So the check is now two claims: a real
call node exists, and no gated call precedes it inside the function that makes
it. `test_local_client_contract.py` (LOCAL19) is the same shape one level down,
and was written against this strengthened form rather than the substring one.

The ordering half is deliberately vacuous against today's tree, because every
module is correct: the fifteen functions that call `prepare` construct no client
above it. That is what a tripwire looks like before it fires, and it is a
different thing from an assertion that *cannot* fire, which is what CI6 filed
against. `_entry_contract_violations` is therefore a pure function over source
text, and the tests below drive it against hand-written modules that get it
wrong, so the checker is proven to bite rather than asserted to.
"""
from __future__ import annotations

import ast
from pathlib import Path

SRC = Path(__file__).resolve().parents[1] / "src" / "mp"

# Dispatch targets that legitimately do NOT arm the guard, each with why it is
# exempt. None reaches a sink, an engine, or a cloud token through its normal
# path, so there is nothing for `entry.prepare` to clamp. Adding a command here
# is a deliberate, reviewable act; the default for a new subcommand is to arm.
ENTRY_CONTRACT_EXEMPT = {
    "logs_cmd": "reads the event-log JSONL; no config, no network",
    "prefetch_model": "deliberately unarmed: its whole job is to fetch a model over the network",
    "corrections": "aggregates the local correction corpus (read-only)",
    "analyze_detection": "audits the event stream (read-only)",
    "roster_cmd": "local voiceprint management; no sink, no engine",
    # `actions` was exempt until AI7: `--cluster` can load an embedding model, so
    # it is no longer a pure read of files on disk and now arms the guard.
    "prep": "recaps <stem>.meta.json + <stem>.summary.json already on disk; no sink, no engine",
    "doctor": "preflight diagnostic; loads secrets on purpose to test live API access",
}

#: The module `prepare` is imported from, so `from .entry import prepare` reads
#: as an arm too rather than as a missing one.
ENTRY_MODULE = "entry"

#: Loading the Keychain secrets is the third leg of the triple `prepare` owns,
#: so a call to it that is not `prepare`'s own is work the guard has to precede.
SECRET_LOADER = "load_secrets"

#: What "sink, engine or token work" looks like as a call node. The clients and
#: publishers are named by convention (`AnthropicSummaryClient`,
#: `LocalSummaryClient`, `NotionRestPublisher`, `httpx.Client`, ...), which is
#: exactly why `test_the_gate_predicate_still_names_the_real_client_surface`
#: pins that the convention still describes the real surface.
GATE_SUFFIXES = ("Client", "Publisher")

#: Client constructions the gate has to keep recognising. A rename that slips
#: past the naming convention above empties the ordering check silently, and the
#: check would then pass forever, so it is pinned rather than trusted.
KNOWN_GATED_CALLS = {
    "AnthropicSummaryClient",
    "LocalSummaryClient",
    "NotionRestPublisher",
    "load_secrets",
}


def _called_name(func: ast.expr) -> str | None:
    """The callee's name for a plain call or an attribute call, else None."""
    if isinstance(func, ast.Attribute):
        return func.attr
    if isinstance(func, ast.Name):
        return func.id
    return None


def _is_gated_call(node: ast.Call) -> bool:
    """True for a call that reaches a sink, an engine, or a token."""
    name = _called_name(node.func)
    if name is None:
        return False
    return name == SECRET_LOADER or name.endswith(GATE_SUFFIXES)


def _imports_prepare_directly(tree: ast.Module) -> bool:
    """True for `from .entry import prepare`, which makes a bare `prepare(...)`
    an arm rather than some unrelated local helper of the same name."""
    for node in ast.walk(tree):
        if (
            isinstance(node, ast.ImportFrom)
            and node.module == ENTRY_MODULE
            and any(alias.name == "prepare" for alias in node.names)
        ):
            return True
    return False


def _prepare_calls(tree: ast.Module) -> list[ast.Call]:
    """Every real `entry.prepare(...)` **call node**, never a mention of the name.

    A docstring, a comment or a string literal naming `entry.prepare` produces no
    `ast.Call`, which is the whole point of reading the tree instead of the text.
    """
    bare_is_an_arm = _imports_prepare_directly(tree)
    calls: list[ast.Call] = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        func = node.func
        if isinstance(func, ast.Attribute) and func.attr == "prepare":
            if isinstance(func.value, ast.Name) and func.value.id == ENTRY_MODULE:
                calls.append(node)
        elif bare_is_an_arm and isinstance(func, ast.Name) and func.id == "prepare":
            calls.append(node)
    return calls


def _enclosing_function(tree: ast.Module, call: ast.Call) -> ast.AST:
    """The innermost function containing `call`, falling back to the module."""
    best: ast.AST = tree
    best_line = -1
    for node in ast.walk(tree):
        if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        end = node.end_lineno or node.lineno
        if node.lineno <= call.lineno <= end and node.lineno > best_line:
            best, best_line = node, node.lineno
    return best


def _entry_contract_violations(source: str, label: str) -> list[str]:
    """Every way `source` breaks the SEC13 entry contract, as readable strings.

    Pure over the text so the tests below can drive it with modules written to
    fail, which is the only way to show the ordering half can fail at all.
    """
    tree = ast.parse(source)
    calls = _prepare_calls(tree)
    if not calls:
        return [f"{label}: no entry.prepare(...) call node"]

    first = min(calls, key=lambda c: c.lineno)
    scope = _enclosing_function(tree, first)
    early = sorted(
        (node.lineno, _called_name(node.func))
        for node in ast.walk(scope)
        if isinstance(node, ast.Call) and _is_gated_call(node) and node.lineno < first.lineno
    )
    return [
        f"{label}: {name}() at line {line} runs before entry.prepare(...) at line {first.lineno}"
        for line, name in early
    ]


def _dispatch_targets() -> set[str]:
    """Every module `__main__.main` dispatches to, read from the `from .<module>
    import main as run` lines so the set can never drift from the real router."""
    tree = ast.parse((SRC / "__main__.py").read_text(encoding="utf-8"))
    targets: set[str] = set()
    for node in ast.walk(tree):
        if (
            isinstance(node, ast.ImportFrom)
            and node.level == 1
            and node.module
            and any(alias.name == "main" for alias in node.names)
        ):
            targets.add(node.module)
    return targets


def test_dispatch_targets_are_discoverable():
    """Guard the guard: if the extraction finds nothing, the tripwire below is
    vacuously green and would never catch a real regression."""
    assert len(_dispatch_targets()) >= 15


def test_every_dispatch_target_arms_or_is_exempt():
    offenders: list[str] = []
    for module in sorted(_dispatch_targets()):
        if module in ENTRY_CONTRACT_EXEMPT:
            continue
        src = (SRC / f"{module}.py").read_text(encoding="utf-8")
        offenders += _entry_contract_violations(src, module)
    assert not offenders, (
        "these mp subcommands break the SEC13 entry contract (PIPE8), either by "
        "never calling entry.prepare or by doing sink / engine / token work "
        f"above it, and none is on ENTRY_CONTRACT_EXEMPT: {offenders}. Arm via "
        "mp.entry.prepare before any client is built, or, if the command truly "
        "reaches no sink / engine / token, add it to the allowlist with a "
        "one-line reason."
    )


def test_exempt_allowlist_has_no_stale_entries():
    """A renamed or removed command must not leave a stale allowlist entry that
    would silently exempt a future module reusing the name."""
    stale = set(ENTRY_CONTRACT_EXEMPT) - _dispatch_targets()
    assert not stale, f"ENTRY_CONTRACT_EXEMPT names non-dispatch modules: {sorted(stale)}"


# --------------------------------------------------------------------------
# The checker's own tests (CI6). Each drives `_entry_contract_violations` with a
# module written to be wrong in exactly one way, so both halves of the contract
# are shown failing rather than assumed to.
# --------------------------------------------------------------------------

_ARMED = '''
"""Calls entry.prepare like every armed subcommand does."""
from . import entry


def main(argv):
    cfg = entry.prepare(anchor=argv[0])
    return AnthropicSummaryClient(api_key="k").summarize(cfg)
'''

_MENTIONS_ONLY = '''
"""This module should call entry.prepare (SEC13) but does not.

    cfg = entry.prepare(anchor=argv[0])
"""
from . import entry  # noqa: F401


def main(argv):
    # TODO: entry.prepare(anchor=argv[0])
    return AnthropicSummaryClient(api_key="k").summarize(argv)
'''

_ARMS_TOO_LATE = '''
from . import entry


def main(argv):
    client = AnthropicSummaryClient(api_key="k")
    cfg = entry.prepare(anchor=argv[0])
    return client.summarize(cfg)
'''

_ARMS_BY_DIRECT_IMPORT = '''
from .entry import prepare


def main(argv):
    cfg = prepare(anchor=argv[0])
    return LocalSummaryClient(memory_floor_pct=cfg.floor)
'''


def test_a_correctly_armed_module_is_clean():
    """Guard the guard from the other side: a checker that flags everything
    would make every test below pass while telling nobody anything."""
    assert _entry_contract_violations(_ARMED, "armed") == []
    assert _entry_contract_violations(_ARMS_BY_DIRECT_IMPORT, "direct") == []


def test_a_mention_in_a_docstring_or_comment_does_not_satisfy_the_contract():
    """The defect CI6 filed: the old walk was `"entry.prepare" not in src`, so
    this module passed it while arming nothing."""
    assert "entry.prepare" in _MENTIONS_ONLY  # the substring test's whole basis
    violations = _entry_contract_violations(_MENTIONS_ONLY, "mentions")
    assert violations == ["mentions: no entry.prepare(...) call node"]


def test_arming_after_a_client_is_constructed_is_a_violation():
    """The ordering half. A late arm leaves the client built against an unclamped
    config, which is the leak `mp.entry` exists to close, and the substring test
    could not see it at all."""
    violations = _entry_contract_violations(_ARMS_TOO_LATE, "late")
    assert len(violations) == 1
    assert "AnthropicSummaryClient() at line 6 runs before entry.prepare(...) at line 7" in violations[0]


def test_the_gate_predicate_still_names_the_real_client_surface():
    """The ordering check reads "sink, engine or token" off a naming convention.
    If a rename walked out from under it, the check would pass forever without
    ever looking at anything, so pin that it still sees the real constructions."""
    seen: set[str] = set()
    for path in sorted(SRC.rglob("*.py")):
        tree = ast.parse(path.read_text(encoding="utf-8"))
        for node in ast.walk(tree):
            if isinstance(node, ast.Call) and _is_gated_call(node):
                name = _called_name(node.func)
                if name:
                    seen.add(name)
    missing = KNOWN_GATED_CALLS - seen
    assert not missing, (
        f"the entry-contract gate no longer recognises {sorted(missing)} as sink "
        "/ engine / token work. If one was renamed, update KNOWN_GATED_CALLS and "
        "check GATE_SUFFIXES still matches the new name; otherwise the ordering "
        "assertion above has quietly stopped checking anything."
    )
