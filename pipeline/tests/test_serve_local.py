"""Tests for the TECH-A15 local-backend surfaces: the shared server-command
builder, the loopback clamp, the `mp serve-local` warm entry point, and the
`mp summarize --print-prompt` read-only prompt surface."""
from __future__ import annotations

import os
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
    snapshot = "/hub/models--mlx-community--Qwen2.5-3B-Instruct-4bit/snapshots/" + "a" * 40
    cmd = build_server_command(snapshot, "127.0.0.1", 8765)
    assert cmd[-6:] == ["--model", snapshot, "--host", "127.0.0.1", "--port", "8765"]
    # SEC27: the hardened shim around mlx-lm's server, under this interpreter.
    assert cmd[1:3] == ["-m", "mp.local_model_server"]


def test_loopback_clamp_keeps_loopback_and_rewrites_public():
    assert _loopback_only("127.0.0.1") == "127.0.0.1"
    assert _loopback_only("localhost") == "localhost"
    assert _loopback_only("0.0.0.0") == DEFAULT_HOST
    assert _loopback_only("192.168.1.5") == DEFAULT_HOST


class _ExecCalled(Exception):
    """Sentinel so the test can intercept execvpe without replacing the process."""


def _pin_snapshot(monkeypatch, *, present: bool = True):
    """SEC27: `serve-local` starts the server on a pinned snapshot directory."""
    from pathlib import Path

    from mp import local_snapshot

    def _resolve(repo_id, home=None):
        if not present:
            raise local_snapshot.SnapshotMissing(
                f"{repo_id} is {local_snapshot.NOT_CACHED_PHRASE}"
            )
        return Path("/hub/models--x/snapshots/" + "b" * 40)

    monkeypatch.setattr("mp.local_snapshot.resolve_for_serving", _resolve)


def _fake_cfg(*, regulated: bool = False, model: str = "mlx-community/Custom-7B-4bit",
              endpoint: str = "http://0.0.0.0:9999") -> types.SimpleNamespace:
    return types.SimpleNamespace(
        # entry.prepare arms the egress guard off `modes` (zero_egress).
        modes=types.SimpleNamespace(regulated_mode=regulated, workflow_nda_mode=False),
        summarization=types.SimpleNamespace(
            local_model=model,
            local_endpoint=endpoint,
            local_adapter_path="",  # LOCAL9: no adapter -> base model served
        ),
    )


@pytest.fixture(autouse=True)
def _restore_stdio_fds():
    """T12: `serve_local_main` runs `_redirect_output_to_server_log` before the
    (faked) exec, which `dup2`s the server log over fds 1 and 2 of the pytest
    process itself. Fd capture happens to re-`dup2` its saved fds afterwards; with
    `-s` the session's own report went into the log. Put both back every time."""
    saved = {fd: os.dup(fd) for fd in (1, 2)}
    try:
        yield
    finally:
        for fd, copy in saved.items():
            os.dup2(copy, fd)
            os.close(copy)


def test_serve_local_execs_server_for_configured_model(monkeypatch):
    captured: dict[str, object] = {}

    def fake_execvpe(file, args, env):
        captured["file"] = file
        captured["args"] = list(args)
        captured["env"] = dict(env)
        raise _ExecCalled()

    # A non-loopback host must be clamped before it reaches exec.
    monkeypatch.setattr(config_mod.Config, "load", classmethod(lambda cls: _fake_cfg()))
    _pin_snapshot(monkeypatch)

    import mp.summarize_local as sl
    monkeypatch.setattr(sl.os, "execvpe", fake_execvpe)

    with pytest.raises(_ExecCalled):
        serve_local_main([])

    args = captured["args"]
    assert args[-6:] == [
        "--model", "/hub/models--x/snapshots/" + "b" * 40,   # a pinned dir, never a repo id
        "--host", DEFAULT_HOST,   # clamped from 0.0.0.0
        "--port", "9999",
    ]
    # LOCAL22: the warm server bounds its retained KV caches too.
    assert args[args.index("--prompt-cache-size") + 1] == "2"
    # SEC13: exec must go through execvpe with an explicit env (child_env()).
    env = captured["env"]
    assert isinstance(env, dict)
    # SEC27: the per-spawn token rides in the environment, never in argv.
    token = env["MP_LOCAL_SERVER_TOKEN"]
    assert len(token) >= 32 and token not in " ".join(args)
    assert env["HF_HUB_OFFLINE"] == "1"


@pytest.mark.parametrize("regulated", [False, True])
def test_serve_local_refuses_a_model_with_no_pinned_snapshot(monkeypatch, regulated):
    """SEC13/SEC27: the server never downloads, in any mode, so serve-local fails
    closed on a missing snapshot instead of stranding the load. Exec never runs."""
    monkeypatch.setattr(
        config_mod.Config, "load",
        classmethod(lambda cls: _fake_cfg(regulated=regulated, model="mlx-community/Uncached-7B-4bit")),
    )
    import mp.summarize_local as sl
    _pin_snapshot(monkeypatch, present=False)

    def _boom(*a, **k):
        raise AssertionError("execvpe must not run for a model with no pinned snapshot")

    monkeypatch.setattr(sl.os, "execvpe", _boom)
    assert serve_local_main([]) == 1


@pytest.mark.parametrize("regulated", [False, True])
def test_serve_local_strips_cloud_tokens_from_child(monkeypatch, regulated):
    """SEC13/SEC27: the exec'd child inherits no managed token and is pinned
    offline, in every mode (the warm server used to carry `OPENAI_API_KEY`)."""
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-should-be-stripped")
    monkeypatch.setenv("NOTION_TOKEN", "ntn-should-be-stripped")
    monkeypatch.setenv("OPENAI_API_KEY", "sk-also-stripped")
    monkeypatch.setattr(
        config_mod.Config, "load",
        classmethod(lambda cls: _fake_cfg(regulated=regulated, endpoint="http://127.0.0.1:8765")),
    )
    import mp.summarize_local as sl
    _pin_snapshot(monkeypatch)

    captured: dict[str, object] = {}

    def fake_execvpe(file, args, env):
        captured["env"] = dict(env)
        raise _ExecCalled()

    monkeypatch.setattr(sl.os, "execvpe", fake_execvpe)
    with pytest.raises(_ExecCalled):
        serve_local_main([])

    env = captured["env"]
    assert "ANTHROPIC_API_KEY" not in env
    assert "NOTION_TOKEN" not in env
    assert "OPENAI_API_KEY" not in env
    assert env.get("HF_HUB_OFFLINE") == "1"


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
