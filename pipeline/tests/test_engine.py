"""Tests for `engine.complete_text` backend routing + the zero-egress contract.

CI-safe: the local and Anthropic clients are faked, so no model loads and no
socket opens. What is under test is the routing (which backend answers) and the
regulated / NDA force-local rule, not the vendor SDKs.
"""
from __future__ import annotations

import anthropic
import httpx
import pytest

from mp import engine
from mp.config import Config
from mp.engine import EngineError, EngineResult, complete_text


def _cfg(backend: str = "local", regulated: bool = False, nda: bool = False) -> Config:
    return Config.model_validate({
        "summarization": {"backend": backend, "local_model": "fake-local", "model": "fake-cloud"},
        "modes": {"regulated_mode": regulated, "workflow_nda_mode": nda},
    })


class _FakeLocal:
    def __init__(self, text: str = "local answer", model: str = "fake-local") -> None:
        self._text = text
        self.model = model
        self.closed = False

    def complete(self, *, system_prompt: str, user_message: str, max_tokens: int, response_format) -> str:
        return self._text

    def close(self) -> None:
        self.closed = True


class _FakeAnthropic:
    last: "_FakeAnthropic | None" = None

    def __init__(self, *, api_key: str, model: str) -> None:
        self.model = model
        _FakeAnthropic.last = self

    def complete(self, *, system_prompt: str, user_message: str, max_tokens: int) -> str:
        return "cloud answer"


def _patch_local(monkeypatch, fake: _FakeLocal) -> _FakeLocal:
    monkeypatch.setattr(engine, "_local_client", lambda cfg, model: fake)
    return fake


def _call(cfg: Config) -> EngineResult:
    return complete_text(cfg, system_prompt="s", user_message="u", max_tokens=64)


def test_local_backend_uses_local_and_closes_it(monkeypatch: pytest.MonkeyPatch) -> None:
    fake = _patch_local(monkeypatch, _FakeLocal())
    res = _call(_cfg("local"))
    assert res.backend == "local"
    assert res.text == "local answer"
    assert fake.closed  # the server subprocess is always closed


def test_anthropic_backend_uses_cloud(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")
    monkeypatch.setattr(engine, "AnthropicTextClient", _FakeAnthropic)
    res = _call(_cfg("anthropic"))
    assert res.backend == "anthropic"
    assert res.text == "cloud answer"


def test_regulated_forces_local_over_anthropic(monkeypatch: pytest.MonkeyPatch) -> None:
    # Even with backend=anthropic and a key set, regulated_mode must resolve local.
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")
    fake = _patch_local(monkeypatch, _FakeLocal())
    res = _call(_cfg("anthropic", regulated=True))
    assert res.backend == "local"
    assert fake.closed


def test_nda_forces_local(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")
    _patch_local(monkeypatch, _FakeLocal())
    assert _call(_cfg("anthropic", nda=True)).backend == "local"


def test_apple_intelligence_falls_back_to_local(monkeypatch: pytest.MonkeyPatch) -> None:
    _patch_local(monkeypatch, _FakeLocal(text="apple->local"))
    res = _call(_cfg("apple_intelligence"))
    assert res.backend == "local"
    assert res.text == "apple->local"


def test_auto_prefers_anthropic_when_key_present(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")
    monkeypatch.setattr(engine, "AnthropicTextClient", _FakeAnthropic)
    _patch_local(monkeypatch, _FakeLocal())
    assert _call(_cfg("auto")).backend == "anthropic"


def test_auto_falls_back_to_local_without_key(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    _patch_local(monkeypatch, _FakeLocal())
    assert _call(_cfg("auto")).backend == "local"


def _raising_anthropic(exc: BaseException) -> type:
    class _Boom:
        def __init__(self, *, api_key: str, model: str) -> None:
            self.model = model

        def complete(self, **kwargs) -> str:
            raise exc

    return _Boom


def test_auto_falls_back_to_local_on_anthropic_failure(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")
    req = httpx.Request("POST", "https://api.anthropic.com/v1/messages")
    monkeypatch.setattr(engine, "AnthropicTextClient",
                        _raising_anthropic(anthropic.APIConnectionError(request=req)))
    _patch_local(monkeypatch, _FakeLocal(text="fell back"))
    res = _call(_cfg("auto"))
    assert res.backend == "local"
    assert res.text == "fell back"


@pytest.mark.parametrize(
    "exc",
    [
        anthropic.RateLimitError(
            "boom",
            response=httpx.Response(
                429, request=httpx.Request("POST", "https://api.anthropic.com/v1/messages")
            ),
            body=None,
        ),
        anthropic.InternalServerError(
            "boom",
            response=httpx.Response(
                500, request=httpx.Request("POST", "https://api.anthropic.com/v1/messages")
            ),
            body=None,
        ),
        anthropic.APITimeoutError(
            request=httpx.Request("POST", "https://api.anthropic.com/v1/messages")
        ),
    ],
    ids=["rate_limit_429", "server_error_500", "timeout"],
)
def test_auto_falls_back_to_local_on_429_5xx_and_timeout(
    monkeypatch: pytest.MonkeyPatch, exc: BaseException
) -> None:
    # engine and summarize share one ladder (PIPE7), so the transport failures
    # that drop summarize to local drop ask / digest to local too.
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")
    monkeypatch.setattr(engine, "AnthropicTextClient", _raising_anthropic(exc))
    _patch_local(monkeypatch, _FakeLocal(text="fell back"))
    assert _call(_cfg("auto")).backend == "local"


def test_auto_does_not_fall_back_on_a_caller_bug(monkeypatch: pytest.MonkeyPatch) -> None:
    # PIPE7 tightened this path. It used to catch bare `Exception`, so a malformed
    # request or a bug in our own call site silently re-ran on a different model
    # and reported the local backend's answer as if nothing had happened. Only an
    # unreachable-or-unwilling cloud earns the fallback now.
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")
    monkeypatch.setattr(engine, "AnthropicTextClient",
                        _raising_anthropic(ValueError("caller bug")))
    _patch_local(monkeypatch, _FakeLocal(text="must not be reached"))
    with pytest.raises(ValueError, match="caller bug"):
        _call(_cfg("auto"))


def test_empty_local_completion_raises(monkeypatch: pytest.MonkeyPatch) -> None:
    _patch_local(monkeypatch, _FakeLocal(text="   "))
    with pytest.raises(EngineError):
        _call(_cfg("local"))
