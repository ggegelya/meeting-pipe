"""One Anthropic client policy at every call site (PIPE24).

Before this the summarize, ask/digest and cleanup sites each built their own
`anthropic.Anthropic` with their own timeout and retry policy, ask/digest never
went through `_create_message`, and HTTP 529 (`OverloadedError`) was neither
retried nor dropped to local. The 2026-11-13 amendment adds the one re-issue a
workflow pinned to `anthropic` gets for a timeout, since it has no fallback.
Nothing here touches the network: fakes only.
"""
from __future__ import annotations

import re
from pathlib import Path
from types import SimpleNamespace
from typing import Any

import anthropic
import httpx
import pytest

from mp import providers, summarize
from mp.backend_fallback import fallback_exceptions, run_with_local_fallback
from mp.config import Config
from mp.summarize import _create_message, _should_retry_anthropic

_REQ = httpx.Request("POST", "https://api.anthropic.com/v1/messages")


def _status_error(cls: type[anthropic.APIStatusError], code: int) -> anthropic.APIStatusError:
    return cls("boom", response=httpx.Response(code, request=_REQ), body=None)


def _timeout() -> anthropic.APITimeoutError:
    return anthropic.APITimeoutError(request=_REQ)


class _FakeAnthropic:
    """`client.messages.create`; each call pops an outcome (raise or return)."""

    def __init__(self, outcomes: list[Any]) -> None:
        self.calls = 0
        self._outcomes = list(outcomes)
        self.messages = self

    def create(self, **_: Any) -> Any:
        self.calls += 1
        outcome = self._outcomes.pop(0)
        if isinstance(outcome, BaseException):
            raise outcome
        return outcome


