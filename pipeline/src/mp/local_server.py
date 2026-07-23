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

Served identity (LOCAL11)
-------------------------
The second thing nothing on the machine knew: *what* the running server serves.
`LocalSummaryClient` reuses a warm server on a bare HTTP 200, so flipping
`summarization.local_model` or `local_adapter_path` used to leave the old weights
serving every later run, with the run sidecar recording the configured id rather
than the one that answered. `served_identity()` reads it back from the server's
own argv, which is the only ground truth available:

  - `/v1/models` cannot answer this. mlx-lm's handler scans the HuggingFace cache
    and lists *every* downloaded MLX model, then appends `--model` only when it is
    a filesystem path; a repo-id server is indistinguishable from any other cached
    repo. `/v1/chat/completions` is no better: it echoes back the `model` the
    caller sent. Verified against mlx-lm 0.31.3.
  - The argv behind the listening pid does answer it, for any owner: the server we
    spawned, one a previous `mp` left behind, and the daemon's warm `mp serve-local`
    (which `execvpe`s, so its argv *is* the server's). `lsof` on the port, `ps` on
    the pid, parse the flags `build_server_command` emitted.

Argv is the spawn contract, not a readback of the loaded weights, so this catches
a server started for a different model or adapter, not a server that failed to
apply the adapter it was handed. The marker is the fallback when `lsof` is
unavailable, and carries the same two fields for that reason.
"""
from __future__ import annotations

import json
import logging
import os
import signal
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

log = logging.getLogger("mp.local_server")

SCHEMA_VERSION = 1
MARKER_NAME = "mlx-server.json"

# Substring that identifies an `mlx_lm.server` in a `ps` command line. Guards
# against pid reuse: a recycled pid pointing at some unrelated process must
# never be signalled.
_SERVER_COMMAND_MARK = "mlx_lm.server"

# The two identity-bearing flags `summarize_local.build_server_command` emits.
_MODEL_FLAG = "--model"
_ADAPTER_FLAG = "--adapter-path"


def marker_path(home: Path | None = None) -> Path:
    """`~/Library/Logs/MeetingPipe/mlx-server.json`, beside the logs."""
    base = (home or Path.home()) / "Library" / "Logs" / "MeetingPipe"
    return base / MARKER_NAME


def write_marker(
    *,
    pid: int,
    port: int,
    model: str,
    adapter_path: str | None = None,
    home: Path | None = None,
) -> None:
    """Record a freshly spawned server. Best-effort: failing to write a marker
    must not fail the summarize that just started a working server.

    `adapter_path` (LOCAL11) records the LoRA adapter the server was started with,
    so the identity check has an answer when `lsof` cannot name the listening pid.
    Empty string and None both mean "base model", and both serialize as `""`.
    """
    path = marker_path(home)
    payload = {
        "schema_version": SCHEMA_VERSION,
        "pid": pid,
        "owner_pid": os.getpid(),
        "port": port,
        "model": model,
        "adapter_path": adapter_path or "",
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


def listening_pid(port: int) -> int | None:
    """Pid of whatever holds `port`, via macOS `lsof`. None when nothing listens
    or `lsof` is unavailable, so a caller degrades to "identity unknown" rather
    than to a false mismatch."""
    try:
        out = subprocess.run(
            ["lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN", "-t"],
            capture_output=True, text=True, timeout=5, check=False,
        ).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return None
    first = out.splitlines()[0] if out else ""
    return int(first) if first.isdigit() else None


def _flag_value(command: str, flag: str) -> str | None:
    """The value following `flag` in a space-joined command line, or None.

    Reads to the end of the string or the next ` --` rather than splitting on
    whitespace, because an adapter path is user-chosen and routinely contains a
    space (`~/Library/Application Support/...`). `build_server_command` never
    emits a value that itself starts a ` --` run, so this is unambiguous for the
    argv we generate.
    """
    needle = f"{flag} "
    at = command.find(needle)
    if at < 0:
        return None
    rest = command[at + len(needle):]
    end = rest.find(" --")
    value = (rest if end < 0 else rest[:end]).strip()
    return value or None


def parse_identity(command: str) -> tuple[str | None, str | None]:
    """`(model, adapter_path)` parsed out of an `mlx_lm.server` command line.

    Pure, so the parse is unit-testable without a process table. Either half is
    None when the flag is absent: no `--adapter-path` means the base model, and
    no `--model` means an argv we do not recognise (a server someone started by
    hand), which callers must treat as unknown rather than as a mismatch.
    """
    return _flag_value(command, _MODEL_FLAG), _flag_value(command, _ADAPTER_FLAG)


@dataclass(frozen=True)
class ServedIdentity:
    """What the `mlx_lm.server` on a port is actually serving (LOCAL11).

    `source` is `"argv"` when read from the listening process's command line (the
    ground truth, and the only source that covers a server we did not spawn) or
    `"marker"` when `lsof` could not name the pid and the LOCAL10 marker answered
    instead.
    """
    pid: int
    model: str | None
    adapter_path: str | None
    source: str

    def matches(self, *, model: str, adapter_path: str | None) -> bool:
        """Does this server serve the configured identity?

        Fails open: an identity we could not read (`model is None`) never reports
        a mismatch, so an argv we cannot parse costs a warm reuse, never a
        needless respawn of a multi-GB server.
        """
        if self.model is None:
            return True
        if self.model != model:
            return False
        return (self.adapter_path or "") == (adapter_path or "")

    def describe(self) -> str:
        """One-line rendering for a log line or a doctor row."""
        base = self.model or "unknown model"
        return f"{base} + adapter {self.adapter_path}" if self.adapter_path else base


def served_identity(port: int, home: Path | None = None) -> ServedIdentity | None:
    """What is being served on `port` right now, or None when that is unknowable.

    Prefers the listening process's argv, which answers for any owner: a server
    this process spawned, one a previous `mp` left behind, and the daemon's warm
    `mp serve-local` (which `execvpe`s into the server, so its argv is the
    server's). Falls back to the LOCAL10 marker when `lsof` cannot name the pid,
    which only covers `mp`-spawned servers but is better than nothing.

    None means "no answer", never "no mismatch": something non-mlx holding the
    port, an unreadable `ps` line, and an absent marker all land here, and every
    caller treats it as unknown.
    """
    pid = listening_pid(port)
    if pid is not None:
        cmd = pid_command(pid)
        if cmd is not None and _SERVER_COMMAND_MARK in cmd:
            model, adapter = parse_identity(cmd)
            return ServedIdentity(pid=pid, model=model, adapter_path=adapter, source="argv")
        return None

    marker = read_marker(home)
    if marker is None or marker.get("port") != port:
        return None
    marker_pid = marker.get("pid")
    if not isinstance(marker_pid, int) or not is_server_pid(marker_pid):
        return None
    model = marker.get("model")
    adapter = marker.get("adapter_path")
    return ServedIdentity(
        pid=marker_pid,
        model=model if isinstance(model, str) and model else None,
        adapter_path=adapter if isinstance(adapter, str) and adapter else None,
        source="marker",
    )


def terminate_server(pid: int, home: Path | None = None) -> bool:
    """SIGTERM (then SIGKILL) an `mlx_lm.server` we own, and clear its marker.

    Signals the process *group*: the server setsid'd into its own session, so the
    group id equals the pid and any worker it forked dies with it. Returns False
    without signalling anything when `pid` is not actually a server, so a recycled
    pid is never killed. Blocks up to ~10 s for a graceful exit, which is what
    lets a caller rebind the same port immediately afterwards.
    """
    if not is_server_pid(pid):
        clear_marker(home)
        return False
    try:
        os.killpg(os.getpgid(pid), signal.SIGTERM)
    except (OSError, ProcessLookupError) as e:
        log.warning("SIGTERM to local model server %s failed: %s", pid, e)
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
    return True


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

    `orphaned_server` decides *whether* it is ours to kill (live server, dead
    owner); `terminate_server` does the killing, shared with the LOCAL11
    identity-mismatch replacement.
    """
    marker = orphaned_server(home)
    if marker is None:
        return None
    pid = int(marker["pid"])
    log.warning("reaping orphaned mlx_lm.server (pid=%s, model=%s)", pid, marker.get("model"))
    terminate_server(pid, home)
    return marker
