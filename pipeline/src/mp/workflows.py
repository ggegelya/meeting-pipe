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


def nda_workflow_names(directory: Path | None = None) -> list[str]:
    """Names of every workflow with `[flags] nda_mode = true`, sorted.

    A malformed or unreadable TOML is skipped rather than raised on, matching
    `WorkflowStore.load`'s behaviour on the Swift side: one bad file must not hide
    the others.
    """
    directory = directory or WORKFLOWS_DIR
    if not directory.is_dir():
        return []
    names: list[str] = []
    for path in sorted(directory.glob("*.toml")):
        try:
            doc = tomllib.loads(path.read_text(encoding="utf-8"))
        except (OSError, tomllib.TOMLDecodeError, UnicodeDecodeError):
            continue
        flags = doc.get("flags")
        if isinstance(flags, dict) and flags.get("nda_mode") is True:
            names.append(str(doc.get("name") or path.stem))
    return sorted(names)
