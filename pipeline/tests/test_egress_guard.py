"""Tests for the process-wide HTTP egress firewall (TECH-SEC3).

These drive real `httpx.Client` / `httpx.AsyncClient` instances through the
default transport (the path the Anthropic SDK and the Notion publisher take),
but stub the guard's downstream (`_orig_sync` / `_orig_async`) so a permitted
request lands on a fake instead of a real socket. The block path short-circuits
before the transport, so it never opens a connection either.
"""
from __future__ import annotations

import asyncio
from typing import Any

import httpx
import pytest

from mp import egress_guard
from mp.config import Config
from mp.egress_guard import EgressBlocked


def _ok(self: Any, request: httpx.Request) -> httpx.Response:
    return httpx.Response(200, request=request, json={"ok": True})


def test_blocks_non_loopback_when_armed(monkeypatch: pytest.MonkeyPatch) -> None:
    egress_guard.arm("test")
    # If the guard were to fall through, this would fail the test loudly rather
    # than make a real request.
    monkeypatch.setattr(egress_guard, "_orig_sync",
                        lambda s, r: pytest.fail("egress reached the transport"))
    assert egress_guard.is_armed()
    with httpx.Client() as client, pytest.raises(EgressBlocked):
        client.get("https://api.notion.com/v1/search")


def test_blocks_non_loopback_async_when_armed(monkeypatch: pytest.MonkeyPatch) -> None:
    egress_guard.arm("test")
    monkeypatch.setattr(egress_guard, "_orig_async",
                        lambda s, r: pytest.fail("async egress reached the transport"))

    async def _go() -> None:
        async with httpx.AsyncClient() as client:
            await client.get("https://api.anthropic.com/v1/messages")

    with pytest.raises(EgressBlocked):
        asyncio.run(_go())


def test_loopback_passes_through_when_armed(monkeypatch: pytest.MonkeyPatch) -> None:
    egress_guard.arm("test")
    monkeypatch.setattr(egress_guard, "_orig_sync", _ok)
    with httpx.Client() as client:
        resp = client.get("http://127.0.0.1:8765/v1/health")
    assert resp.status_code == 200  # the local model endpoint is never blocked


def test_disarmed_passes_everything_through(monkeypatch: pytest.MonkeyPatch) -> None:
    egress_guard.arm("test")
    egress_guard.disarm()
    assert not egress_guard.is_armed()
    monkeypatch.setattr(egress_guard, "_orig_sync", _ok)
    # Disarmed: even a non-loopback host reaches the transport (no EgressBlocked).
    with httpx.Client() as client:
        resp = client.get("https://api.notion.com/v1/search")
    assert resp.status_code == 200


def test_is_loopback_classification() -> None:
    assert egress_guard._is_loopback("127.0.0.1")
    assert egress_guard._is_loopback("localhost")
    assert egress_guard._is_loopback("::1")
    assert not egress_guard._is_loopback("api.notion.com")
    assert not egress_guard._is_loopback("10.0.0.5")
    assert not egress_guard._is_loopback("")
    assert not egress_guard._is_loopback(None)


def test_arm_for_config_arms_under_regulated() -> None:
    cfg = Config.model_validate({"modes": {"regulated_mode": True}})
    assert egress_guard.arm_for_config(cfg) is True
    assert egress_guard.is_armed()


def test_arm_for_config_arms_under_workflow_nda() -> None:
    cfg = Config.model_validate({"modes": {"workflow_nda_mode": True}})
    assert egress_guard.arm_for_config(cfg) is True
    assert egress_guard.is_armed()


def test_arm_for_config_noop_when_unrestricted() -> None:
    cfg = Config()
    assert egress_guard.arm_for_config(cfg) is False
    assert not egress_guard.is_armed()
