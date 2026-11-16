"""Tests for the claude_cli backend (PROV1). No live `claude` process: the
subprocess is monkeypatched. The load-bearing test is the fail-closed refusal to
spawn under a zero-egress (armed) guard, since a CLI child egresses outside the
in-process httpx guard.
"""
from __future__ import annotations

import json
import subprocess

import pytest

import mp.provider_claude_cli as cc
from mp.config import Config
from mp.provider_claude_cli import ClaudeCLIClient, ClaudeCLIError
from mp.schemas import ActionItem, MeetingSummary


def _summary_json() -> str:
    return MeetingSummary(
        title="Weekly sync",
        summary=["Discussed the roadmap."],
        decisions=["Ship on Friday."],
        actions=[ActionItem(task="Send notes", owner="Alice", confidence="high")],
        questions=["When is the next review?"],
        attendees=["Alice", "Bob"],
        detected_language="en",
    ).model_dump_json()


def _fake_run(result_text: str, *, is_error: bool = False, returncode: int = 0):
    def run(cmd, **kwargs):
        payload = {"type": "result", "is_error": is_error, "result": result_text}
        return subprocess.CompletedProcess(cmd, returncode, stdout=json.dumps(payload), stderr="")
    return run


@pytest.fixture
def _found_claude(monkeypatch):
    monkeypatch.setattr(cc, "find_claude", lambda: "/usr/local/bin/claude")


def test_summarize_parses_valid_json(monkeypatch, _found_claude):
    monkeypatch.setattr(cc.subprocess, "run", _fake_run(_summary_json()))
    out = ClaudeCLIClient().summarize(system_prompt="sys", transcript="hi", model="x", max_tokens=1000)
    assert out.title == "Weekly sync"
    assert out.decisions == ["Ship on Friday."]


def test_summarize_recovers_json_from_surrounding_prose(monkeypatch, _found_claude):
    wrapped = "Sure, here is the JSON:\n\n" + _summary_json() + "\n\nHope that helps!"
    monkeypatch.setattr(cc.subprocess, "run", _fake_run(wrapped))
    out = ClaudeCLIClient().summarize(system_prompt="s", transcript="t", model="x", max_tokens=100)
    assert out.title == "Weekly sync"


def test_summarize_prompt_goes_in_on_stdin(monkeypatch, _found_claude):
    captured: dict = {}

    def run(cmd, **kwargs):
        captured["cmd"] = cmd
        captured["input"] = kwargs.get("input")
        return subprocess.CompletedProcess(
            cmd, 0, stdout=json.dumps({"is_error": False, "result": _summary_json()}), stderr=""
        )

    monkeypatch.setattr(cc.subprocess, "run", run)
    ClaudeCLIClient().summarize(system_prompt="SYS", transcript="TRANSCRIPT", model="x", max_tokens=10)
    # Prompt on stdin (not argv) so a long transcript never hits ARG_MAX.
    assert captured["input"] is not None and "TRANSCRIPT" in captured["input"]
    assert "-p" in captured["cmd"] and "--output-format" in captured["cmd"]
    assert not any("TRANSCRIPT" in str(a) for a in captured["cmd"])


def test_complete_returns_result_text(monkeypatch, _found_claude):
    monkeypatch.setattr(cc.subprocess, "run", _fake_run("  the answer  "))
    text = ClaudeCLIClient().complete(system_prompt="s", user_message="q", max_tokens=100)
    assert text == "the answer"


def test_is_error_result_raises(monkeypatch, _found_claude):
    monkeypatch.setattr(cc.subprocess, "run", _fake_run("401 auth failed", is_error=True))
    with pytest.raises(ClaudeCLIError):
        ClaudeCLIClient().complete(system_prompt="s", user_message="q", max_tokens=10)


def test_nonzero_exit_raises(monkeypatch, _found_claude):
    def run(cmd, **kwargs):
        return subprocess.CompletedProcess(cmd, 1, stdout="", stderr="boom")
    monkeypatch.setattr(cc.subprocess, "run", run)
    with pytest.raises(ClaudeCLIError):
        ClaudeCLIClient().complete(system_prompt="s", user_message="q", max_tokens=10)


def test_missing_binary_raises(monkeypatch):
    monkeypatch.setattr(cc, "find_claude", lambda: None)
    with pytest.raises(ClaudeCLIError, match="not installed"):
        ClaudeCLIClient().complete(system_prompt="s", user_message="q", max_tokens=10)


