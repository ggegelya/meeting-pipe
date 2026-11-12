"""Shared pytest fixtures for the pipeline suite."""
from __future__ import annotations

import os
import signal

import pytest

from mp import egress_guard, resource_guard
from mp.config import MANAGED_SECRET_KEYS


@pytest.fixture(autouse=True)
def _disable_memory_guard(monkeypatch):
    """LOCAL16: the memory guard reads the REAL machine (physical RAM, and free
    RAM via `vm_stat`), so leaving it live would let an unrelated local-client
    test fail because the developer's Mac happened to be under pressure, or
    because a CI runner is smaller than the model the fixture names.

    Off for the suite by default, and the two files that exist to test it
    (`test_resource_guard.py`, the LOCAL16 cases in `test_summarize_local.py`)
    turn it back on deliberately and pass an explicit `ram_gb`.
    """
    monkeypatch.setenv(resource_guard.OVERRIDE_ENV, "0")


@pytest.fixture(autouse=True)
def _reset_egress_guard():
    """The egress guard is process-global state (TECH-SEC3). Disarm it after
    every test so a test that arms it (directly or through an entry point that
    resolves a regulated/NDA config) cannot block httpx for later tests.

    SEC13 gave `arm()` a second global effect: it pops the managed cloud tokens
    out of `os.environ` and forces the HF offline flags in. Snapshot and restore
    those too, or one armed test strips the developer's exported
    ANTHROPIC_API_KEY for every test that runs after it.
    """
    watched = (*MANAGED_SECRET_KEYS, "HF_HUB_OFFLINE", "HF_HUB_DISABLE_TELEMETRY")
    before = {k: os.environ.get(k) for k in watched}
    yield
    egress_guard.disarm()
    for key, value in before.items():
        if value is None:
            os.environ.pop(key, None)
        else:
            os.environ[key] = value


@pytest.fixture(autouse=True)
def _restore_sigterm_disposition():
    """`mp.__main__.main` installs a process-wide SIGTERM handler (PIPE22), and
    in-process tests call `main()`. Put back whatever pytest had, so a test that
    drove the router cannot leave the whole suite turning SIGTERM into a
    `SystemExit` in whichever test happens to be running when one arrives."""
    before = signal.getsignal(signal.SIGTERM)
    yield
    signal.signal(signal.SIGTERM, before)


@pytest.fixture(autouse=True)
def _private_server_marker(monkeypatch, tmp_path_factory):
    """`local_server.marker_path()` defaults to the real `~/Library/Logs/
    MeetingPipe/mlx-server.json`, and `LocalSummaryClient` calls it with no
    `home`, so any test that spawns, closes, or reuses a server through the
    client wrote, rewrote or deleted the developer's live marker, the one the
    daemon's reaper acts on. Default it to a per-test directory; a test that
    passes `home` explicitly still gets exactly the path it asked for (PIPE22)."""
    from mp import local_server

    home = tmp_path_factory.mktemp("marker-home")
    real = local_server.marker_path
    monkeypatch.setattr(local_server, "marker_path", lambda h=None: real(h or home))
