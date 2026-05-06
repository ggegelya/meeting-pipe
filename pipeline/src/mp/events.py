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
    try:
        line = json.dumps(record, sort_keys=True, default=str)
        with _events_path().open("a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception as e:  # pragma: no cover
        _log.warning("event log write failed: %s", e)
