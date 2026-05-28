"""Tests for the TECH-A15 local-backend surfaces: the shared server-command
builder, the loopback clamp, the `mp serve-local` warm entry point, and the
`mp summarize --print-prompt` read-only prompt surface."""
from __future__ import annotations

import types

import pytest

import mp.config as config_mod
from mp.summarize import _load_system_prompt, _summary_language_directive
from mp.summarize_local import (
    DEFAULT_HOST,
    _loopback_only,
    build_server_command,
    main as serve_local_main,
)


def test_build_server_command_appends_model_host_port():
    cmd = build_server_command("mlx-community/Qwen2.5-3B-Instruct-4bit", "127.0.0.1", 8765)
    assert cmd[-6:] == [
        "--model", "mlx-community/Qwen2.5-3B-Instruct-4bit",
        "--host", "127.0.0.1",
        "--port", "8765",
    ]
    # Either the standalone entry point or `python -m mlx_lm.server`.
    assert "mlx_lm.server" in " ".join(cmd)


def test_loopback_clamp_keeps_loopback_and_rewrites_public():
    assert _loopback_only("127.0.0.1") == "127.0.0.1"
    assert _loopback_only("localhost") == "localhost"
    assert _loopback_only("0.0.0.0") == DEFAULT_HOST
    assert _loopback_only("192.168.1.5") == DEFAULT_HOST


class _ExecCalled(Exception):
    """Sentinel so the test can intercept execvp without replacing the process."""


def test_serve_local_execs_server_for_configured_model(monkeypatch):
    captured: dict[str, object] = {}

    def fake_execvp(file, args):
        captured["file"] = file
        captured["args"] = list(args)
        raise _ExecCalled()

    fake_cfg = types.SimpleNamespace(
        summarization=types.SimpleNamespace(
            local_model="mlx-community/Custom-7B-4bit",
            # A non-loopback host must be clamped before it reaches execvp.
            local_endpoint="http://0.0.0.0:9999",
        )
    )
    monkeypatch.setattr(config_mod.Config, "load", classmethod(lambda cls: fake_cfg))

    import mp.summarize_local as sl
    monkeypatch.setattr(sl.os, "execvp", fake_execvp)

    with pytest.raises(_ExecCalled):
        serve_local_main([])

    args = captured["args"]
    assert args[-6:] == [
        "--model", "mlx-community/Custom-7B-4bit",
        "--host", DEFAULT_HOST,   # clamped from 0.0.0.0
        "--port", "9999",
    ]


def test_serve_local_help_returns_zero(capsys):
    assert serve_local_main(["--help"]) == 0
    assert "serve-local" in capsys.readouterr().out


def test_print_prompt_substitutes_team_context_and_language():
    rendered = _load_system_prompt("ACME platform team", "en")
    assert "ACME platform team" in rendered
    assert "{team_context}" not in rendered
    assert "{summary_language_directive}" not in rendered


def test_summary_language_directive_auto_vs_forced():
    assert "SAME language" in _summary_language_directive("auto")
    forced = _summary_language_directive("uk")
    assert "`uk`" in forced
