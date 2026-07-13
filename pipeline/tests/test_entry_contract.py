"""PIPE8: an entry-contract tripwire.

SEC13 requires every `mp` subcommand that can reach a sink, an engine, or a
token to arm the egress guard through `mp.entry.prepare` before it does anything
else. That was enforced by convention (a reviewer noticing). This test walks
every dispatch target in `__main__.py` and asserts the module either calls
`entry.prepare` or sits on a small named allowlist of read-only / diagnostic
commands, so the next forgotten arm is a red build instead of a silent leak.
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
    "actions": "lists action items already extracted into <stem>.summary.json",
    "doctor": "preflight diagnostic; loads secrets on purpose to test live API access",
}


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
        if "entry.prepare" not in src:
            offenders.append(module)
    assert not offenders, (
        "these mp subcommands dispatch to a module that neither calls "
        f"entry.prepare (SEC13) nor sits on ENTRY_CONTRACT_EXEMPT: {offenders}. "
        "Arm via mp.entry.prepare, or, if the command truly reaches no sink / "
        "engine / token, add it to the allowlist with a one-line reason."
    )


def test_exempt_allowlist_has_no_stale_entries():
    """A renamed or removed command must not leave a stale allowlist entry that
    would silently exempt a future module reusing the name."""
    stale = set(ENTRY_CONTRACT_EXEMPT) - _dispatch_targets()
    assert not stale, f"ENTRY_CONTRACT_EXEMPT names non-dispatch modules: {sorted(stale)}"
