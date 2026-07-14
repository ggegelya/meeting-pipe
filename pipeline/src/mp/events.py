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
import re
import sys
import tempfile
from collections.abc import Iterable
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
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


#: The engine that actually transcribes. Anything else in a ``transcription`` row is a
#: test double (the ``fake`` / ``pass`` runners in the Swift suite).
REAL_ENGINE = "fluidaudio"

#: Real recordings are stemmed ``YYYYMMDD-HHMMSS``. Every fixture stem the suites emit
#: (``clip.wav``, ``a.wav``, ``x``, ``m``, the 4-digit-time ``20260710-1200``) fails this,
#: which is the only reason historical residue is identifiable at all.
_REAL_STEM = re.compile(r"^\d{8}-\d{6}$")

#: Keys naming the meeting a row belongs to. Deliberately excludes ``path``: on a
#: ``prefetch`` row that is a model-cache path, and treating it as a stem would drop a
#: real event.
_MEETING_KEYS = ("file", "stem", "wav", "meeting")


def is_test_residue(event: dict[str, Any]) -> bool:
    """True when a row in the real log was written by a test suite, not by the app.

    Both suites wrote here: Swift until TECH-END4 isolated it, Python until the
    ``logs_dir`` guard above. The rows they already left behind are permanent, because
    they sit in rotated generations that nothing rewrites, and every reader concatenates
    those generations. So a reader that does not drop them reports work that never
    happened: on the dogfood Mac the residue faked 250 ``pipeline_failed`` rows against
    0 real ones, and 243 ``engine_failed`` against 0.

    Identified by content, two ways:

    * a ``transcription`` row whose ``engine`` is not :data:`REAL_ENGINE` (the ``fake`` /
      ``pass`` runners, including the ``FakeRunner.Boom`` deliberate failures);
    * any row naming a meeting whose stem is not a real ``YYYYMMDD-HHMMSS`` recording.

    Deliberately not exhaustive, and it cannot be. Test rows that name no meeting
    (``coordinator.state_change``, ``workflow.migrator_seeded``, ``daemon.
    notion_fetch_blocked``) are byte-identical to real ones and interleave with them in
    the same time window, so no content or time discriminator separates them. Those
    inflate benign counters; they fabricate no failures. Do not read a pass through this
    filter as "the log is clean".
    """
    if event.get("category") == "transcription":
        engine = event.get("engine")
        if isinstance(engine, str) and engine != REAL_ENGINE:
            return True
    for key in _MEETING_KEYS:
        value = event.get(key)
        if isinstance(value, str) and value:
            if not _REAL_STEM.match(PurePosixPath(value).name.split(".")[0]):
                return True
    return False


def drop_test_residue(rows: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    """:func:`is_test_residue` over a stream. The call every log reader owes the user."""
    return [row for row in rows if not is_test_residue(row)]


def _running_under_tests() -> bool:
    """True when this process is hosting a pytest run. The env var is only set once
    a test is executing, so fall back to the imported module and the guard also holds
    at collection/import time. The installed CLI never imports pytest."""
    return "PYTEST_CURRENT_TEST" in os.environ or "pytest" in sys.modules


def logs_dir() -> Path:
    """Resolve the logs directory. An explicit ``MEETINGPIPE_LOGS_DIR`` wins (sandboxed
    runs, targeted tests); otherwise, under pytest we redirect to a temp dir so the suite
    never appends fixture rows (stems ``x``, ``m``, ``20260506-1500``) into the user's
    production ``pipeline_events.jsonl``.

    Without this the suite corrupts the very log every analysis reads: on the dogfood Mac
    21% of that file (1491 of 7020 rows) was pytest output. Mirrors Swift's
    ``Log.resolveLogsDir`` (TECH-END4), env var and all, so both writers isolate the
    same way."""
    override = os.environ.get("MEETINGPIPE_LOGS_DIR")
    if override:
        return Path(override)
    if _running_under_tests():
        return Path(tempfile.gettempdir()) / "MeetingPipe-test-logs"
    return Path(os.path.expanduser("~/Library/Logs/MeetingPipe"))


def _events_path() -> Path:
    base = logs_dir()
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