def test_refuses_to_spawn_when_egress_guard_armed(monkeypatch, _found_claude):
    """Fail-closed: the CLI child egresses outside the httpx guard, so it must
    never spawn under a zero-egress run. subprocess.run is a tripwire here."""
    spawned: list[int] = []
    monkeypatch.setattr(cc.subprocess, "run", lambda *a, **k: spawned.append(1))
    monkeypatch.setattr(cc.egress_guard, "is_armed", lambda: True)
    with pytest.raises(ClaudeCLIError, match="zero-egress"):
        ClaudeCLIClient().summarize(system_prompt="s", transcript="t", model="x", max_tokens=10)
    assert spawned == [], "the claude CLI must not be spawned while the guard is armed"


def test_select_backend_claude_cli_needs_no_api_key(monkeypatch):
    """Acceptance: backend=claude_cli resolves a client with no API key set."""
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    from mp.summarize import _select_backend
    client = _select_backend(Config.model_validate({"summarization": {"backend": "claude_cli"}}))
    assert isinstance(client, ClaudeCLIClient)


def test_summarize_end_to_end_no_api_key(tmp_path, monkeypatch, _found_claude):
    """Acceptance: `summarize()` produces a summary via claude_cli end-to-end with
    no API key configured."""
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    monkeypatch.setattr(cc.subprocess, "run", _fake_run(_summary_json()))
    md = tmp_path / "20260101-1000.md"
    md.write_text("Alice: hello everyone\nBob: hi there", encoding="utf-8")
    cfg = Config.model_validate({
        "summarization": {"backend": "claude_cli"},
        "recording": {"output_dir": str(tmp_path)},
    })
    from mp.summarize import summarize
    out = summarize(md, cfg=cfg)
    assert out["backend"] == "claude_cli"
    assert (tmp_path / "20260101-1000.summary.json").exists()
    assert (tmp_path / "20260101-1000.summary.md").exists()


# ----- SEC20: the child is confined to a text turn -----


def _capturing_run(captured: list[dict], result_text: str):
    """A `subprocess.run` stand-in that records argv, env, cwd, and whether the cwd
    was an empty directory at the moment of the call."""
    def run(cmd, **kwargs):
        from pathlib import Path

        cwd = Path(kwargs["cwd"])
        captured.append({
            "cmd": list(cmd), "env": kwargs["env"], "cwd": cwd,
            "cwd_was_empty_dir": cwd.is_dir() and not any(cwd.iterdir()),
        })
        payload = {"type": "result", "is_error": False, "result": result_text}
        return subprocess.CompletedProcess(cmd, 0, stdout=json.dumps(payload), stderr="")
    return run


def _assert_confined(call: dict) -> None:
    cmd = call["cmd"]
    # Built-in tools are off. `--allowed-tools` only pre-approves, so it must not
    # be what we rely on (and must not be there pretending to).
    assert cmd[cmd.index("--tools") + 1] == ""
    assert "--allowed-tools" not in cmd
    # The owner's MCP servers do not load: strict config over an empty server map.
    assert "--strict-mcp-config" in cmd
    assert json.loads(cmd[cmd.index("--mcp-config") + 1]) == {"mcpServers": {}}
    assert "--no-session-persistence" in cmd
    # The owner's CLAUDE.md, hooks, plugins and agents are off; auth still works.
    assert "--safe-mode" in cmd
    assert "--setting-sources" not in cmd             # would drop apiKeyHelper / model
    assert "--disable-slash-commands" in cmd
    # `--tools` and `--mcp-config` are variadic: each value must be followed by
    # another flag (or end the argv), or the CLI swallows whatever comes next.
    for flag in ("--tools", "--mcp-config"):
        after = cmd[cmd.index(flag) + 2:cmd.index(flag) + 3]
        assert after == [] or after[0].startswith("-"), flag
    # `--bare` would drop the subscription auth this backend exists for.
    assert "--bare" not in cmd
    # An empty directory, gone again afterwards.
    assert call["cwd_was_empty_dir"] and not call["cwd"].exists()


def _secret_env(monkeypatch) -> None:
    from mp.config import MANAGED_SECRET_KEYS

    for key in MANAGED_SECRET_KEYS:
        monkeypatch.setenv(key, "secret-value")
    monkeypatch.setenv("UNRELATED_VAR", "kept")


def _assert_env_clean(call: dict) -> None:
    from mp.config import MANAGED_SECRET_KEYS

    assert not any(k in call["env"] for k in MANAGED_SECRET_KEYS)
    assert call["env"]["UNRELATED_VAR"] == "kept"      # only the credentials go


def test_summarize_spawns_a_confined_child(monkeypatch, _found_claude):
    _secret_env(monkeypatch)
    calls: list[dict] = []
    monkeypatch.setattr(cc.subprocess, "run", _capturing_run(calls, _summary_json()))
    ClaudeCLIClient().summarize(system_prompt="s", transcript="t", model="x", max_tokens=10)
    assert len(calls) == 1
    _assert_confined(calls[0])
    _assert_env_clean(calls[0])


