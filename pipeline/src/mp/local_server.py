"""Ownership marker for the detached `mlx_lm.server` child (LOCAL10).

`LocalSummaryClient._spawn` starts the model server with `preexec_fn=os.setsid`,
putting it in its own session so a signal aimed at `mp`'s process group cannot
reach it. Every clean exit path calls `close()`, which kills it. The one path
that does not is a `SIGKILL` of `mp` itself, which is exactly what the daemon's
pipeline watchdog does to a wedged `run-all` (the LOCAL2/AUD-21 scenario). Then
the parent's idle-timeout `threading.Timer` dies with the parent, the child's
own session shields it from the group kill, and a multi-GB server survives with
nothing left on the machine that knows it exists.

This module is that missing knowledge. `_spawn` writes a marker naming the
server pid, the port, the model, and the `mp` process that owns it; a clean
termination removes it. Anything that finds a marker whose server is alive and
whose owner is gone has found an orphan:

  - `mp doctor` reports it (`check_local_server`).
  - The daemon reaps it, in Swift, from `LocalServerReaper` (at launch, and
    right after its watchdog kills a pipeline job).

The marker is a Swift-to-Python contract, so its schema lives in CONVENTIONS.md
beside the sidecars. `mp serve-local` writes no marker: the daemon spawns it
directly and owns its lifetime through a child handle, so it is never orphaned.
"""
from __future__ import annotations

import json
import logging
import os
import signal
import subprocess
import time
from pathlib import Path
from typing import Any

log = logging.getLogger("mp.local_server")

SCHEMA_VERSION = 1
MARKER_NAME = "mlx-server.json"

# Substring that identifies an `mlx_lm.server` in a `ps` command line. Guards
# against pid reuse: a recycled pid pointing at some unrelated process must
# never be signalled.
_SERVER_COMMAND_MARK = "mlx_lm.server"


def marker_path(home: Path | None = None) -> Path:
    """`~/Library/Logs/MeetingPipe/mlx-server.json`, beside the logs."""
    base = (home or Path.home()) / "Library" / "Logs" / "MeetingPipe"
    return base / MARKER_NAME


def write_marker(*, pid: int, port: int, model: str, home: Path | None = None) -> None:
    """Record a freshly spawned server. Best-effort: failing to write a marker
    must not fail the summarize that just started a working server."""
    path = marker_path(home)
    payload = {
        "schema_version": SCHEMA_VERSION,
        "pid": pid,
        "owner_pid": os.getpid(),
        "port": port,
        "model": model,
        "spawned_at": time.time(),
    }
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_name(path.name + ".tmp")
        tmp.write_text(json.dumps(payload, indent=2), encoding="utf-8")
        os.chmod(tmp, 0o600)
        tmp.replace(path)
    except OSError as e:
        log.warning("could not write local-server marker %s: %s", path, e)


def clear_marker(home: Path | None = None) -> None:
    """Remove the marker on a clean self-termination. Idempotent."""
    try:
        marker_path(home).unlink(missing_ok=True)
    except OSError as e:
        log.warning("could not remove local-server marker: %s", e)


def read_marker(home: Path | None = None) -> dict[str, Any] | None:
    path = marker_path(home)
    if not path.exists():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as e:
        log.warning("local-server marker at %s is unreadable: %s", path, e)
        return None
    return data if isinstance(data, dict) else None


def pid_command(pid: int) -> str | None:
    """The full command line of `pid`, or None if it does not exist."""
    if pid <= 0:
        return None
    try:
        out = subprocess.run(
            ["/bin/ps", "-o", "command=", "-p", str(pid)],
            capture_output=True, text=True, timeout=5, check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    cmd = out.stdout.strip()
    return cmd or None


def is_server_pid(pid: int) -> bool:
    """True when `pid` is alive and is actually an `mlx_lm.server`."""
    cmd = pid_command(pid)
    return cmd is not None and _SERVER_COMMAND_MARK in cmd


def is_owner_alive(pid: int) -> bool:
    """True when the `mp` process that spawned the server is still running.

    A recycled pid belonging to something that is not a Python `mp` invocation
    reads as dead, so a long-lived orphan is not hidden by pid reuse.
    """
    cmd = pid_command(pid)
    if cmd is None:
        return False
    return "mp" in cmd or "python" in cmd.lower()


def orphaned_server(home: Path | None = None) -> dict[str, Any] | None:
    """The marker of a server that outlived its owner, or None.

    A marker whose server is already gone is stale, not an orphan: it is cleared
    as a side effect so the next caller sees a clean slate.
    """
    marker = read_marker(home)
    if marker is None:
        return None
    pid = marker.get("pid")
    owner = marker.get("owner_pid")
    if not isinstance(pid, int) or not isinstance(owner, int):
        clear_marker(home)
        return None
    if not is_server_pid(pid):
        clear_marker(home)
        return None
    if is_owner_alive(owner):
        return None  # a live `mp` is mid-summarize; its own close() will reap this
    return marker


def reap_orphan(home: Path | None = None) -> dict[str, Any] | None:
    """Kill an orphaned server and clear its marker. Returns the reaped marker,
    or None when there was nothing to reap.

    Signals the process *group*: the server setsid'd into its own session, so
    the group id equals the pid and any worker it forked dies with it.
    """
    marker = orphaned_server(home)
    if marker is None:
        return None
    pid = int(marker["pid"])
    log.warning("reaping orphaned mlx_lm.server (pid=%s, model=%s)", pid, marker.get("model"))
    try:
        os.killpg(os.getpgid(pid), signal.SIGTERM)
    except (OSError, ProcessLookupError) as e:
        log.warning("SIGTERM to orphaned server %s failed: %s", pid, e)
    else:
        for _ in range(20):  # up to ~10 s for a graceful exit
            time.sleep(0.5)
            if not is_server_pid(pid):
                break
        else:
            try:
                os.killpg(os.getpgid(pid), signal.SIGKILL)
            except (OSError, ProcessLookupError):
                pass
    clear_marker(home)
    return marker
