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


# ---------------------------------------------------------------------------
# LOCAL11: served identity
#
# The seam is the same one the marker tests use, plus `listening_pid`. Nothing
# runs `lsof` or `ps` for real: `served_identity` is the composition of those two
# lookups with a pure argv parse, so faking both covers every branch.
# ---------------------------------------------------------------------------

_ADAPTER_CMD = (
    "/opt/homebrew/bin/mlx_lm.server --model mlx-community/Qwen2.5-7B-Instruct-4bit "
    "--host 127.0.0.1 --port 8765 --adapter-path /adapters/lora-2026-07"
)


def _fake_listener(monkeypatch: pytest.MonkeyPatch, pid: int | None) -> None:
    monkeypatch.setattr(local_server, "listening_pid", lambda _port: pid)


def test_parse_identity_reads_model_and_adapter() -> None:
    assert local_server.parse_identity(_ADAPTER_CMD) == (
        "mlx-community/Qwen2.5-7B-Instruct-4bit", "/adapters/lora-2026-07",
    )


def test_parse_identity_reports_no_adapter_as_none() -> None:
    model, adapter = local_server.parse_identity(_SERVER_CMD)
    assert model == "mlx-community/Qwen2.5-7B-Instruct-4bit"
    assert adapter is None


def test_parse_identity_keeps_a_spaced_adapter_path_whole() -> None:
    # Adapter paths are user-chosen and land under "Application Support" often
    # enough that splitting the command line on whitespace would truncate them.
    cmd = (
        "mlx_lm.server --model some/model --port 8765 "
        "--adapter-path /Users/me/Library/Application Support/MeetingPipe/lora"
    )
    assert local_server.parse_identity(cmd)[1] == (
        "/Users/me/Library/Application Support/MeetingPipe/lora"
    )


def test_parse_identity_returns_none_for_an_unrecognised_argv() -> None:
    # A server someone started by hand with a config file rather than --model.
    assert local_server.parse_identity("mlx_lm.server --config /tmp/s.yaml") == (None, None)


def test_served_identity_reads_the_listening_process_argv(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _fake_listener(monkeypatch, 4242)
    _fake_process_table(monkeypatch, {4242: _ADAPTER_CMD})

    identity = local_server.served_identity(8765, tmp_path)
    assert identity is not None
    assert identity.source == "argv"
    assert identity.model == "mlx-community/Qwen2.5-7B-Instruct-4bit"
    assert identity.adapter_path == "/adapters/lora-2026-07"


def test_served_identity_covers_a_server_we_never_spawned(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # The daemon's warm `mp serve-local` writes no marker; argv is the only thing
    # that can name it, which is the whole reason identity is read from `ps`.
    _fake_listener(monkeypatch, 4242)
    _fake_process_table(monkeypatch, {4242: _SERVER_CMD})
    assert local_server.read_marker(tmp_path) is None

    identity = local_server.served_identity(8765, tmp_path)
    assert identity is not None and identity.source == "argv"


def test_served_identity_falls_back_to_the_marker_without_lsof(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _write(tmp_path, adapter_path="/adapters/lora-2026-07")
    _fake_listener(monkeypatch, None)
    _fake_process_table(monkeypatch, {4242: _SERVER_CMD})

    identity = local_server.served_identity(8765, tmp_path)
    assert identity is not None
    assert identity.source == "marker"
    assert identity.adapter_path == "/adapters/lora-2026-07"


def test_served_identity_ignores_a_marker_for_another_port(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _write(tmp_path, port=9999)
    _fake_listener(monkeypatch, None)
    _fake_process_table(monkeypatch, {4242: _SERVER_CMD})
    assert local_server.served_identity(8765, tmp_path) is None


def test_served_identity_is_none_when_a_non_server_holds_the_port(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _fake_listener(monkeypatch, 4242)
    _fake_process_table(monkeypatch, {4242: "/usr/bin/python3 -m http.server 8765"})
    assert local_server.served_identity(8765, tmp_path) is None


def test_identity_matches_on_model_and_adapter() -> None:
    identity = local_server.ServedIdentity(
        pid=1, model="a/b", adapter_path="/lora", source="argv",
    )
    assert identity.matches(model="a/b", adapter_path="/lora")
    assert not identity.matches(model="a/b", adapter_path="")
    assert not identity.matches(model="c/d", adapter_path="/lora")


def test_identity_treats_none_and_empty_adapter_as_the_same_base_model() -> None:
    identity = local_server.ServedIdentity(pid=1, model="a/b", adapter_path=None, source="argv")
    assert identity.matches(model="a/b", adapter_path="")
    assert identity.matches(model="a/b", adapter_path=None)


def test_unreadable_identity_never_reports_a_mismatch() -> None:
    # Fail open: a `ps` line we could not parse is not evidence of a mismatch, and
    # respawning on it would cost a multi-GB model reload for nothing.
    identity = local_server.ServedIdentity(pid=1, model=None, adapter_path=None, source="argv")
    assert identity.matches(model="anything/at-all", adapter_path="/lora")


def test_terminate_server_refuses_a_recycled_pid(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _write(tmp_path)
    _fake_process_table(monkeypatch, {4242: "/usr/bin/vim notes.txt"})
    monkeypatch.setattr(local_server.os, "killpg", _never_called)

    assert local_server.terminate_server(4242, tmp_path) is False
    # The marker described a server that no longer exists, so it goes too.
    assert not local_server.marker_path(tmp_path).exists()


def _never_called(*_args: object, **_kwargs: object) -> None:
    raise AssertionError("a pid that is not an mlx_lm.server must never be signalled")
