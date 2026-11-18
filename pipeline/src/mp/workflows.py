"""Read the workflow TOMLs the daemon owns.

The pipeline normally learns about a workflow through `<stem>.meta.json`, which
carries the one workflow that recorded the meeting. `mp doctor` needs a different
question answered: *does any* NDA workflow exist on this Mac? That decides whether
a cloud-synced library is a warning or a failure (SEC12), and it cannot be
answered from a per-meeting sidecar.

Read-only. The daemon is the sole writer.
"""
from __future__ import annotations

import tomllib
import uuid
from pathlib import Path

from .config import CONFIG_PATH

WORKFLOWS_DIR = CONFIG_PATH.parent / "workflows"


# Every `WorkflowBackend` raw value on the Swift side (`Workflow.swift`).
KNOWN_BACKENDS = frozenset({"anthropic", "local", "auto", "apple_intelligence", "claude_cli", "openai"})


def _is_uuid(value: str) -> bool:
    try:
        uuid.UUID(value)
    except ValueError:
        return False
    return True


def strict_problem(doc: dict, path: Path) -> str | None:
    """The reason a parsed workflow file is refused, or None (SEC21 item 6).

    The same rule as Swift's `WorkflowStore.decode`: a present `nda_mode` that is not
    a TOML bool, a present `backend` that is not a known backend, or an `id` that is
    invalid, or missing while the file name is not itself a UUID. Only a present,
    wrong value is refused; a file with no `[flags]` and no `backend` still loads.
    """
    flags = doc.get("flags")
    if isinstance(flags, dict) and "nda_mode" in flags and not isinstance(flags["nda_mode"], bool):
        return "nda_mode is not true or false"
    if "backend" in doc and doc["backend"] not in KNOWN_BACKENDS:
        return f"backend {doc['backend']!r} is not a known backend"
    if "id" in doc:
        if not isinstance(doc["id"], str) or not _is_uuid(doc["id"]):
            return "id is not a valid UUID"
    elif not _is_uuid(path.stem):
        return "id is missing and the file name is not a UUID"
    return None


def load_workflows(directory: Path | None = None) -> tuple[list[dict], list[tuple[str, str]]]:
    """Every workflow TOML in `directory`: the docs that load, and the (file name,
    reason) of each that does not, by the daemon's own rule (SEC21 items 5 to 7).

    A broken file is reported rather than skipped in silence: the daemon refuses it
    too, so its rules (perhaps an NDA workflow's) are not applied. Empty when the
    directory is absent.
    """
    directory = directory or WORKFLOWS_DIR
    if not directory.is_dir():
        return [], []
    docs: list[dict] = []
    broken: list[tuple[str, str]] = []
    for path in sorted(directory.glob("*.toml")):
        try:
            doc = tomllib.loads(path.read_text(encoding="utf-8"))
        except (OSError, tomllib.TOMLDecodeError, UnicodeDecodeError) as exc:
            broken.append((path.name, type(exc).__name__))
            continue
        problem = strict_problem(doc, path)
        if problem is not None:
            broken.append((path.name, problem))
            continue
        # An empty or absent name falls back to the filename, matching the prior
        # per-caller `doc.get("name") or path.stem`, so callers read `doc["name"]`.
        doc["name"] = str(doc.get("name") or path.stem)
        # Likewise the id: `strict_problem` already required the file name to be the UUID
        # when the key is absent, so this is always a UUID string (WF11 reads it).
        doc["id"] = str(doc.get("id") or path.stem)
        docs.append(doc)
    return docs, broken


def broken_workflow_files(directory: Path | None = None) -> list[tuple[str, str]]:
    """The workflow files the daemon refuses, as (file name, reason) (SEC21 item 7)."""
    return load_workflows(directory)[1]


def _load_workflow_docs(directory: Path | None) -> list[dict]:
    """The workflow docs that load (one bad file must not hide the others, matching
    `WorkflowStore.load`). Broken ones are `broken_workflow_files`' to report."""
    return load_workflows(directory)[0]


def workflow_name_for_id(workflow_id: object, directory: Path | None = None) -> str | None:
    """The current name of the workflow whose id is ``workflow_id``, or None when it
    is absent, not a string, or names no workflow on this Mac (WF11).

    A meeting's `<stem>.meta.json` records both the workflow's id and the name it had
    at recording time. Renaming a workflow changes only the name, so a lookup keyed
    on the recorded name stops finding things a rename moved (its glossary table).
    The id is compared case-insensitively, as Swift's `PrepCardStore.matches` does.
    Callers fall back to the recorded name on None, which keeps a library moved to a
    Mac whose workflows carry other ids working (TECH-B4).
    """
    if not isinstance(workflow_id, str) or not workflow_id.strip():
        return None
    wanted = workflow_id.strip().lower()
    for doc in _load_workflow_docs(directory):
        if doc["id"].lower() == wanted:
            return doc["name"]
    return None


def nda_workflow_names(directory: Path | None = None) -> list[str]:
    """Names of every workflow with `[flags] nda_mode = true`, sorted."""
    names = [
        doc["name"]
        for doc in _load_workflow_docs(directory)
        if isinstance(doc.get("flags"), dict) and doc["flags"].get("nda_mode") is True
    ]
    return sorted(names)


def sink_types_in_use(directory: Path | None = None) -> set[str]:
    """Every sink type any workflow lists (`[[sinks]]` tables with a `type` key, as the
    daemon's `WorkflowStore` writes them), across all workflow TOMLs (SEC35).

    `mp doctor` asks this because a workflow can publish to the filesystem, the vault
    or the LAN share while the global `output.sinks` says `notion`: the per-meeting
    overlay replaces the global list, so the global one is not the whole answer.
    Malformed files and entries without a string `type` are skipped, like the rest.
    """
    types: set[str] = set()
    for doc in _load_workflow_docs(directory):
        sinks = doc.get("sinks")
        if not isinstance(sinks, list):
            continue
        for entry in sinks:
            kind = entry.get("type") if isinstance(entry, dict) else None
            if isinstance(kind, str) and kind:
                types.add(kind)
    return types


def local_backend_workflow_names(directory: Path | None = None) -> list[str]:
    """Names of every workflow that forces on-device summarization, sorted: an
    explicit `backend = "local"` pin, or `[flags] nda_mode = true` (NDA forces
    local regardless of the pin, mirroring Swift's `Workflow.effectiveBackend`).

    `mp doctor`'s local-stack check needs this (UX21): the on-device stack is used
    the moment any workflow resolves to local, not only when the global backend
    does, so the check must not skip on a global anthropic backend when a
    local / NDA workflow exists.
    """
    names: list[str] = []
    for doc in _load_workflow_docs(directory):
        flags = doc.get("flags")
        is_nda = isinstance(flags, dict) and flags.get("nda_mode") is True
        is_local = doc.get("backend") == "local"
        if is_nda or is_local:
            names.append(doc["name"])
    return sorted(names)
