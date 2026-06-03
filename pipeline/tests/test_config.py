"""Tests for config secrets handling (TECH-SEC1) and the effective-config
chokepoint (TECH-ARCH1)."""
from __future__ import annotations

import os
from pathlib import Path

from mp.config import (
    Config,
    _secrets_too_open,
    effective_backend,
    effective_sinks,
)


def test_secrets_too_open_flags_group_or_other_readable(tmp_path: Path) -> None:
    p = tmp_path / "secrets.env"
    p.write_text("NOTION_TOKEN=x\n", encoding="utf-8")
    os.chmod(p, 0o644)
    assert _secrets_too_open(p) is True
    os.chmod(p, 0o640)  # group-read only is still too open
    assert _secrets_too_open(p) is True


def test_secrets_0600_is_not_too_open(tmp_path: Path) -> None:
    p = tmp_path / "secrets.env"
    p.write_text("NOTION_TOKEN=x\n", encoding="utf-8")
    os.chmod(p, 0o600)
    assert _secrets_too_open(p) is False


def test_secrets_missing_file_is_not_flagged(tmp_path: Path) -> None:
    assert _secrets_too_open(tmp_path / "nope.env") is False


# --- TECH-ARCH1: effective_backend / effective_sinks chokepoint ---


def test_effective_backend_regulated_forces_local() -> None:
    for configured in ("anthropic", "auto", "apple_intelligence"):
        cfg = Config.model_validate({
            "summarization": {"backend": configured},
            "modes": {"regulated_mode": True},
        })
        assert effective_backend(cfg) == "local"


def test_effective_backend_nda_forces_local() -> None:
    for configured in ("anthropic", "auto", "apple_intelligence"):
        cfg = Config.model_validate({
            "summarization": {"backend": configured},
            "modes": {"workflow_nda_mode": True},
        })
        assert effective_backend(cfg) == "local"


def test_effective_backend_passthrough_when_unrestricted() -> None:
    # Apple Intelligence and auto must survive when no zero-egress mode is on;
    # the per-call-site collapse (apple->daemon, auto->fallback) happens later.
    for configured in ("anthropic", "auto", "apple_intelligence", "local"):
        cfg = Config.model_validate({"summarization": {"backend": configured}})
        assert effective_backend(cfg) == configured


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
