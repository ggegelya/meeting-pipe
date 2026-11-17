"""Shared pytest fixtures for the pipeline suite."""
from __future__ import annotations

import os
import signal

import pytest

from mp import egress_guard, resource_guard
from mp.config import MANAGED_SECRET_KEYS


@pytest.fixture(autouse=True)
def _known_encryption(monkeypatch):
    """STOR8: `mp backup` asks `df` and `diskutil` about the destination's volume.
    Stubbed for the whole suite so no test shells out to them (`diskutil` does not
    exist on the Linux runner); the probe's own tests in `test_backup_restore.py`
    call the real function with an injected runner."""
    from mp import backup

    monkeypatch.setattr(backup, "destination_encrypted", lambda _d: True)


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

    SEC19 added a third: it drops every `*_proxy` variable and sets `NO_PROXY=*`,
    so those are snapshotted by pattern (the names present differ per machine).
    """
    def proxy_keys() -> set[str]:
        return {k for k in os.environ if k.lower().endswith("_proxy")}

    watched = {*MANAGED_SECRET_KEYS, "HF_HUB_OFFLINE", "HF_HUB_DISABLE_TELEMETRY", *proxy_keys()}
    before = {k: os.environ.get(k) for k in watched}
    yield
    for key in proxy_keys() - watched:
        os.environ.pop(key, None)
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


@pytest.fixture(autouse=True)
def _fixed_server_token(monkeypatch, tmp_path_factory):
    """SEC27: the client verifies a model server with the per-spawn token, and
    the real record of it lives in Application Support. Give every test the one
    token the fake servers in `fake_health.py` answer with, so none reads or
    writes the developer's live token file."""
    from mp import local_server

    from .fake_health import TEST_TOKEN

    monkeypatch.setattr(local_server, "read_token", lambda port, home=None: TEST_TOKEN)
    home = tmp_path_factory.mktemp("token-home")
    real_path = local_server.token_path
    monkeypatch.setattr(local_server, "token_path", lambda h=None: real_path(h or home))

    # The fakes listen inside the pytest process, which `lsof` would (correctly)
    # name as a foreign listener (SEC27). Default to "lsof could not say", the
    # situation every fake-server test was written for; the tests of the foreign
    # path and of `served_identity` itself patch their own answers over this.
    monkeypatch.setattr(local_server, "listening_pid", lambda port: None)


@pytest.fixture(autouse=True)
def _fresh_secret_probe_state():
    """`load_secrets` remembers absent and unreadable keys for the life of the process (CONC8, SEC23),
    which is a property of a real run and a leak between tests."""
    from mp import config

    config._ABSENT_SECRETS.clear()
    config._UNREADABLE_SECRETS.clear()
    yield
    config._ABSENT_SECRETS.clear()
    config._UNREADABLE_SECRETS.clear()
