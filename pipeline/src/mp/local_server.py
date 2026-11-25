"""Ownership marker for the detached `mlx_lm.server` child (LOCAL10).

`LocalSummaryClient._spawn` starts the model server with `start_new_session=True`,
putting it in its own session so a signal aimed at `mp`'s process group cannot
reach it. Every clean exit path calls `close()`, which kills it, and since PIPE22
so does a SIGTERM (the daemon's Cancel and its watchdog), which `__main__` turns
into an unwind. The paths that do not are a `SIGKILL` of `mp` itself (the
daemon's follow-up when the SIGTERM grace runs out, the LOCAL2/AUD-21 scenario)
and a server that survives its own kill ladder. Then the parent's idle-timeout
`threading.Timer` dies with the parent, the child's own session shields it from
the group kill, and a multi-GB server survives with nothing left on the machine
that knows it exists.

This module is that missing knowledge. `_spawn` writes a marker naming the
server pid, the port, the model, and the `mp` process that owns it; a confirmed
exit removes it, and nothing else does (PIPE22: a marker cleared ahead of a kill
that then failed left a live server nobody could see). Anything that finds a
marker whose server is alive and whose owner is gone has found an orphan:

  - `mp doctor` reports it (`check_local_server`).
  - The daemon reaps it, in Swift, from `LocalServerReaper` (at launch and after
    every finished job, right after its watchdog kills a job, and after a user
    Cancel).

A client that reuses a server the marker names takes ownership while it uses it
(`restamp_owner`) and hands it back on close (`hand_back_owner`), so a reap
triggered by the spawner's death cannot kill a server a live `mp ask` is using.

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

import hashlib
import hmac
import json
import logging
import os
import secrets
import signal
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path
from typing import IO, Any

from . import events, local_snapshot, storage

log = logging.getLogger("mp.local_server")

SCHEMA_VERSION = 1
MARKER_NAME = "mlx-server.json"

# LOCAL16: where the model server's own stdout/stderr goes. It used to go to
# DEVNULL, so an OOM message from mlx_lm.server was discarded and the failure
# surfaced as the generic "exited during startup (rc=...)" guess. Sized and
# rotated by the same helper as the event log, so it self-bounds.
SERVER_LOG_NAME = "mlx-server.log"

# Substrings that identify our model server in a `ps` command line. Guards
# against pid reuse: a recycled pid pointing at some unrelated process must
# never be signalled. Since SEC27 the server is launched through the hardened
# `mp.local_model_server` shim (which then runs mlx-lm's own `main`), so its argv
# names the shim; a server a pre-SEC27 build left running still names
# `mlx_lm.server`. Mirrored by Swift's `LocalServerReaper.isServerCommand`.
_SERVER_COMMAND_MARKS = ("mlx_lm.server", "mp.local_model_server")


def is_server_command(command: str | None) -> bool:
    """Does this `ps` command line belong to our model server?"""
    return command is not None and any(mark in command for mark in _SERVER_COMMAND_MARKS)

# The two identity-bearing flags `summarize_local.build_server_command` emits.
_MODEL_FLAG = "--model"
_ADAPTER_FLAG = "--adapter-path"


def marker_path(home: Path | None = None) -> Path:
    """`~/Library/Logs/MeetingPipe/mlx-server.json`, beside the logs.

    With no `home` it routes through `events.logs_dir` (T9), so
    `MEETINGPIPE_LOGS_DIR` applies; an explicit `home`
    keeps the old `<home>/Library/Logs/MeetingPipe` shape its tests pin."""
    if home is None:
        return events.logs_dir() / MARKER_NAME
    return home / "Library" / "Logs" / "MeetingPipe" / MARKER_NAME


def server_log_path() -> Path:
    """`~/Library/Logs/MeetingPipe/mlx-server.log`. Routed through
    `events.logs_dir`, so `MEETINGPIPE_LOGS_DIR` applies here exactly as it
    does to the event log."""
    return events.logs_dir() / SERVER_LOG_NAME


def open_server_log() -> IO[bytes] | None:
    """A rotated append handle for the model server's output, or None when the
    file cannot be opened. Best-effort: losing the log must never stop a
    summarize, so the caller falls back to DEVNULL."""
    path = server_log_path()
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        events.rotate_if_needed(path)
        handle = path.open("ab")
    except OSError as e:
        log.warning("could not open the model-server log %s: %s", path, e)
        return None
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass
    return handle


def tail_server_log(max_chars: int = 800) -> str:
    """The last `max_chars` of the model server's log, for a failure message.
    Empty string when there is nothing readable, so a caller can append it
    unconditionally."""
    try:
        text = server_log_path().read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""
    return text[-max_chars:].strip()


# SEC27: the per-spawn bearer token the model server demands on every request.
# The spawner (`LocalSummaryClient._spawn` or `mp serve-local`) generates it and
# hands it to the server through the environment, never argv (`ps` shows argv to
# every account). The *server* records it here once it is bound and listening
# (`local_model_server`), so a spawn that loses a port race never replaces the
# record of the server that won it, and any later `mp` that reuses the warm
# server reads it from this file. 0600, in Application Support (a log folder
# travels in diagnostic bundles); a process that can read it already runs as the
# owner. Clients also use it to *verify* the server: see `health_proof`.
TOKEN_NAME = "mlx-server.token"  # noqa: S105 - a file name, not a secret
TOKEN_ENV = "MP_LOCAL_SERVER_TOKEN"  # noqa: S105 - a name; == local_model_server.TOKEN_ENV, which cannot be imported here
HEALTH_PATH = "/health"


def token_path(home: Path | None = None) -> Path:
    return storage.app_support_dir(home) / TOKEN_NAME


def new_token() -> str:
    return secrets.token_urlsafe(32)


_HEALTH_DOMAIN = b"mp-local-server-health-v2:"
_BEARER_LABEL = b"mp-local-server-bearer-v2:"


def health_proof(token: str, nonce: str) -> str:
    """What a server that knows `token` answers `GET /health?nonce=<nonce>` with.

    The bearer token authenticates the client to the server; this is the other
    direction. Anything can bind an idle loopback port and answer 200, so a
    client that sent a transcript to "whatever answers /health" was handing it to
    whichever local program got there first. A squatter cannot read the 0600
    token file, so it cannot compute this.

    The nonce is attacker-chosen and the route is unauthenticated, so this HMAC
    lives in its own domain (`_HEALTH_DOMAIN`, which `_BEARER_LABEL` does not start with): no nonce a caller can send may
    reproduce the bearer (see `bearer_for`)."""
    return hmac.new(token.encode("utf-8"), _HEALTH_DOMAIN + nonce.encode("utf-8"), hashlib.sha256).hexdigest()


def bearer_for(token: str) -> str:
    """The credential a client puts on the wire, derived one-way from `token`.

    `token` itself is the key of `health_proof`, so it must never leave the two
    processes that hold the file: if the bearer *were* the token, a listener that
    captured one request could pass every later health probe. A captured bearer
    proves nothing about `token`.

    Both HMACs share the key, so they are separated by domain: `/health` answers
    `HMAC(token, _HEALTH_DOMAIN + nonce)` for any nonce a caller picks, and the
    bearer label below does not start with `_HEALTH_DOMAIN`, so no nonce can make
    the two inputs equal (the `:` in the bearer label is belt and braces: the
    nonce alphabet `[A-Za-z0-9_-]` cannot carry it). Before SEC27's amendment the bearer label was itself a valid nonce, so
    one unauthenticated GET returned the bearer."""
    return hmac.new(token.encode("utf-8"), _BEARER_LABEL, hashlib.sha256).hexdigest()


def clear_token(pid: int | None = None, home: Path | None = None) -> None:
    """Remove the token record when its server is gone. With `pid`, only a record
    that names that pid (a newer server's record is not ours to delete)."""
    path = token_path(home)
    try:
        if pid is not None:
            data = storage.read_json_object(path)
            if data is None or data.get("pid") != pid:
                return
        path.unlink(missing_ok=True)
    except OSError:
        pass


def write_token(port: int, token: str, pid: int, home: Path | None = None) -> None:
    """Atomic 0600 write of `{port, pid, token}`. Raises `OSError`: a server we
    cannot authenticate to is useless, so the caller must stop."""
    path = token_path(home)
    path.parent.mkdir(parents=True, exist_ok=True)
    # The helper's temp is created fresh at 0600 under a per-writer name (PIPE30),
    # so two servers writing at once cannot interleave and no looser file is reused.
    storage.atomic_write_text(path, json.dumps({"port": port, "pid": pid, "token": token}))


def read_token(port: int, home: Path | None = None) -> str | None:
    """The token of the server recorded for `port`, or None when there is no
    readable record for that port (so there is nothing to verify or sign with)."""
    data = storage.read_json_object(token_path(home))
    if data is None or data.get("port") != port:
        return None
    token = data.get("token")
    return token if isinstance(token, str) and token else None


def server_env(token: str, base: dict[str, str] | None = None) -> dict[str, str]:
    """The environment for the model-server child (SEC27, SEC13).

    Starts from `egress_guard.child_env` (scrubbed and offline when armed) and
    then removes every managed token in EVERY mode: the server serves a local
    snapshot and needs no credential, and until now an unarmed child inherited
    the lot. Always offline, and carries this spawn's bearer token."""
    from . import egress_guard
    from .config import MANAGED_SECRET_KEYS

    env = egress_guard.child_env(base)
    for key in MANAGED_SECRET_KEYS:
        env.pop(key, None)
    env["HF_HUB_OFFLINE"] = "1"
    env["TRANSFORMERS_OFFLINE"] = "1"
    env[TOKEN_ENV] = token
    return env


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
        _write_marker_payload(payload, home)
    except OSError as e:
        log.warning("could not write local-server marker %s: %s", marker_path(home), e)


def _write_marker_payload(payload: dict[str, Any], home: Path | None) -> None:
    """Atomic `0600` write of a marker payload. Raises `OSError`; callers decide
    whether a failed write matters."""
    path = marker_path(home)
    path.parent.mkdir(parents=True, exist_ok=True)
    storage.atomic_write_text(path, json.dumps(payload, indent=2))


def restamp_owner(server_pid: int, home: Path | None = None) -> int | None:
    """Make this process the owner of the marker that names `server_pid`
    (PIPE22), keeping every other field. Returns the owner it replaced, so the
    caller can hand ownership back when it is done, or None when nothing changed.

    A client reusing a warm server used to leave the marker naming the `mp` that
    spawned it. Owner liveness is the only thing both reapers check, so once that
    spawner died (a Cancel, a watchdog kill) the server read as an orphan and was
    killed under the live `mp ask` still using it.

    Never creates a marker: a server with none (the daemon's warm `mp
    serve-local`) is owned through the daemon's child handle, and giving it a
    marker would make it reapable. Best-effort, like `write_marker`."""
    marker = read_marker(home)
    if marker is None or marker.get("pid") != server_pid:
        return None
    previous = marker.get("owner_pid")
    if previous == os.getpid():
        return None
    try:
        _write_marker_payload({**marker, "owner_pid": os.getpid()}, home)
    except OSError as e:
        log.warning("could not re-stamp local-server marker: %s", e)
        return None
    return previous if isinstance(previous, int) else None


def hand_back_owner(server_pid: int, owner_pid: int, home: Path | None = None) -> None:
    """Undo `restamp_owner` when this process stops using `server_pid`.

    Only while the marker still names that server and this process, and only to
    an owner that is still alive. A dead previous owner is left alone: the
    server then reads as an orphan once we exit, which is right, since nobody is
    using it any more, and is what keeping our own soon-dead pid amounts to."""
    marker = read_marker(home)
    if (
        marker is None
        or marker.get("pid") != server_pid
        or marker.get("owner_pid") != os.getpid()
        or not is_owner_alive(owner_pid)
    ):
        return
    try:
        _write_marker_payload({**marker, "owner_pid": owner_pid}, home)
    except OSError as e:
        log.warning("could not hand the local-server marker back: %s", e)


def note_survived_kill(pid: int, last_signal: str) -> None:
    """A server outlived its kill ladder: say so (PIPE22). The caller keeps the
    marker.

    Both kill paths used to clear the marker regardless, so a survivor became
    invisible to `mp doctor` and the daemon reaper, which are both marker-based.
    This is the record that the marker had to stay."""
    log.warning(
        "mlx_lm.server %s survived %s; keeping its marker for mp doctor and the reaper",
        pid, last_signal,
    )
    events.emit("pipeline", "local_server_survived_kill", pid=pid, signal=last_signal)


def clear_marker(home: Path | None = None) -> None:
    """Remove the marker once its server is confirmed gone. Idempotent."""
    try:
        marker_path(home).unlink(missing_ok=True)
    except OSError as e:
        log.warning("could not remove local-server marker: %s", e)


def read_marker(home: Path | None = None) -> dict[str, Any] | None:
    path = marker_path(home)
    if not path.exists():
        return None
    data = storage.read_json_object(path)
    if data is None:
        log.warning("local-server marker at %s is unreadable", path)
    return data


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
    return is_server_command(pid_command(pid))


def is_owner_command(command: str | None) -> bool:
    """Does this `ps` command line belong to a Python `mp` invocation?

    A Python interpreter whose argv carries `-m mp` (both daemon tiers, DIST1) or
    an `mp` entrypoint path segment (`.venv/bin/mp`, which is how `uv run mp` and
    a console script show up: macOS lists a shebang script as its interpreter
    followed by the script path). Pure, and mirrored token for token by Swift's
    `LocalServerReaper.isOwnerCommand`; both suites pin the same cases.

    It used to be `"mp" in cmd or "python" in cmd.lower()`, which any command
    containing the letters `mp` satisfied (a path under `/tmp`, `sample`, a
    compiler), so after pid reuse a dead owner could read as alive and shield an
    orphan forever (PIPE22, CONC5 item d). Tokens are split on whitespace, so a
    path with a space in it (`~/My Documents/...`) still ends in a `/mp` token.
    """
    if not command:
        return False
    tokens = command.split()
    python_at = next((i for i, t in enumerate(tokens) if "python" in t.lower()), None)
    if python_at is None:
        return False
    rest = tokens[python_at + 1:]
    for i, arg in enumerate(rest):
        if arg == "mp" and i > 0 and rest[i - 1] == "-m":
            return True
        if arg.endswith("/mp"):
            return True
    return False


def is_owner_alive(pid: int) -> bool:
    """True when the `mp` process that owns the server is still running.

    A recycled pid belonging to something that is not a Python `mp` invocation
    reads as dead, so a long-lived orphan is not hidden by pid reuse.
    """
    return is_owner_command(pid_command(pid))


#: Root-owned system binary (SEC17): the answer feeds `served_identity`, so a `lsof` planted
#: earlier on a user-writable PATH must not be the one that answers.
LSOF = "/usr/sbin/lsof"


def listening_pid(port: int) -> int | None:
    """Pid of whatever holds `port`, via macOS `lsof`. None when nothing listens
    or `lsof` is unavailable, so a caller degrades to "identity unknown" rather
    than to a false mismatch."""
    try:
        out = subprocess.run(
            [LSOF, "-nP", f"-iTCP:{port}", "-sTCP:LISTEN", "-t"],
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
    model = _flag_value(command, _MODEL_FLAG)
    if model is not None:
        # SEC27: the server is started on a `snapshots/<sha>` directory; the rest
        # of the system (config, the run sidecar, `matches`) speaks repo ids.
        model = local_snapshot.repo_id_from_snapshot(model) or model
    return model, _flag_value(command, _ADAPTER_FLAG)


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
    #: SEC27: the listener's argv when `source == "foreign"`, for the refusal.
    command: str | None = None

    @property
    def is_foreign(self) -> bool:
        """`lsof` named the listener and it is not our model server."""
        return self.source == "foreign"

    def matches(self, *, model: str, adapter_path: str | None) -> bool:
        """Does this server serve the configured identity?

        Fails open on an identity we could not read (`model is None`): an argv we
        cannot parse costs a warm reuse, never a needless respawn of a multi-GB
        server. A foreign listener never matches (SEC27).
        """
        if self.is_foreign:
            return False
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

    A listener that `lsof` and `ps` identified as something else (SEC27) is
    returned as a `foreign` identity, which is a positive mismatch, not "no
    answer": it used to land in None and be reused like an unknown. None still
    means "could not tell" (no `lsof`, an unreadable `ps` line, an absent
    marker), and a caller treats it as unknown; the bearer-token probe is what
    covers that case.
    """
    pid = listening_pid(port)
    if pid is not None:
        cmd = pid_command(pid)
        if cmd is None:
            return None
        if is_server_command(cmd):
            model, adapter = parse_identity(cmd)
            return ServedIdentity(pid=pid, model=model, adapter_path=adapter, source="argv")
        return ServedIdentity(
            pid=pid, model=None, adapter_path=None, source="foreign", command=cmd
        )

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


# PIPE22: how long a SIGKILLed server gets to leave the process table before it
# counts as a survivor. SIGKILL cannot be caught, so this only covers the kernel
# tearing a multi-GB process down; it is not a second grace.
KILL_CONFIRM_SEC = 2.0


def terminate_server(pid: int, home: Path | None = None) -> bool:
    """SIGTERM (then SIGKILL) an `mlx_lm.server` we own, and clear its marker
    once it is confirmed gone.

    Signals the process *group*: the server setsid'd into its own session, so the
    group id equals the pid and any worker it forked dies with it. Returns False
    without signalling anything when `pid` is not actually a server, so a recycled
    pid is never killed. Blocks up to ~10 s for a graceful exit, which is what
    lets a caller rebind the same port immediately afterwards.

    Also returns False, keeping the marker, when the server is still alive after
    the whole ladder (PIPE22): a signal that raised, or a SIGKILL that did not
    land. The marker is the only record `mp doctor` and the daemon reaper have,
    so clearing it for a survivor hid a multi-GB process from both. A caller
    tells the two Falses apart with `is_server_pid`.
    """
    if not is_server_pid(pid):
        clear_marker(home)
        clear_token(pid)
        return False
    last_signal = "SIGTERM"
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
            last_signal = "SIGKILL"
            try:
                os.killpg(os.getpgid(pid), signal.SIGKILL)
            except (OSError, ProcessLookupError) as e:
                log.warning("SIGKILL to local model server %s failed: %s", pid, e)
            for _ in range(int(KILL_CONFIRM_SEC / 0.5)):
                if not is_server_pid(pid):
                    break
                time.sleep(0.5)
    if is_server_pid(pid):
        note_survived_kill(pid, last_signal)
        return False
    clear_marker(home)
    clear_token(pid)
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
