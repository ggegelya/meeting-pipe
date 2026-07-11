"""Tests for config secrets handling (SEC8 Keychain) and the effective-config
chokepoint (TECH-ARCH1)."""
from __future__ import annotations

import os

from mp.config import (
    Config,
    effective_backend,
    effective_sinks,
    load_secrets,
    zero_egress,
)


# --- SEC8: load_secrets reads the managed tokens from the Keychain (via an injected reader) ---


def test_load_secrets_fills_missing_from_keychain(monkeypatch) -> None:
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    monkeypatch.delenv("NOTION_TOKEN", raising=False)
    kc = {"ANTHROPIC_API_KEY": "sk-kc", "NOTION_TOKEN": "ntn-kc"}
    load_secrets(reader=lambda account: kc.get(account))
    assert os.environ["ANTHROPIC_API_KEY"] == "sk-kc"
    assert os.environ["NOTION_TOKEN"] == "ntn-kc"


def test_load_secrets_keeps_a_real_env_value(monkeypatch) -> None:
    # A token the daemon already injected into the subprocess env must not be clobbered.
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-injected")
    load_secrets(reader=lambda account: "sk-should-not-win")
    assert os.environ["ANTHROPIC_API_KEY"] == "sk-injected"


def test_load_secrets_treats_empty_env_as_missing(monkeypatch) -> None:
    # Claude Code exports ANTHROPIC_API_KEY="" (empty); the Keychain value must still win.
    monkeypatch.setenv("ANTHROPIC_API_KEY", "")
    load_secrets(reader=lambda account: "sk-kc" if account == "ANTHROPIC_API_KEY" else None)
    assert os.environ["ANTHROPIC_API_KEY"] == "sk-kc"


# --- TECH-ARCH1 / SEC13: zero_egress is the single owner of the clamp predicate ---


def test_zero_egress_is_true_for_regulated_and_for_nda() -> None:
    assert zero_egress(Config.model_validate({"modes": {"regulated_mode": True}}))
    assert zero_egress(Config.model_validate({"modes": {"workflow_nda_mode": True}}))


def test_zero_egress_is_false_by_default() -> None:
    assert not zero_egress(Config())


# --- TECH-ARCH1: effective_backend / effective_sinks chokepoint ---


def test_effective_backend_regulated_forces_local() -> None:
    # PROV1: the CLI (claude_cli) and API (openai) cloud backends are forced
    # local too, so a regulated run never selects them.
    for configured in ("anthropic", "auto", "apple_intelligence", "claude_cli", "openai"):
        cfg = Config.model_validate({
            "summarization": {"backend": configured},
            "modes": {"regulated_mode": True},
        })
        assert effective_backend(cfg) == "local"


def test_effective_backend_nda_forces_local() -> None:
    for configured in ("anthropic", "auto", "apple_intelligence", "claude_cli", "openai"):
        cfg = Config.model_validate({
            "summarization": {"backend": configured},
            "modes": {"workflow_nda_mode": True},
        })
        assert effective_backend(cfg) == "local"


def test_effective_backend_passthrough_when_unrestricted() -> None:
    # Apple Intelligence and auto must survive when no zero-egress mode is on;
    # the per-call-site collapse (apple->daemon, auto->fallback) happens later.
    for configured in ("anthropic", "auto", "apple_intelligence", "local", "claude_cli", "openai"):
        cfg = Config.model_validate({"summarization": {"backend": configured}})
        assert effective_backend(cfg) == configured


def test_cli_backends_are_a_subset_of_backends_and_cloud() -> None:
    # PROV1: claude_cli is a valid backend AND classed as a CLI (cloud) backend,
    # so effective_backend's non-local force-local rule catches it.
    from mp.config import BACKENDS, CLI_BACKENDS

    assert {"claude_cli", "openai"} <= BACKENDS
    assert "claude_cli" in CLI_BACKENDS
    assert CLI_BACKENDS <= BACKENDS
    assert "local" not in CLI_BACKENDS


def test_effective_sinks_drops_notion_under_zero_egress() -> None:
    for mode in ("regulated_mode", "workflow_nda_mode"):
        cfg = Config.model_validate({
            "output": {"sinks": ["notion", "obsidian", "filesystem"]},
            "modes": {mode: True},
        })
        assert effective_sinks(cfg) == ["obsidian", "filesystem"]


def test_effective_sinks_passthrough_preserves_order_when_unrestricted() -> None:
    cfg = Config.model_validate({"output": {"sinks": ["filesystem", "notion", "obsidian"]}})
    assert effective_sinks(cfg) == ["filesystem", "notion", "obsidian"]
