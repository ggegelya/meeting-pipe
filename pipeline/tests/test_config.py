"""Tests for config secrets handling (SEC8 Keychain) and the effective-config
chokepoint (TECH-ARCH1)."""
from __future__ import annotations

import json
import logging
import os
from pathlib import Path

import pytest
from pydantic import ValidationError

from mp import config as config_mod
from mp.config import (
    Config,
    ConfigError,
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


def test_effective_sinks_is_filesystem_only_under_zero_egress() -> None:
    # SEC18: one rule on both paths. Obsidian, LAN and Notion all drop, the same
    # collapse `workflow.apply_overrides` always applied on the sidecar path.
    for mode in ("regulated_mode", "workflow_nda_mode"):
        for sinks in (["notion", "obsidian", "filesystem"], ["obsidian"], ["notion", "lan"], []):
            cfg = Config.model_validate({"output": {"sinks": sinks}, "modes": {mode: True}})
            assert effective_sinks(cfg) == ["filesystem"]


def test_effective_sinks_passthrough_preserves_order_when_unrestricted() -> None:
    cfg = Config.model_validate({"output": {"sinks": ["filesystem", "notion", "obsidian"]}})
    assert effective_sinks(cfg) == ["filesystem", "notion", "obsidian"]


# --- PIPE42: a misplaced section fails closed, unknown keys warn, sinks are validated at load ---


@pytest.fixture
def isolated(monkeypatch, tmp_path: Path) -> Path:
    """A logs dir of our own, and a fresh per-process warn-once memory."""
    logs = tmp_path / "logs"
    logs.mkdir()
    monkeypatch.setenv("MEETINGPIPE_LOGS_DIR", str(logs))
    monkeypatch.setattr(config_mod, "_WARNED_UNKNOWN", set())
    return logs


def _write(tmp_path: Path, text: str) -> Path:
    path = tmp_path / "config.toml"
    path.write_text(text, encoding="utf-8")
    return path


def _events(logs: Path, action: str) -> list[dict]:
    path = logs / "pipeline_events.jsonl"
    if not path.exists():
        return []
    rows = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    return [r for r in rows if r.get("action") == action]


@pytest.mark.parametrize("last_table", ["[transcription]\nlanguage = \"auto\"", "[mcp]\nenabled = false"])
def test_a_regulated_switch_appended_under_the_last_table_refuses_to_load(
    tmp_path: Path, isolated: Path, last_table: str
) -> None:
    # The README names the switch `modes.regulated_mode = true`; appended to the
    # end of a file, TOML binds the dotted key to whatever table is open last.
    path = _write(tmp_path, f"{last_table}\nmodes.regulated_mode = true\n")
    section = last_table.split("]")[0].lstrip("[")
    with pytest.raises(ConfigError, match=rf"{section}\.modes"):
        Config.load(path)


def test_a_section_nested_inside_an_array_of_tables_refuses_to_load(tmp_path: Path, isolated: Path) -> None:
    path = _write(
        tmp_path,
        '[[summarization.extra_sections]]\nname = "Risks"\ninstruction = "List them"\nmodes.regulated_mode = true\n',
    )
    with pytest.raises(ConfigError, match="modes"):
        Config.load(path)


def test_a_top_level_modes_table_still_loads_regulated(tmp_path: Path, isolated: Path) -> None:
    path = _write(tmp_path, "[transcription]\nlanguage = \"auto\"\n\n[modes]\nregulated_mode = true\n")
    assert Config.load(path).modes.regulated_mode is True


@pytest.mark.parametrize("literal", ['"true"', '"false"', "1", "0"])
def test_a_regulated_switch_that_is_not_a_boolean_refuses_to_load(
    tmp_path: Path, isolated: Path, literal: str
) -> None:
    # Pydantic's lax mode read "true" and 1 as True and "false" as False, while the
    # Swift store read every one of them as false and then saved false over it.
    path = _write(tmp_path, f"[modes]\nregulated_mode = {literal}\n")
    with pytest.raises(ValidationError):
        Config.load(path)


def test_an_unknown_summarization_key_loads_with_defaults_warns_once_and_emits(
    tmp_path: Path, isolated: Path, caplog
) -> None:
    path = _write(tmp_path, '[summarization]\nbackedn = "local"\n')
    with caplog.at_level(logging.WARNING, logger="mp.config"):
        cfg = Config.load(path)
        Config.load(path)   # a second load in the same run says nothing new
    assert cfg.summarization.backend == "anthropic"
    assert len([r for r in caplog.records if "backedn" in r.getMessage()]) == 1
    rows = _events(isolated, "config_unknown_key")
    assert [(r["category"], r["section"], r["key"]) for r in rows] == [("pipeline", "summarization", "backedn")]
    assert cfg.unknown_keys == [("summarization", "backedn")]


def test_an_unknown_top_level_key_warns_and_emits(tmp_path: Path, isolated: Path, caplog) -> None:
    path = _write(tmp_path, "sinks = [\"obsidian\"]\n")
    with caplog.at_level(logging.WARNING, logger="mp.config"):
        cfg = Config.load(path)
    assert cfg.output.sinks == ["notion"]
    assert any("sinks" in r.getMessage() for r in caplog.records)
    rows = _events(isolated, "config_unknown_key")
    assert [(r["section"], r["key"]) for r in rows] == [("top_level", "sinks")]


def test_a_regulated_switch_above_every_table_refuses_to_load(tmp_path: Path, isolated: Path) -> None:
    path = _write(tmp_path, "regulated_mode = true\n\n[modes]\n")
    with pytest.raises(ConfigError, match="above every table"):
        Config.load(path)


def test_a_switch_appended_after_a_last_modes_table_refuses_to_load(tmp_path: Path, isolated: Path) -> None:
    # Before AUTO3 added [mcp], config.example.toml ended with [modes].
    path = _write(tmp_path, "[modes]\nregulated_mode = false\nmodes.regulated_mode = true\n")
    with pytest.raises(ConfigError, match="modes.modes"):
        Config.load(path)


def test_legacy_keys_in_the_tolerant_sections_say_nothing(tmp_path: Path, isolated: Path, caplog) -> None:
    path = _write(
        tmp_path,
        '[recording]\ncapture_mode = "both"\n\n[transcription]\nmodel = "large-v3"\n\n'
        '[detection]\nmanual_hotkey = "ctrl+option+m"\n',
    )
    with caplog.at_level(logging.WARNING, logger="mp.config"):
        cfg = Config.load(path)
    assert cfg.unknown_keys == []
    assert not caplog.records
    assert _events(isolated, "config_unknown_key") == []


def test_a_misspelt_sink_fails_at_load(tmp_path: Path, isolated: Path) -> None:
    path = _write(tmp_path, '[output]\nsinks = ["obsidan"]\n')
    with pytest.raises(ValidationError, match="obsidan"):
        Config.load(path)


def test_known_sinks_load(tmp_path: Path, isolated: Path) -> None:
    path = _write(tmp_path, '[output]\nsinks = ["obsidian", "filesystem", "lan", "notion"]\n')
    assert Config.load(path).output.sinks == ["obsidian", "filesystem", "lan", "notion"]


def test_the_sink_vocabulary_matches_what_the_router_builds() -> None:
    import ast
    import inspect
    import typing

    from mp import publish_router

    source = inspect.getsource(publish_router._build_one)
    compared = {
        node.comparators[0].value
        for node in ast.walk(ast.parse(source))
        if isinstance(node, ast.Compare)
        and isinstance(node.left, ast.Name) and node.left.id == "name"
        and isinstance(node.comparators[0], ast.Constant)
    }
    assert set(typing.get_args(config_mod.SinkName)) == compared
