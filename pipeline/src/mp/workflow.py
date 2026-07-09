"""Per-meeting workflow overlay.

The daemon resolves a workflow at the start of every recording (TECH-B3)
and writes the relevant overrides into the meeting's `<stem>.meta.json`
sidecar (TECH-B4). This module reads that sidecar and returns a `Config`
that already has the workflow's `team_context`, `backend`, `sinks`, and
optional NDA flag applied — the rest of the pipeline never has to know
that workflows exist.

The contract is one-way: the daemon produces a sidecar, the pipeline
consumes it. There is no Python-side workflow CRUD; the daemon owns the
TOML files under `~/.config/meeting-pipe/workflows/`.

Failure mode: a missing or malformed sidecar yields the unmodified
config. We deliberately don't raise on bad JSON — the pipeline must
still produce a summary when the daemon never wrote a sidecar (manual
`mp run-all` invocations from a shell).
"""
from __future__ import annotations

import json
import logging
from pathlib import Path
from typing import Any

from .config import Config, zero_egress

log = logging.getLogger("mp.workflow")


def apply_overrides(cfg: Config, any_meeting_path: Path) -> Config:
    """Read the meeting's meta sidecar (sibling of the wav/transcript/
    summary at the same meeting stem) and return a Config with the
    workflow's overrides applied. Pure: never mutates the input cfg.

    `any_meeting_path` may be any file belonging to the meeting
    (`<stem>.wav`, `<stem>.md`, `<stem>.summary.json`, etc.). The stem is
    the substring before the first dot in the filename, mirroring the
    daemon's `MeetingStore.stem(of:)` rule.

    Overrides understood:
      - `workflow_context_prompt`  → `summarization.team_context`
      - `workflow_backend`         → `summarization.backend` (applied only when
        present; the daemon omits it when the workflow inherits the global
        default, so a global `apple_intelligence` setting stays in effect)
      - `workflow_sinks`           → `output.sinks`
      - `workflow_notion_database_id` → `notion.database_id`
      - `workflow_nda_mode`        → forces local backend + filesystem sink
      - `regulated_mode`           → global zero-egress at record time (TECH-DSN6);
        folded in fail-closed, same effect as `workflow_nda_mode`
    """
    meta = _read_meta(any_meeting_path)
    if not meta:
        return cfg

    # `model_copy(deep=True)` so nested pydantic models clone cleanly
    # and the original cfg stays untouched.
    overlay = cfg.model_copy(deep=True)
    changed: list[str] = []

    nda_mode = bool(meta.get("workflow_nda_mode"))
    # Carry the resolved NDA flag on the config so the egress guard can arm on
    # it at entry without re-reading the sidecar (TECH-SEC3).
    overlay.modes.workflow_nda_mode = nda_mode

    # TECH-DSN6: a meeting recorded under global regulated mode persists
    # `regulated_mode` in the sidecar. Fold it in fail-closed, so a reprocess
    # (and the Library badge, which reads the same flag) stays zero-egress even
    # if the global config flag has since been turned off.
    if bool(meta.get("regulated_mode")) and not overlay.modes.regulated_mode:
        overlay.modes.regulated_mode = True
        changed.append("regulated_mode (from sidecar)")
    clamped = zero_egress(overlay)

    backend_raw = meta.get("workflow_backend")
    if isinstance(backend_raw, str) and backend_raw in {"anthropic", "local", "auto", "apple_intelligence"}:
        if overlay.summarization.backend != backend_raw:
            overlay.summarization.backend = backend_raw  # type: ignore[assignment]
            changed.append(f"backend={backend_raw}")

    ctx = meta.get("workflow_context_prompt")
    if isinstance(ctx, str):
        if overlay.summarization.team_context != ctx:
            overlay.summarization.team_context = ctx
            changed.append("team_context")

    sinks = meta.get("workflow_sinks")
    if isinstance(sinks, list) and sinks:
        clean = [s for s in sinks if isinstance(s, str) and s]
        if clean and overlay.output.sinks != clean:
            overlay.output.sinks = clean
            changed.append(f"sinks={','.join(clean)}")

    notion_db = meta.get("workflow_notion_database_id")
    if isinstance(notion_db, str) and notion_db:
        if overlay.notion.database_id != notion_db:
            overlay.notion.database_id = notion_db
            changed.append("notion.database_id")

    # Zero-egress (NDA or regulated) is a belt-and-braces enforcement: even if
    # the daemon-supplied backend/sinks already reflect it (they should, via
    # `effectiveBackend` / effective_sinks), we re-apply here so a misconfigured
    # workflow (NDA + backend=anthropic somewhere upstream) still keeps the
    # meeting on-device.
    if clamped:
        if overlay.summarization.backend != "local":
            overlay.summarization.backend = "local"  # type: ignore[assignment]
            changed.append("zero_egress→backend=local")
        if overlay.output.sinks != ["filesystem"]:
            overlay.output.sinks = ["filesystem"]
            changed.append("zero_egress→sinks=filesystem")

    if changed:
        wf_name = meta.get("workflow_name") or "(unnamed)"
        log.info("Workflow overlay applied (%s): %s", wf_name, ", ".join(changed))
    return overlay


def _read_meta(any_meeting_path: Path) -> dict[str, Any]:
    # Mirror the daemon's `MeetingStore.stem(of:)` rule: stem is the
    # filename substring before the first dot. Lets a single function
    # handle every per-meeting filename (`.wav`, `.md`, `.summary.json`,
    # `.READY_FOR_MANUAL.md`, …).
    name = any_meeting_path.name
    stem = name.split(".", 1)[0]
    sidecar = any_meeting_path.parent / f"{stem}.meta.json"
    if not sidecar.exists():
        return {}
    try:
        return json.loads(sidecar.read_text(encoding="utf-8"))
    except Exception as e:  # noqa: BLE001
        log.warning("Workflow meta sidecar at %s is malformed: %s", sidecar, e)
        return {}