def test_every_caller_reaches_the_same_confined_spawn(monkeypatch, _found_claude):
    """Ask and digest (`engine.complete_text`) and diarization cleanup (the
    providers cleanup row) reach `ClaudeCLIClient` by their own routes; each one
    must hit the confined argv, with the managed tokens stripped."""
    from mp import engine, providers

    _secret_env(monkeypatch)
    cfg = Config.model_validate({"summarization": {"backend": "claude_cli"}})

    calls: list[dict] = []
    monkeypatch.setattr(cc.subprocess, "run", _capturing_run(calls, "an answer"))
    engine.complete_text(cfg, system_prompt="s", user_message="q", max_tokens=10)  # ask / digest
    assert len(calls) == 1
    _assert_confined(calls[0])
    _assert_env_clean(calls[0])

    calls.clear()
    monkeypatch.setattr(cc.subprocess, "run", _capturing_run(calls, '{"edits": []}'))
    cleanup = providers.lookup("claude_cli").build_cleanup(cfg)  # diarization cleanup
    cleanup.propose_edits(window_prompt="[0] A: hi", speakers=["A"])
    assert len(calls) == 1
    _assert_confined(calls[0])
    _assert_env_clean(calls[0])


def test_each_run_gets_its_own_workdir(monkeypatch, _found_claude):
    calls: list[dict] = []
    monkeypatch.setattr(cc.subprocess, "run", _capturing_run(calls, "ok"))
    client = ClaudeCLIClient()
    client.complete(system_prompt="s", user_message="q", max_tokens=10)
    client.complete(system_prompt="s", user_message="q", max_tokens=10)
    assert calls[0]["cwd"] != calls[1]["cwd"]


def test_the_workdir_is_removed_even_when_the_child_fails(monkeypatch, _found_claude):
    seen: list = []

    def run(cmd, **kwargs):
        seen.append(kwargs["cwd"])
        raise subprocess.TimeoutExpired(cmd, 1)

    monkeypatch.setattr(cc.subprocess, "run", run)
    with pytest.raises(ClaudeCLIError, match="timed out"):
        ClaudeCLIClient().complete(system_prompt="s", user_message="q", max_tokens=10)
    from pathlib import Path

    assert not Path(seen[0]).exists()


def test_the_armed_refusal_still_fires_before_any_workdir_or_spawn(monkeypatch, _found_claude):
    made: list[int] = []
    monkeypatch.setattr(cc.tempfile, "TemporaryDirectory", lambda *a, **k: made.append(1))
    monkeypatch.setattr(cc.subprocess, "run", lambda *a, **k: made.append(2))
    monkeypatch.setattr(cc.egress_guard, "is_armed", lambda: True)
    with pytest.raises(ClaudeCLIError, match="zero-egress"):
        ClaudeCLIClient().complete(system_prompt="s", user_message="q", max_tokens=10)
    assert made == []


def test_a_claude_in_a_fixed_install_dir_beats_one_earlier_on_path(tmp_path, monkeypatch):
    # SEC17: PATH is user-writable, so a planted `claude` ahead of the real install must lose.
    fixed = tmp_path / "fixed"
    planted = tmp_path / "planted"
    for d in (fixed, planted):
        d.mkdir()
        (d / "claude").write_text("#!/bin/sh\n")
        (d / "claude").chmod(0o755)
    monkeypatch.setattr(cc, "_FALLBACK_DIRS", (str(fixed),))
    monkeypatch.setenv("PATH", f"{planted}:/usr/bin:/bin")
    assert cc.find_claude() == str(fixed / "claude")


def test_claude_still_resolves_from_path_when_no_fixed_dir_has_it(tmp_path, monkeypatch):
    planted = tmp_path / "bin"
    planted.mkdir()
    (planted / "claude").write_text("#!/bin/sh\n")
    (planted / "claude").chmod(0o755)
    monkeypatch.setattr(cc, "_FALLBACK_DIRS", (str(tmp_path / "nowhere"),))
    monkeypatch.setenv("PATH", f"{planted}:/usr/bin:/bin")
    assert cc.find_claude() == str(planted / "claude")


def test_the_resolved_claude_path_is_logged_once(tmp_path, monkeypatch, caplog):
    import logging

    fixed = tmp_path / "fixed"
    fixed.mkdir()
    (fixed / "claude").write_text("#!/bin/sh\n")
    (fixed / "claude").chmod(0o755)
    monkeypatch.setattr(cc, "_FALLBACK_DIRS", (str(fixed),))
    monkeypatch.setattr(cc, "_logged_claude", set())
    with caplog.at_level(logging.INFO, logger="mp.provider_claude_cli"):
        cc.find_claude()
        cc.find_claude()
    assert sum("claude CLI resolved to" in r.message for r in caplog.records) == 1