@pytest.fixture(autouse=True)
def _no_real_waiting(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr("mp.summarize._create_message.retry.wait", lambda *_a, **_k: 0)
    monkeypatch.setattr(summarize.time, "sleep", lambda _s: None)


# ----- the factory -----


def test_the_factory_builds_the_summarize_policy() -> None:
    client = providers.make_anthropic_client("sk-test")
    assert client.max_retries == 0
    assert client.timeout == httpx.Timeout(120.0, connect=10.0)
    assert client.api_key == "sk-test"


def test_every_site_is_built_through_the_factory(monkeypatch: pytest.MonkeyPatch) -> None:
    from mp.diarize_cleanup import AnthropicCleanupClient
    from mp.engine import AnthropicTextClient

    keys: list[str] = []
    sentinel = object()

    def fake_factory(api_key: str) -> object:
        keys.append(api_key)
        return sentinel

    monkeypatch.setattr(providers, "make_anthropic_client", fake_factory)

    assert summarize.AnthropicSummaryClient(api_key="k1")._client is sentinel
    assert AnthropicTextClient(api_key="k2", model="m")._client is sentinel
    assert AnthropicCleanupClient(api_key="k3", model="m", max_tokens=8)._client is sentinel
    assert keys == ["k1", "k2", "k3"]


def test_the_factory_module_is_the_only_one_that_constructs_a_client() -> None:
    src = Path(summarize.__file__).parent
    offenders = [
        p.name for p in sorted(src.glob("*.py"))
        if re.search(r"anthropic\.Anthropic\(", p.read_text(encoding="utf-8"))
    ]
    assert offenders == ["providers.py"]


# ----- ask / digest go through _create_message -----


def _text_response(text: str = "answer") -> Any:
    return SimpleNamespace(content=[SimpleNamespace(type="text", text=text)], stop_reason="end_turn")


def _text_client(monkeypatch: pytest.MonkeyPatch, fake: _FakeAnthropic) -> Any:
    from mp.engine import AnthropicTextClient

    monkeypatch.setattr(providers, "make_anthropic_client", lambda _k: fake)
    return AnthropicTextClient(api_key="k", model="claude-sonnet-4-6")


def test_text_client_retries_a_500_through_create_message(monkeypatch: pytest.MonkeyPatch) -> None:
    fake = _FakeAnthropic([_status_error(anthropic.InternalServerError, 500), _text_response()])
    out = _text_client(monkeypatch, fake).complete(system_prompt="s", user_message="u", max_tokens=8)
    assert out == "answer"
    assert fake.calls == 2


def test_text_client_does_not_retry_an_awake_timeout(monkeypatch: pytest.MonkeyPatch) -> None:
    fake = _FakeAnthropic([_timeout(), _text_response()])
    with pytest.raises(anthropic.APITimeoutError):
        _text_client(monkeypatch, fake).complete(system_prompt="s", user_message="u", max_tokens=8)
    assert fake.calls == 1


# ----- 529 -----


def test_an_overload_is_retried_by_create_message() -> None:
    overloaded = _status_error(anthropic.OverloadedError, 529)
    assert _should_retry_anthropic(overloaded) is True
    fake = _FakeAnthropic([overloaded, overloaded, "answer"])
    assert _create_message(fake, model="claude-x") == "answer"
    assert fake.calls == 3


def test_an_overload_falls_back_to_local(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")
    assert anthropic.OverloadedError in fallback_exceptions()

    def cloud() -> str:
        raise _status_error(anthropic.OverloadedError, 529)

    assert run_with_local_fallback(cloud=cloud, local=lambda: "local") == ("local", "local")


# ----- the pinned-backend timeout re-issue (2026-11-13 amendment) -----


def _summary_response() -> Any:
    block = SimpleNamespace(
        type="tool_use",
        input={
            "title": "Standup", "summary": ["A point."], "decisions": [], "actions": [],
            "questions": [], "attendees": ["Alice"], "detected_language": "en",
        },
    )
    return SimpleNamespace(content=[block], stop_reason="tool_use")


def _summarize(monkeypatch: pytest.MonkeyPatch, fake: _FakeAnthropic, **kw: Any) -> Any:
    monkeypatch.setattr(providers, "make_anthropic_client", lambda _k: fake)
    return summarize.AnthropicSummaryClient(api_key="k", **kw).summarize(
        system_prompt="s", transcript="A: hi.", model="claude-sonnet-4-6", max_tokens=64,
    )


def test_a_pinned_client_reissues_a_timeout_once_and_succeeds(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    fake = _FakeAnthropic([_timeout(), _summary_response()])
    assert _summarize(monkeypatch, fake, retry_timeout_once=True).title == "Standup"
    assert fake.calls == 2


def test_two_timeouts_in_a_row_fail_after_exactly_two_calls(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    fake = _FakeAnthropic([_timeout(), _timeout(), _summary_response()])
    with pytest.raises(anthropic.APITimeoutError):
        _summarize(monkeypatch, fake, retry_timeout_once=True)
    assert fake.calls == 2


def test_a_client_with_no_flag_still_fails_on_the_first_timeout(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    fake = _FakeAnthropic([_timeout(), _summary_response()])
    with pytest.raises(anthropic.APITimeoutError):
        _summarize(monkeypatch, fake)
    assert fake.calls == 1


def test_a_slept_through_timeout_on_a_pinned_client_is_reissued_once_only(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # The first timeout reads as slept-through (wall far ahead of monotonic) and
    # is re-issued by PIPE10's path; a second timeout must not get a third call.
    class _Clock:
        def __init__(self) -> None:
            self.wall = iter([0.0, 7980.0])
            self.mono = iter([0.0, 123.0])

        def time(self) -> float:
            return next(self.wall)

        def monotonic(self) -> float:
            return next(self.mono)

        def sleep(self, _s: float) -> None:  # pragma: no cover - must not be reached
            raise AssertionError("a slept-through re-issue takes no extra pause")

    monkeypatch.setattr("mp.summarize.time", _Clock())
    fake = _FakeAnthropic([_timeout(), _timeout(), "answer"])
    with pytest.raises(anthropic.APITimeoutError):
        _create_message(fake, retry_timeout_once=True, model="claude-x")
    assert fake.calls == 2


def test_the_pinned_provider_row_turns_the_reissue_on_and_auto_leaves_it_off(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")
    monkeypatch.setattr(providers, "make_anthropic_client", lambda _k: object())
    pinned = providers.lookup("anthropic").build_summary(Config())
    assert pinned._retry_timeout_once is True  # type: ignore[union-attr]

    # `AutoFallbackClient` builds its cloud client per call; record how. A
    # ValueError is not a fallback class, so nothing reaches the local rung.
    built: list[dict[str, Any]] = []

    class _Recorder:
        def __init__(self, **kw: Any) -> None:
            built.append(kw)

        def summarize(self, **_: Any) -> Any:
            raise ValueError("stop here")

    monkeypatch.setattr(summarize, "AnthropicSummaryClient", _Recorder)
    auto = providers.lookup("auto").build_summary(Config())
    with pytest.raises(ValueError, match="stop here"):
        auto.summarize(system_prompt="s", transcript="t", model="m", max_tokens=8)
    assert built == [{"api_key": "sk-test"}]  # the flag is absent, so it is off


def test_the_auto_rung_still_drops_to_local_after_one_cloud_timeout(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")
    cloud = _FakeAnthropic([_timeout(), _summary_response()])
    monkeypatch.setattr(providers, "make_anthropic_client", lambda _k: cloud)

    def cloud_call() -> Any:
        return summarize.AnthropicSummaryClient(api_key="k").summarize(
            system_prompt="s", transcript="t", model="m", max_tokens=8,
        )

    assert run_with_local_fallback(cloud=cloud_call, local=lambda: "local") == ("local", "local")
    assert cloud.calls == 1


def test_cleanup_does_not_reissue_an_awake_timeout(monkeypatch: pytest.MonkeyPatch) -> None:
    from mp.diarize_cleanup import AnthropicCleanupClient

    fake = _FakeAnthropic([_timeout(), SimpleNamespace(content=[], stop_reason="end_turn")])
    monkeypatch.setattr(providers, "make_anthropic_client", lambda _k: fake)
    client = AnthropicCleanupClient(api_key="k", model="claude-sonnet-4-6", max_tokens=8)
    with pytest.raises(anthropic.APITimeoutError):
        client.propose_edits(window_prompt="[0] a: hi", speakers=["a", "b"])
    assert fake.calls == 1
