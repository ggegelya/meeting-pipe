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

Reading the sidecar has three outcomes (SEC25), and only one of them is
"no workflow":

  - absent: the daemon never wrote one (a manual `mp run-all` from a shell,
    a workflow-less non-regulated recording). The global config applies.
  - ok: the overlay below.
  - unreadable: it exists but could not be read (an I/O error, such as the
    EDEADLK a dataless iCloud file returned on 2026-10-16) or parsed. The
    meeting's NDA posture lives only in this file, so the overlay fails
    closed: the run goes on-device exactly as a `workflow_nda_mode` meeting
    would. Reading it as absent is what used to send such a meeting to cloud.

`read_meta` keeps its old dict-or-empty shape for the informational callers
(actions, mcp_tools, glossary, the AI6 sibling scan, visibility, which
already withholds a meeting it cannot read).
"""
from __future__ import annotations

import errno as errno_mod
import json
import logging
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Literal

from . import events
from .config import BACKENDS, Config, ExtraSectionSpec, zero_egress

log = logging.getLogger("mp.workflow")


@dataclass(frozen=True)
class MetaRead:
    """One read of `<stem>.meta.json` (SEC25). `state` is the outcome; `data` is
    the parsed object only for `ok`; `kind` and `errno` (the symbolic name, e.g.
    `EDEADLK`) only for `unreadable`."""

    sidecar: Path
    state: Literal["absent", "ok", "unreadable"]
    data: dict[str, Any] = field(default_factory=dict)
    kind: Literal["io", "parse"] | None = None
    errno: str | None = None
    reason: str = ""


def _sidecar_path(any_meeting_path: Path) -> Path:
    # Mirror the daemon's `MeetingStore.stem(of:)` rule: stem is the
    # filename substring before the first dot. Lets a single function
    # handle every per-meeting filename (`.wav`, `.md`, `.summary.json`,
    # `.READY_FOR_MANUAL.md`, …).
    stem = any_meeting_path.name.split(".", 1)[0]
    return any_meeting_path.parent / f"{stem}.meta.json"


def load_meta(any_meeting_path: Path) -> MetaRead:
    """Read the meeting's sidecar into one of three outcomes. Never raises.

    Only a missing file is `absent`; every other `OSError` (EDEADLK, EISDIR,
    EACCES, ...) is `unreadable` with `kind="io"`, and bytes that are not a
    JSON object are `unreadable` with `kind="parse"`.
    """
    sidecar = _sidecar_path(any_meeting_path)
    try:
        raw = sidecar.read_bytes()
    except FileNotFoundError:
        return MetaRead(sidecar, "absent")
    except OSError as e:
        name = errno_mod.errorcode.get(e.errno, str(e.errno)) if e.errno is not None else None
        return MetaRead(sidecar, "unreadable", kind="io", errno=name, reason=str(e))
    try:
        obj = json.loads(raw.decode("utf-8"))
    except ValueError as e:  # JSONDecodeError and UnicodeDecodeError both derive from it
        return MetaRead(sidecar, "unreadable", kind="parse", reason=str(e))
    if not isinstance(obj, dict):
        return MetaRead(
            sidecar, "unreadable", kind="parse", reason=f"top level is {type(obj).__name__}, not an object"
        )
    return MetaRead(sidecar, "ok", data=obj)


def _describe_unreadable(read: MetaRead) -> str:
    if read.kind == "io":
        return f"Workflow meta sidecar at {read.sidecar} could not be read ({read.errno}: {read.reason})"
    return f"Workflow meta sidecar at {read.sidecar} is malformed ({read.reason})"


# Sidecars already reported as unreadable in this process. `run-all` prepares and
# then hands its config to `summarize`, which prepares again, so without this one
# meeting would write two event rows for one run.
_reported_unreadable: set[Path] = set()


def _fail_closed(cfg: Config, read: MetaRead) -> Config:
    """SEC25: the overlay for a sidecar that exists but could not be read. Same
    effect as `workflow_nda_mode`: local backend, filesystem sink, and the egress
    guard arms through `zero_egress` at entry."""
    overlay = cfg.model_copy(deep=True)
    overlay.modes.workflow_nda_mode = True
    overlay.summarization.backend = "local"  # type: ignore[assignment]
    overlay.output.sinks = ["filesystem"]
    if read.sidecar not in _reported_unreadable:
        _reported_unreadable.add(read.sidecar)
        log.warning("%s; running this meeting on-device", _describe_unreadable(read))
        events.emit(
            "pipeline", "sidecar_unreadable",
            stem=read.sidecar.name.split(".", 1)[0], kind=read.kind, errno=read.errno,
        )
    return overlay


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

    Informational keys, read elsewhere or not at all, that change no routing:
      - `mic_device_name`, `mic_silent` (MIC15), for the Library
      - `held_end_trim_sec` (END17), seconds from the recording start where a
        held end began. The daemon already cut the transcript there, so the
        summary this pipeline writes covers only the meeting; the WAV keeps
        the tail so the owner can restore it.
      - `resumed_from` (END17), the stem a recording resumed from after an end
        the call outlived, for the Library's merge offer

    A sidecar that exists but cannot be read or parsed is not "no workflow"
    (SEC25): the run goes on-device, and `sidecar_unreadable` is emitted once.
    """
    read = load_meta(any_meeting_path)
    if read.state == "unreadable":
        return _fail_closed(cfg, read)
    meta = read.data
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
    if isinstance(backend_raw, str) and backend_raw in BACKENDS:
        if overlay.summarization.backend != backend_raw:
            overlay.summarization.backend = backend_raw  # type: ignore[assignment]
            changed.append(f"backend={backend_raw}")

    ctx = meta.get("workflow_context_prompt")
    if isinstance(ctx, str):
        if overlay.summarization.team_context != ctx:
            overlay.summarization.team_context = ctx
            changed.append("team_context")

    # WF7: workflow-defined extra summary sections. A list of {name, instruction}
    # dicts; kept only when both fields are non-empty so a half-filled row never
    # asks the model for an unnamed section.
    raw_sections = meta.get("workflow_extra_sections")
    if isinstance(raw_sections, list):
        specs = [
            ExtraSectionSpec(name=s["name"].strip(), instruction=s["instruction"].strip())
            for s in raw_sections
            if isinstance(s, dict)
            and isinstance(s.get("name"), str) and s["name"].strip()
            and isinstance(s.get("instruction"), str) and s["instruction"].strip()
        ]
        if specs:
            overlay.summarization.extra_sections = specs
            changed.append(f"extra_sections={len(specs)}")

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


def read_meta(any_meeting_path: Path) -> dict[str, Any]:
    """The sidecar as a dict, or `{}` when it is absent or unreadable. For the
    informational callers only; anything that routes a run uses `load_meta`
    (through `apply_overrides`), where unreadable fails closed."""
    read = load_meta(any_meeting_path)
    if read.state == "unreadable":
        log.warning("%s", _describe_unreadable(read))
    return read.data
