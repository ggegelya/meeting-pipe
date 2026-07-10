"""Tests for the detached-server ownership marker (LOCAL10).

No real `mlx_lm.server` is started and nothing is signalled: `pid_command` is the
single seam onto the process table, so faking it covers alive / dead / recycled
without touching a real process.
"""
from __future__ import annotations

import json
import time
from pathlib import Path

import pytest

from mp import local_server

_SERVER_CMD = "/opt/homebrew/bin/mlx_lm.server --model mlx-community/Qwen2.5-7B-Instruct-4bit"
_MP_CMD = "/usr/bin/python3 -m mp run-all /tmp/x.wav"


def _fake_process_table(monkeypatch: pytest.MonkeyPatch, table: dict[int, str]) -> None:
    monkeypatch.setattr(local_server, "pid_command", lambda pid: table.get(pid))


def _write(home: Path, **overrides: object) -> Path:
    path = local_server.marker_path(home)
    path.parent.mkdir(parents=True, exist_ok=True)
    payload: dict[str, object] = {
        "schema_version": 1,
        "pid": 4242,
        "owner_pid": 1111,
        "port": 8765,
        "model": "mlx-community/Qwen2.5-7B-Instruct-4bit",
        "spawned_at": time.time(),
    }
    payload.update(overrides)
    path.write_text(json.dumps(payload), encoding="utf-8")
    return path


def test_write_marker_round_trips_and_is_owner_readable_only(tmp_path: Path) -> None:
    local_server.write_marker(pid=4242, port=8765, model="some/model", home=tmp_path)
    marker = local_server.read_marker(tmp_path)
    assert marker is not None
    assert marker["pid"] == 4242
    assert marker["port"] == 8765
    assert marker["model"] == "some/model"
    assert marker["owner_pid"] > 0
    # The marker names a killable pid; keep it off other users' eyes (SEC11 posture).
    assert local_server.marker_path(tmp_path).stat().st_mode & 0o777 == 0o600


def test_no_marker_is_not_an_orphan(tmp_path: Path) -> None:
    assert local_server.orphaned_server(tmp_path) is None
    assert local_server.reap_orphan(tmp_path) is None


def test_live_owner_means_not_an_orphan(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    # An `mp` is mid-summarize. Its own close() will reap the server; touching it
    # here would kill a summary in flight.
    _write(tmp_path)
    _fake_process_table(monkeypatch, {4242: _SERVER_CMD, 1111: _MP_CMD})
    assert local_server.orphaned_server(tmp_path) is None


def test_dead_owner_with_live_server_is_an_orphan(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _write(tmp_path)
    _fake_process_table(monkeypatch, {4242: _SERVER_CMD})  # owner 1111 is gone
    orphan = local_server.orphaned_server(tmp_path)
    assert orphan is not None
    assert orphan["pid"] == 4242


def test_dead_server_clears_the_stale_marker(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # The server died on its own. The marker is a ghost; doctor must not report it.
    _write(tmp_path)
    _fake_process_table(monkeypatch, {})
    assert local_server.orphaned_server(tmp_path) is None
    assert not local_server.marker_path(tmp_path).exists()


def test_recycled_server_pid_is_not_killed(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # The pid was reused by something else entirely. Signalling it would be a bug
    # with real consequences, so the identity check, not liveness, is the gate.
    _write(tmp_path)
    _fake_process_table(monkeypatch, {4242: "/Applications/Safari.app/Contents/MacOS/Safari"})
    assert local_server.orphaned_server(tmp_path) is None
    assert not local_server.marker_path(tmp_path).exists()


def test_recycled_owner_pid_does_not_hide_an_orphan(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # The owner's pid now belongs to some unrelated process. That is not a live
    # `mp`, so the server is still an orphan.
    _write(tmp_path)
    _fake_process_table(monkeypatch, {4242: _SERVER_CMD, 1111: "/usr/sbin/cupsd -l"})
    assert local_server.orphaned_server(tmp_path) is not None


def test_malformed_marker_is_cleared_not_crashed(tmp_path: Path) -> None:
    path = local_server.marker_path(tmp_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("{not json", encoding="utf-8")
    assert local_server.read_marker(tmp_path) is None
    assert local_server.orphaned_server(tmp_path) is None


def test_marker_without_pids_is_cleared(tmp_path: Path) -> None:
    _write(tmp_path, pid="nope")
    assert local_server.orphaned_server(tmp_path) is None
    assert not local_server.marker_path(tmp_path).exists()


def test_reap_orphan_signals_the_group_then_clears_the_marker(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _write(tmp_path)
    table = {4242: _SERVER_CMD}
    _fake_process_table(monkeypatch, table)
    monkeypatch.setattr(local_server.os, "getpgid", lambda pid: pid)

    signalled: list[tuple[int, int]] = []

    def _killpg(pgid: int, sig: int) -> None:
        signalled.append((pgid, sig))
        table.pop(4242, None)  # the server exits on SIGTERM

    monkeypatch.setattr(local_server.os, "killpg", _killpg)
    monkeypatch.setattr(local_server.time, "sleep", lambda _s: None)

    reaped = local_server.reap_orphan(tmp_path)
    assert reaped is not None and reaped["pid"] == 4242
    assert signalled == [(4242, local_server.signal.SIGTERM)]
    assert not local_server.marker_path(tmp_path).exists()


def test_reap_orphan_escalates_to_sigkill_when_sigterm_is_ignored(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _write(tmp_path)
    _fake_process_table(monkeypatch, {4242: _SERVER_CMD})  # never exits
    monkeypatch.setattr(local_server.os, "getpgid", lambda pid: pid)
    signalled: list[int] = []
    monkeypatch.setattr(local_server.os, "killpg", lambda pgid, sig: signalled.append(sig))
    monkeypatch.setattr(local_server.time, "sleep", lambda _s: None)

    local_server.reap_orphan(tmp_path)
    assert signalled == [local_server.signal.SIGTERM, local_server.signal.SIGKILL]
    assert not local_server.marker_path(tmp_path).exists()
