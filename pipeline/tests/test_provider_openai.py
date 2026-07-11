"""Tests for the openai backend (PROV1). Happy paths use an httpx MockTransport;
the security test arms the real egress guard and asserts the httpx transport
patch blocks the call, the same clamp anthropic gets (the provider is built on
httpx precisely so this holds with no SDK-specific plumbing).
"""
from __future__ import annotations

import json
import os

import httpx
import pytest

from mp.config import Config
from mp.provider_openai import OpenAIClient, OpenAIError
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


def _mock_transport(monkeypatch, handler):
    real_init = httpx.Client.__init__

    def patched(self, *args, **kwargs):
        kwargs["transport"] = httpx.MockTransport(handler)
        real_init(self, *args, **kwargs)

    monkeypatch.setattr(httpx.Client, "__init__", patched)


def test_summarize_parses_openai_json(monkeypatch):
    captured: dict = {}

    def handler(request: httpx.Request) -> httpx.Response:
        captured["path"] = request.url.path
        body = json.loads(request.content)
        captured["response_format"] = body.get("response_format")
        captured["model"] = body["model"]
        return httpx.Response(200, json={"choices": [{"message": {"content": _summary_json()}}]})

    _mock_transport(monkeypatch, handler)
    out = OpenAIClient(api_key="sk-x", model="gpt-4o").summarize(
        system_prompt="s", transcript="t", model="ignored-anthropic-model", max_tokens=100
    )
    assert out.title == "Weekly sync"
    assert captured["path"] == "/v1/chat/completions"
    assert captured["response_format"] == {"type": "json_object"}  # JSON mode on
    assert captured["model"] == "gpt-4o"  # provider-pinned, not the passed model


def test_complete_returns_content(monkeypatch):
    def handler(request: httpx.Request) -> httpx.Response:
        body = json.loads(request.content)
        assert "response_format" not in body  # free-form completion, no JSON mode
        return httpx.Response(200, json={"choices": [{"message": {"content": "the answer"}}]})

    _mock_transport(monkeypatch, handler)
    text = OpenAIClient(api_key="sk", model="gpt-4o").complete(
        system_prompt="s", user_message="q", max_tokens=10
    )
    assert text == "the answer"


def test_http_error_raises(monkeypatch):
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(401, text="unauthorized")

    _mock_transport(monkeypatch, handler)
    with pytest.raises(OpenAIError):
        OpenAIClient(api_key="bad", model="gpt-4o").complete(
            system_prompt="s", user_message="q", max_tokens=10
        )


def test_egress_guard_blocks_openai_when_armed():
    """The openai provider must be clamped by the egress guard exactly like
    anthropic: an armed guard raises before any non-loopback request leaves."""
    from mp import egress_guard

    egress_guard.arm("test")
    try:
        client = OpenAIClient(api_key="sk-x", model="gpt-4o")
        with pytest.raises(egress_guard.EgressBlocked):
            client.complete(system_prompt="s", user_message="hi", max_tokens=10)
    finally:
        egress_guard.disarm()
        # arm() force-sets the huggingface-offline env; clean it so it does not
        # leak into other tests.
        for k in ("HF_HUB_OFFLINE", "HF_HUB_DISABLE_TELEMETRY"):
            os.environ.pop(k, None)


def test_select_backend_openai_requires_key(monkeypatch):
    monkeypatch.setenv("OPENAI_API_KEY", "sk-test")
    from mp.summarize import _select_backend
    client = _select_backend(
        Config.model_validate({"summarization": {"backend": "openai", "openai_model": "gpt-4o"}})
    )
    assert isinstance(client, OpenAIClient)
    assert client.model == "gpt-4o"
