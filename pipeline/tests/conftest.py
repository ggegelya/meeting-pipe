"""Shared pytest fixtures for the pipeline suite."""
from __future__ import annotations

import pytest

from mp import egress_guard


@pytest.fixture(autouse=True)
def _reset_egress_guard():
    """The egress guard is process-global state (TECH-SEC3). Disarm it after
    every test so a test that arms it (directly or through an entry point that
    resolves a regulated/NDA config) cannot block httpx for later tests."""
    yield
    egress_guard.disarm()
