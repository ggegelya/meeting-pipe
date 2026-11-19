"""T12: the suite's result does not depend on the developer's machine. Pins the
conftest stubs: no developer config, no Keychain, no network."""
from __future__ import annotations

import socket
import subprocess
from pathlib import Path

import pytest

from mp import config
from mp.config import Config

from .conftest import _NETWORK


def test_config_load_under_the_suite_returns_defaults_whatever_the_real_file_holds():
    real = Path("~/.config/meeting-pipe/config.toml").expanduser()
    assert real != config.CONFIG_PATH
    assert not config.CONFIG_PATH.exists()
    assert Config.load().model_dump() == Config().model_dump()


def test_load_secrets_never_spawns_security(monkeypatch: pytest.MonkeyPatch):
    for key in config.MANAGED_SECRET_KEYS:
        monkeypatch.delenv(key, raising=False)
    monkeypatch.setattr("mp.egress_guard.is_armed", lambda: False)
    spawned: list[object] = []
    monkeypatch.setattr(subprocess, "run", lambda *a, **k: spawned.append(a) or pytest.fail("spawned"))
    config._ABSENT_SECRETS.clear()
    config.load_secrets()
    assert spawned == []


def test_a_public_name_is_refused_and_loopback_is_not():
    with pytest.raises(pytest.fail.Exception, match="leaves the machine"):
        socket.getaddrinfo("example.com", 443)
    assert socket.getaddrinfo("127.0.0.1", 80)
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        with pytest.raises(pytest.fail.Exception, match="leaves the machine"):
            s.connect(("93.184.216.34", 443))
    # Both were refused and recorded; clear the record, which otherwise (rightly)
    # fails the test at teardown as a swallowed refusal.
    assert len(_NETWORK["blocked"]) == 2
    _NETWORK["blocked"].clear()
