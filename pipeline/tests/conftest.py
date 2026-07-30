"""Shared pytest fixtures for the pipeline suite."""
from __future__ import annotations

import os

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
