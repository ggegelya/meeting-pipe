"""Structured JSONL event logging for the pipeline.

One JSON object per line, appended to ``~/Library/Logs/MeetingPipe/pipeline_events.jsonl``.
Mirrors the Swift ``Log.event`` API in ``daemon/Sources/MeetingPipe/Logger.swift``,
so a single ``jq`` query against both files reconstructs the full meeting
lifecycle from detection through publish.

The text logs configured in ``orchestrate._configure_logging`` stay as-is
for tail-based debugging; this module is for grep-based postmortem.

Failures here are swallowed: an empty event log is preferable to a crashed
pipeline. The text log captures any I/O error.
"""
from __future__ import annotations

import json
import logging
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

_log = logging.getLogger("mp.events")

# PERF7: size-based rename rotation so the logs self-bound. `events.jsonl` grew to
# 63 MB / 338k lines on the dogfood Mac with no trim; the pipeline's own logs grow
# the same way. Kept byte-for-byte in step with Swift's Log.rotateIfNeeded.
_LOG_MAX_BYTES_DEFAULT = 5 * 1024 * 1024
_LOG_GENERATIONS = 3


def _max_log_bytes() -> int:
    raw = os.environ.get("MEETINGPIPE_LOG_MAX_BYTES")
    return int(raw) if raw and raw.isdigit() else _LOG_MAX_BYTES_DEFAULT


def _generation_path(path: Path, k: int) -> Path:
    """``events.jsonl`` -> ``events.1.jsonl``. The index goes before the extension
    so a rotated file stays valid JSONL / a tail-able log."""
    return path.with_name(f"{path.stem}.{k}{path.suffix}")


def rotate_if_needed(path: Path) -> None:
    """Rename-rotate ``path`` when it reaches the size cap. ``path`` -> ``path.1``,
    shifting older generations up and dropping the oldest, so a log family self-bounds
    at ~``(_LOG_GENERATIONS + 1) * cap``. Atomic renames, so a concurrent writer that
    loses the race just appends to a fresh file. Call before opening for append."""
    try:
        if path.stat().st_size < _max_log_bytes():
            return
    except OSError:
        return
    _generation_path(path, _LOG_GENERATIONS).unlink(missing_ok=True)
    for k in range(_LOG_GENERATIONS - 1, 0, -1):
        src = _generation_path(path, k)
        if src.exists():
            src.replace(_generation_path(path, k + 1))
    path.replace(_generation_path(path, 1))


def log_generations(path: Path) -> list[Path]:
    """Existing log files for ``path``, oldest first (base last / newest), so a
    reader concatenating them sees the recent window across a rotation boundary."""
    out: list[Path] = []
    for k in range(_LOG_GENERATIONS, 0, -1):
        g = _generation_path(path, k)
        if g.exists():
            out.append(g)
    if path.exists():
        out.append(path)
    return out


def _events_path() -> Path:
    base = Path(os.path.expanduser("~/Library/Logs/MeetingPipe"))
    base.mkdir(parents=True, exist_ok=True)
    return base / "pipeline_events.jsonl"


def emit(category: str, action: str, **attrs: Any) -> None:
    """Append one JSON event line. Attribute values must be JSON-serializable.

    Non-serializable values are silently coerced via ``default=str`` rather
    than dropping the event, on the principle that a slightly-degraded
    event still helps a postmortem.
    """
    record: dict[str, Any] = dict(attrs)
    record["ts"] = datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
    record["category"] = category
    record["action"] = action
    path = _events_path()
    try:
        rotate_if_needed(path)
        line = json.dumps(record, sort_keys=True, default=str)
        with path.open("a", encoding="utf-8") as f:
            f.write(line + "\n")
        # SEC11: the event log carries verbatim meeting titles, so keep it
        # user-private (0600). Idempotent, and self-heals a pre-existing 0644 file.
        os.chmod(path, 0o600)
    except Exception as e:  # pragma: no cover
        _log.warning("event log write failed: %s", e)
