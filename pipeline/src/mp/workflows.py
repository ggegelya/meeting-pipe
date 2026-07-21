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
from pathlib import Path

from .config import CONFIG_PATH

WORKFLOWS_DIR = CONFIG_PATH.parent / "workflows"


def _load_workflow_docs(directory: Path | None) -> list[dict]:
    """Parse every workflow TOML in `directory`, skipping unreadable / malformed
    ones (matching `WorkflowStore.load` on the Swift side: one bad file must not
    hide the others). Empty when the directory is absent.
    """
    directory = directory or WORKFLOWS_DIR
    if not directory.is_dir():
        return []
    docs: list[dict] = []
    for path in sorted(directory.glob("*.toml")):
        try:
            doc = tomllib.loads(path.read_text(encoding="utf-8"))
        except (OSError, tomllib.TOMLDecodeError, UnicodeDecodeError):
            continue
        # An empty or absent name falls back to the filename, matching the prior
        # per-caller `doc.get("name") or path.stem`, so callers read `doc["name"]`.
        doc["name"] = str(doc.get("name") or path.stem)
        docs.append(doc)
    return docs


def nda_workflow_names(directory: Path | None = None) -> list[str]:
    """Names of every workflow with `[flags] nda_mode = true`, sorted."""
    names = [
        doc["name"]
        for doc in _load_workflow_docs(directory)
        if isinstance(doc.get("flags"), dict) and doc["flags"].get("nda_mode") is True
    ]
    return sorted(names)


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
