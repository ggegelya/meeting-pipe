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
