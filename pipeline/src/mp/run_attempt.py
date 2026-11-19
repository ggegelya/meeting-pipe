"""STOR10: the last-attempt markers for the scheduled `mp backup` and `mp digest` runs.

`.last-backup.json` is written on success only, so a scheduled run that failed every night
(an unplugged drive, a moved `mp`) left Preferences reading "Last backup 23 days ago" and
nothing saying why. Each run now writes `~/.config/meeting-pipe/.last-<job>-attempt.json`
whatever happened: `at`, `outcome` (`ok` / `failed`), `reason` (capped at 300 characters),
and `trigger` (`scheduled` when the LaunchAgent set `MP_TRIGGER=scheduled`, else `manual`).
The daemon's `LastBackup` and `mp doctor` read it. Writing it never changes the run's exit
code or hides its exception: a failed write is logged and dropped.
"""
from __future__ import annotations

import json
import logging
import os
from datetime import UTC, datetime
from pathlib import Path

from . import storage

_log = logging.getLogger("mp.run_attempt")

#: Set to `scheduled` by the backup and digest LaunchAgents (`LaunchAgentScheduler`).
TRIGGER_ENV = "MP_TRIGGER"
REASON_CAP = 300
BACKUP = ".last-backup-attempt.json"
DIGEST = ".last-digest-attempt.json"


def marker_path(name: str, home: Path | None = None) -> Path:
    return storage.config_dir(home) / name


def trigger() -> str:
    """`scheduled` for a LaunchAgent run, `manual` for anything else (Back up now, the CLI)."""
    return "scheduled" if os.environ.get(TRIGGER_ENV) == "scheduled" else "manual"


def record(
    name: str,
    *,
    outcome: str,
    reason: str | None = None,
    run_trigger: str,
    home: Path | None = None,
    now: datetime | None = None,
) -> None:
    """Write the attempt marker. Never raises."""
    payload = {
        "at": (now or datetime.now(UTC)).isoformat(),
        "outcome": outcome,
        "reason": (reason or "")[:REASON_CAP] or None,
        "trigger": run_trigger,
    }
    path = marker_path(name, home)
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        storage.atomic_write_text(path, json.dumps(payload, indent=2))
    except OSError as exc:
        _log.warning("could not write %s: %s", path.name, exc)


def read(name: str, home: Path | None = None) -> dict | None:
    return storage.read_json_object(marker_path(name, home))
