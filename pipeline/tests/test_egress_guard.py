"""Tests for the process-wide egress firewall (TECH-SEC3, hardened by SEC13).

These drive real `httpx.Client` / `httpx.AsyncClient` instances through the
default transport (the path the Anthropic SDK and the Notion publisher take),
but stub the guard's downstream (`_orig_sync` / `_orig_async`) so a permitted
request lands on a fake instead of a real socket. The block path short-circuits
before the transport, so it never opens a connection either.

The SEC13 tests below cover the two layers httpx cannot see: the process
environment (which the `mlx_lm.server` child inherits) and the huggingface_hub
`requests` stack (which the transport patch never touches).
"""
from __future__ import annotations

import asyncio
import os
from typing import Any

import httpx
import pytest

from mp import egress_guard
from mp.config import MANAGED_SECRET_KEYS, Config, load_secrets
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


# ----- SEC13: the process boundary -----


def test_arm_scrubs_cloud_tokens_from_the_environment(monkeypatch: pytest.MonkeyPatch) -> None:
    for key in MANAGED_SECRET_KEYS:
        monkeypatch.setenv(key, "secret-value")
    egress_guard.arm("test")
    for key in MANAGED_SECRET_KEYS:
        assert key not in os.environ, f"{key} survived arm()"


def test_arm_forces_huggingface_offline(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("HF_HUB_OFFLINE", raising=False)
    egress_guard.arm("test")
    # mlx_embeddings / mlx_lm.server reach huggingface_hub over `requests`, which
    # the httpx transport patch never sees. The env is the only lever.
    assert os.environ["HF_HUB_OFFLINE"] == "1"
    assert os.environ["HF_HUB_DISABLE_TELEMETRY"] == "1"


def test_arm_rescrubs_on_every_call(monkeypatch: pytest.MonkeyPatch) -> None:
    """The httpx patch installs once and `arm()` early-returns after it, but the
    scrub must not be behind that early return: a caller can load secrets between
    two arms."""
    egress_guard.arm("first")
    monkeypatch.setenv("ANTHROPIC_API_KEY", "leaked-back-in")
    egress_guard.arm("second")
    assert "ANTHROPIC_API_KEY" not in os.environ


def test_child_env_is_scrubbed_when_armed() -> None:
    base = {"PATH": "/usr/bin", "ANTHROPIC_API_KEY": "k", "NOTION_TOKEN": "t", "HF_TOKEN": "h"}
    egress_guard.arm("test")
    env = egress_guard.child_env(base)
    assert env["PATH"] == "/usr/bin"
    assert "ANTHROPIC_API_KEY" not in env
    assert "NOTION_TOKEN" not in env
    assert "HF_TOKEN" not in env
    assert env["HF_HUB_OFFLINE"] == "1"
    # The caller's dict is never mutated.
    assert base["ANTHROPIC_API_KEY"] == "k"


def test_child_env_passes_through_when_disarmed() -> None:
    base = {"PATH": "/usr/bin", "ANTHROPIC_API_KEY": "k"}
    assert not egress_guard.is_armed()
    assert egress_guard.child_env(base) == base


def test_load_secrets_refills_when_disarmed(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    load_secrets(reader=lambda key: f"from-keychain-{key}")
    assert os.environ["ANTHROPIC_API_KEY"] == "from-keychain-ANTHROPIC_API_KEY"


def test_load_secrets_declines_to_refill_when_armed(monkeypatch: pytest.MonkeyPatch) -> None:
    """SEC13(b): the daemon strips the tokens for a zero-egress run (SEC5) and
    `load_secrets` used to hand them straight back from the Keychain, collapsing
    defense-in-depth to the single httpx layer."""
    monkeypatch.delenv("NOTION_TOKEN", raising=False)
    egress_guard.arm("test")
    load_secrets(reader=lambda key: pytest.fail("keychain read under a zero-egress run"))
    assert "NOTION_TOKEN" not in os.environ
