"""Tests for `summarize._select_backend` and the regulated+local
zero-egress contract.

The egress test does not block at the OS level (that would need root
or a network namespace). Instead it patches `httpx.Client.send` and
the `anthropic.Anthropic` constructor so any non-localhost outbound
call fails the test loudly. That covers both the explicit Anthropic
SDK path and any hidden httpx call inside summarize.py.

Also the home of PIPE12's sampling-temperature fence. That one invariant spans two
modules (summarize's tool-use call and engine's free-form one), so both request
bodies are asserted here rather than splitting one constant's guard across two
files, each with its own copy of the same transport patch.
"""
from __future__ import annotations

import json
import logging
import sys
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path
from typing import Any
from unittest.mock import patch

import anthropic
import httpx
import pytest

from mp.config import SAMPLING_TEMPERATURE, Config, MissingSecretError
from mp.config import parse_local_endpoint
from mp.summarize import _AutoFallbackClient, _select_backend


def _local_cfg(backend: str = "local", regulated: bool = False) -> Config:
    return Config.model_validate({
        "summarization": {
            "backend": backend,
            "local_endpoint": "http://127.0.0.1:9999",
            "local_model": "fake-model",
        },
        "modes": {"regulated_mode": regulated},
    })


def test_select_backend_local_returns_local_client() -> None:
    cfg = _local_cfg("local")
    client = _select_backend(cfg)
    # Importing here keeps the test runnable when mlx-lm itself isn't
    # installed (the LocalSummaryClient module's only hard dep is httpx).
    from mp.summarize_local import LocalSummaryClient
    assert isinstance(client, LocalSummaryClient)


def test_select_backend_auto_returns_fallback_wrapper() -> None:
    cfg = _local_cfg("auto")
    client = _select_backend(cfg)
    assert isinstance(client, _AutoFallbackClient)


def test_select_backend_anthropic_requires_env(monkeypatch: pytest.MonkeyPatch) -> None:
    # require_env fails fast on a missing secret by design, and _select_backend
    # bubbles that out unchanged for the explicit "anthropic" mode. The
    # auto-fallback mode reads os.environ directly so it can fall back instead.
    #
    # PIPE16 changed the *mechanism* and not the intent: this was `SystemExit(2)`
    # raised from library code, which is a BaseException and so escaped every
    # `except Exception` a run is wrapped in, skipping the run_failed event, the
    # exit-3 mapping and the publish sidecar. The exit code the CLI returns is
    # unchanged and is pinned at the boundary by the test below.
    from mp.config import MissingSecretError

    cfg = _local_cfg("anthropic")
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    with pytest.raises(MissingSecretError):
        _select_backend(cfg)


def test_a_missing_secret_still_exits_two_at_the_cli_boundary(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    # The fail-fast half of PIPE16's contract, at the one place it was ever
    # meant: `mp.__main__.main` catches MissingSecretError once, beside the
    # KeyboardInterrupt handler, so every subcommand inherits it.
    import mp.__main__ as entry_point

    md = tmp_path / "20260101-120000.md"
    md.write_text("A: hello.\n", encoding="utf-8")
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    monkeypatch.setattr(
        entry_point, "_dispatch",
        lambda _cmd, _rest: (_ for _ in ()).throw(MissingSecretError("ANTHROPIC_API_KEY")),
    )
    monkeypatch.setattr(sys, "argv", ["mp", "summarize", str(md)])
    assert entry_point.main() == 2


def test_select_backend_unknown_raises() -> None:
    cfg = _local_cfg("local")
    cfg.summarization.backend = "made-up"  # type: ignore[assignment]
    with pytest.raises(ValueError):
        _select_backend(cfg)


def test_extract_backend_flag_parses_and_validates() -> None:
    from mp.config import extract_backend_flag
    assert extract_backend_flag(["x.md"]) == (["x.md"], None)
    assert extract_backend_flag(["x.md", "--backend", "local"]) == (["x.md"], "local")
    assert extract_backend_flag(["--backend=anthropic", "x.md"]) == (["x.md"], "anthropic")
    # Unknown value and a missing value are usage errors, surfaced as ValueError.
    with pytest.raises(ValueError):
        extract_backend_flag(["x.md", "--backend", "bogus"])
    with pytest.raises(ValueError):
        extract_backend_flag(["x.md", "--backend"])


def test_backend_override_selects_the_chosen_backend() -> None:
    # PIPE6: a one-shot override changes which client _select_backend builds,
    # without mutating the persisted config field on the original.
    from mp.config import with_backend_override
    from mp.summarize_local import LocalSummaryClient
    cfg = _local_cfg(backend="anthropic")
    overridden = with_backend_override(cfg, "local")
    assert isinstance(_select_backend(overridden), LocalSummaryClient)
    assert cfg.summarization.backend == "anthropic"  # original untouched


def test_backend_override_still_clamps_under_regulated() -> None:
    # PIPE6 + TECH-ARCH1: a one-shot override to anthropic on a regulated meeting
    # is still forced local. The override is applied to the config field, so
    # effective_backend's zero-egress clamp still bites; the override cannot widen
    # egress.
    from mp.config import effective_backend, with_backend_override
    from mp.summarize_local import LocalSummaryClient
    cfg = _local_cfg(backend="local", regulated=True)
    overridden = with_backend_override(cfg, "anthropic")
    assert effective_backend(overridden) == "local"
    assert isinstance(_select_backend(overridden), LocalSummaryClient)


def test_regulated_mode_forces_local_over_anthropic() -> None:
    # regulated_mode is a hard zero-egress guarantee: even with the
    # default backend=anthropic, _select_backend must resolve to the
    # on-device path so no transcript reaches Anthropic. Mirrors
    # test_nda_mode_forces_local_and_filesystem on the workflow side.
    cfg = _local_cfg(backend="anthropic", regulated=True)
    client = _select_backend(cfg)
    from mp.summarize_local import LocalSummaryClient
    assert isinstance(client, LocalSummaryClient)


def test_regulated_mode_forces_local_over_auto() -> None:
    # auto would call Anthropic first whenever it is reachable; under
    # regulated_mode that egress is not permitted, so it is forced local too.
    cfg = _local_cfg(backend="auto", regulated=True)
    client = _select_backend(cfg)
    from mp.summarize_local import LocalSummaryClient
    assert isinstance(client, LocalSummaryClient)


def test_select_backend_apple_raises() -> None:
    # apple_intelligence is a daemon-side (Swift) backend; the Python
    # summarizer must refuse it loudly rather than silently degrading.
    cfg = _local_cfg("apple_intelligence")
    with pytest.raises(ValueError):
        _select_backend(cfg)


def test_regulated_mode_forces_local_over_apple() -> None:
    # Under regulated_mode the proven on-device MLX path is forced even when
    # apple_intelligence is configured, so the zero-egress contract holds via
    # the path test_regulated_local_zero_egress locks in.
    cfg = _local_cfg(backend="apple_intelligence", regulated=True)
    client = _select_backend(cfg)
    from mp.summarize_local import LocalSummaryClient
    assert isinstance(client, LocalSummaryClient)


def test_parse_local_endpoint_variants() -> None:
    assert parse_local_endpoint("http://127.0.0.1:8765") == ("127.0.0.1", 8765)
    assert parse_local_endpoint("https://localhost:9000/v1") == ("localhost", 9000)
    assert parse_local_endpoint("127.0.0.1") == ("127.0.0.1", 8765)
    # Garbage in port slot falls back to the default port instead of raising.
    assert parse_local_endpoint("127.0.0.1:abc") == ("127.0.0.1", 8765)


# ----- Regulated + local: zero egress contract -----

class _EgressBlocker:
    """Intercepts httpx requests and refuses anything that isn't local."""

    def __init__(self) -> None:
        self.allowed_hosts = {"127.0.0.1", "localhost", "::1"}
        self.violations: list[str] = []

    def send(self, request: httpx.Request, **_: Any) -> httpx.Response:
        host = request.url.host
        if host not in self.allowed_hosts:
            self.violations.append(str(request.url))
            raise AssertionError(
                f"egress violation: {request.method} {request.url} "
                "(only localhost is permitted in regulated+local mode)"
            )
        # Pretend a local mlx_lm.server responded with a valid summary
        # so the call completes end-to-end without spinning a real
        # subprocess.
        body = {
            "choices": [
                {"message": {"content":
                    '{"title":"Local","summary":["bullet"],"decisions":[],'
                    '"actions":[],"questions":[],"attendees":[],'
                    '"detected_language":"en"}'
                }}
            ]
        }
        return httpx.Response(
            200, request=request,
            json=body,
        )


def test_regulated_local_zero_egress(tmp_path: Any) -> None:
    cfg = _local_cfg(backend="local", regulated=True)
    blocker = _EgressBlocker()

    # Build a transcript file the way `summarize()` expects.
    md = tmp_path / "test.md"
    md.write_text("# Transcript\n\nA: hello.\n", encoding="utf-8")

    # Patch all httpx.Client and httpx.AsyncClient instances to route
    # through the blocker. Patching the transport layer covers anthropic
    # SDK too (it is built on httpx).
    real_init = httpx.Client.__init__
    real_async_init = httpx.AsyncClient.__init__

    def patched_init(self: httpx.Client, *args: Any, **kwargs: Any) -> None:
        kwargs["transport"] = httpx.MockTransport(blocker.send)
        real_init(self, *args, **kwargs)

    def patched_async_init(self: httpx.AsyncClient, *args: Any, **kwargs: Any) -> None:
        kwargs["transport"] = httpx.MockTransport(blocker.send)
        real_async_init(self, *args, **kwargs)

    # Also poison the Anthropic constructor so any path that bypassed
    # httpx (there isn't one, but lock it anyway) fails loudly.
    def poisoned_anthropic(*_args: Any, **_kwargs: Any) -> Any:
        raise AssertionError(
            "Anthropic SDK was instantiated under regulated+local mode"
        )

    with patch.object(httpx.Client, "__init__", patched_init), \
         patch.object(httpx.AsyncClient, "__init__", patched_async_init), \
         patch("anthropic.Anthropic", side_effect=poisoned_anthropic):
        from mp.summarize import summarize
        # Run the full summarize entry point end-to-end. It must:
        #   - never hit api.anthropic.com (blocker would assert)
        #   - never instantiate anthropic.Anthropic (poison would raise)
        #   - return a valid summary from the mocked local server
        out = summarize(md, cfg=cfg)

    assert blocker.violations == [], f"egress violations: {blocker.violations}"
    summary_md = out["md"].read_text(encoding="utf-8")
    assert "Local" in summary_md


# ----- Local backend subprocess scoping -----

def test_summarize_closes_self_created_local_client(
    tmp_path: Any, monkeypatch: pytest.MonkeyPatch
) -> None:
    # The plain `local` backend owns an mlx_lm.server subprocess.
    # summarize() must close a client it built itself so the subprocess
    # does not outlive the CLI process (the `auto` path already does).
    from mp.schemas import MeetingSummary
    from mp.summarize import summarize

    md = tmp_path / "t.md"
    md.write_text("# Transcript\n\nA: hello.\n", encoding="utf-8")

    class _SpyClient:
        def __init__(self) -> None:
            self.closed = False

        def summarize(self, **_: Any) -> MeetingSummary:
            return MeetingSummary(
                title="T", summary=["b"], decisions=[], actions=[],
                questions=[], attendees=[], detected_language="en",
            )

        def close(self) -> None:
            self.closed = True

    spy = _SpyClient()
    monkeypatch.setattr("mp.summarize._select_backend", lambda _cfg: spy)
    summarize(md, cfg=_local_cfg(backend="local"))
    assert spy.closed is True


# ----- Auto fallback on rate-limit / server error (TECH-FEAT5) -----

def _anthropic_status_error(cls: type[anthropic.APIStatusError], code: int) -> anthropic.APIStatusError:
    req = httpx.Request("POST", "https://api.anthropic.com/v1/messages")
    return cls("boom", response=httpx.Response(code, request=req), body=None)


def test_should_retry_anthropic_skips_timeout_but_keeps_transients() -> None:
    # The end-stop/hang fix: a timeout means a stalled connection, so it must NOT be
    # retried (it would just re-hang); it drops straight to the local fallback. Rate
    # limits, 5xx, and connection resets stay retryable. APITimeoutError subclasses
    # APIConnectionError, so the explicit skip is load-bearing.
    from mp.summarize import _should_retry_anthropic

    req = httpx.Request("POST", "https://api.anthropic.com/v1/messages")
    assert _should_retry_anthropic(anthropic.APITimeoutError(request=req)) is False
    assert _should_retry_anthropic(anthropic.APIConnectionError(request=req)) is True
    assert _should_retry_anthropic(_anthropic_status_error(anthropic.RateLimitError, 429)) is True
    assert _should_retry_anthropic(_anthropic_status_error(anthropic.InternalServerError, 500)) is True
    assert _should_retry_anthropic(ValueError("caller bug")) is False


@pytest.mark.parametrize(
    "exc",
    [
        _anthropic_status_error(anthropic.RateLimitError, 429),
        _anthropic_status_error(anthropic.InternalServerError, 500),
        anthropic.APITimeoutError(
            request=httpx.Request("POST", "https://api.anthropic.com/v1/messages")
        ),
    ],
    ids=["rate_limit_429", "server_error_500", "timeout"],
)
def test_auto_falls_back_to_local_on_429_and_5xx(
    monkeypatch: pytest.MonkeyPatch, exc: anthropic.APIStatusError
) -> None:
    # A sustained 429 / 5xx (after the SDK's own retries) must drop to the local
    # backend, not fail the run.
    from mp.schemas import MeetingSummary

    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")

    class _RaisingAnthropic:
        def __init__(self, **_: Any) -> None: ...

        def summarize(self, **_: Any) -> MeetingSummary:
            raise exc

    class _FakeLocal:
        def __init__(self, **_: Any) -> None: ...

        def __enter__(self) -> "_FakeLocal":
            return self

        def __exit__(self, *_: Any) -> None: ...

        def summarize(self, **_: Any) -> MeetingSummary:
            return MeetingSummary(
                title="Local", summary=["b"], decisions=[], actions=[],
                questions=[], attendees=[], detected_language="en",
            )

    monkeypatch.setattr("mp.summarize.AnthropicSummaryClient", _RaisingAnthropic)
    monkeypatch.setattr("mp.summarize_local.LocalSummaryClient", _FakeLocal)

    client = _AutoFallbackClient(_local_cfg(backend="auto"))
    result = client.summarize(
        system_prompt="sys", transcript="A: hi.", model="claude-x", max_tokens=100,
    )
    assert result.title == "Local"
    assert client.last_used_backend == "local"


# ----- Slept-through-it timeout retry (PIPE10) -----
#
# httpx's read timeout rides the monotonic clock, which freezes while the Mac is
# asleep. So a request in flight when the lid closes burns its whole 120 s budget
# across dark-wake slivers and raises APITimeoutError on wake, having never had
# 120 s of awake time to answer in. `_create_message` tells that apart from a
# genuine stall by comparing the two clocks, and re-issues once.

def _timeout_error() -> anthropic.APITimeoutError:
    return anthropic.APITimeoutError(
        request=httpx.Request("POST", "https://api.anthropic.com/v1/messages")
    )


class _Clock:
    """Scripted stand-in for the `time` module.

    `time()` and `monotonic()` each read the next value from their own script.
    Strict on purpose: over-reading raises IndexError rather than inventing a
    value, so a change in how often `_create_message` samples the clocks fails
    the test instead of passing quietly.
    """

    def __init__(self, *, wall: list[float], monotonic: list[float]) -> None:
        self._wall = list(wall)
        self._monotonic = list(monotonic)

    def time(self) -> float:
        return self._wall.pop(0)

    def monotonic(self) -> float:
        return self._monotonic.pop(0)


class _FakeAnthropic:
    """Minimal `client.messages.create` surface. Each call pops an outcome:
    an exception instance is raised, anything else is returned."""

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


# The 2026-07-16 incident's real numbers: monotonic advanced 123 s while the
# wall clock advanced 2 h 13 m.
_SLEPT_WALL = [0.0, 7980.0]
_SLEPT_MONOTONIC = [0.0, 123.0]


def test_slept_through_timeout_retries_once_and_succeeds(
    monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture
) -> None:
    from mp.summarize import _create_message

    client = _FakeAnthropic([_timeout_error(), "answer"])
    monkeypatch.setattr(
        "mp.summarize.time", _Clock(wall=_SLEPT_WALL, monotonic=_SLEPT_MONOTONIC)
    )

    with caplog.at_level(logging.WARNING, logger="mp.summarize"):
        assert _create_message(client, model="claude-x") == "answer"

    assert client.calls == 2
    # The whole point of the log line: the next investigation reads the
    # divergence here instead of going digging in `pmset -g log`.
    logged = caplog.text
    assert "system sleep" in logged
    assert "7980" in logged and "123" in logged and "7857" in logged


def test_slept_through_timeout_retries_only_once(monkeypatch: pytest.MonkeyPatch) -> None:
    # A second timeout is terminal whatever the clocks say. Only the first
    # attempt reads them, so the scripts are the same as the success case.
    from mp.summarize import _create_message

    client = _FakeAnthropic([_timeout_error(), _timeout_error()])
    monkeypatch.setattr(
        "mp.summarize.time", _Clock(wall=_SLEPT_WALL, monotonic=_SLEPT_MONOTONIC)
    )

    with pytest.raises(anthropic.APITimeoutError):
        _create_message(client, model="claude-x")

    assert client.calls == 2


def test_genuine_stall_timeout_fails_immediately(monkeypatch: pytest.MonkeyPatch) -> None:
    # Clocks agree (the machine stayed awake), so this is a real stalled
    # connection and keeps failing on the first attempt exactly as before:
    # tenacity does not retry a timeout, and the sleep path does not fire.
    from mp.summarize import _create_message

    client = _FakeAnthropic([_timeout_error()])
    monkeypatch.setattr(
        "mp.summarize.time", _Clock(wall=[0.0, 120.4], monotonic=[0.0, 120.0])
    )

    with pytest.raises(anthropic.APITimeoutError):
        _create_message(client, model="claude-x")

    assert client.calls == 1


def test_non_timeout_errors_keep_their_tenacity_retry(monkeypatch: pytest.MonkeyPatch) -> None:
    # The sleep path must not disturb the transient classes: a 429 is still
    # retried by tenacity, on the real clock, and still succeeds on a later
    # attempt. (Real `time` here on purpose: no timeout, so nothing samples it.)
    from mp.summarize import _create_message

    monkeypatch.setattr("mp.summarize._create_message.retry.wait", lambda *_a, **_k: 0)
    client = _FakeAnthropic([
        _anthropic_status_error(anthropic.RateLimitError, 429),
        _anthropic_status_error(anthropic.InternalServerError, 500),
        "answer",
    ])

    assert _create_message(client, model="claude-x") == "answer"
    assert client.calls == 3


# ----- PIPE12: one sampling temperature, on every backend -----

@contextmanager
def _anthropic_transport(body: dict) -> Iterator[list[dict]]:
    """Route every `httpx.Client` through a MockTransport that records the request
    body and answers with `body`. The transport is the seam because the Anthropic
    SDK builds its own client; neither call site takes an injectable one, and
    reshaping them for a test would be the test dictating the design."""
    seen: list[dict] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(json.loads(request.content))
        return httpx.Response(200, request=request, json=body)

    real_init = httpx.Client.__init__

    def patched_init(self: httpx.Client, *args: Any, **kwargs: Any) -> None:
        kwargs["transport"] = httpx.MockTransport(handler)
        real_init(self, *args, **kwargs)

    with patch.object(httpx.Client, "__init__", patched_init):
        yield seen


def _message_response(content: list[dict], stop_reason: str) -> dict:
    return {
        "id": "msg_01",
        "type": "message",
        "role": "assistant",
        "model": "claude-x",
        "content": content,
        "stop_reason": stop_reason,
        "stop_sequence": None,
        "usage": {"input_tokens": 3, "output_tokens": 2},
    }


def test_the_shared_temperature_is_the_value_local_and_openai_already_sampled_at() -> None:
    # The number itself is the contract: every comparison surface in this product
    # (corrections A/B, `mp dogfood` scoring, FEAT10's evidence verifier) reads
    # runs against each other, so a backend sampling somewhere else measures the
    # sampler instead of the change under test.
    assert SAMPLING_TEMPERATURE == 0.2


def test_anthropic_summarize_request_pins_the_temperature() -> None:
    from mp.summarize import AnthropicSummaryClient

    summary = {
        "title": "Standup", "summary": ["A point."], "decisions": [], "actions": [],
        "questions": [], "attendees": ["Alice"], "detected_language": "en",
    }
    body = _message_response(
        [{"type": "tool_use", "id": "toolu_01", "name": "emit_meeting_summary", "input": summary}],
        "tool_use",
    )
    with _anthropic_transport(body) as seen:
        out = AnthropicSummaryClient(api_key="sk-test").summarize(
            system_prompt="Summarize.", transcript="A: hello.",
            model="claude-x", max_tokens=512,
        )

    assert out.title == "Standup"
    assert seen[0]["temperature"] == SAMPLING_TEMPERATURE


# ----- PIPE15: the schema-violation retry replays the failure -----

@contextmanager
def _anthropic_transport_sequence(bodies: list[dict]) -> Iterator[list[dict]]:
    """`_anthropic_transport`, but answering a different body per request, so a
    two-attempt round trip can be driven end to end: a malformed first reply, a
    well-formed second. The last body repeats if the client asks again."""
    seen: list[dict] = []

    def handler(request: httpx.Request) -> httpx.Response:
        body = bodies[min(len(seen), len(bodies) - 1)]
        seen.append(json.loads(request.content))
        return httpx.Response(200, request=request, json=body)

    real_init = httpx.Client.__init__

    def patched_init(self: httpx.Client, *args: Any, **kwargs: Any) -> None:
        kwargs["transport"] = httpx.MockTransport(handler)
        real_init(self, *args, **kwargs)

    with patch.object(httpx.Client, "__init__", patched_init):
        yield seen


def _tool_use_body(summary: dict) -> dict:
    return _message_response(
        [{"type": "tool_use", "id": "toolu_01", "name": "emit_meeting_summary", "input": summary}],
        "tool_use",
    )


def test_anthropic_retry_replays_the_validation_error_instead_of_repeating_itself() -> None:
    # The whole PIPE15 defect: both attempts built a byte-identical payload, so
    # the model had no way to know it had failed. Two of the three real
    # occurrences recovered only because the blind re-roll happened to come back
    # well-formed, at the cost of a second paid call.
    from mp.summarize import AnthropicSummaryClient

    good = {
        "title": "Standup", "summary": ["A point."], "decisions": [], "actions": [],
        "questions": [], "attendees": ["Alice"], "detected_language": "en",
    }
    # `title` over its 120-char cap: a content-level violation the decode in
    # `normalize_model_summary` deliberately cannot repair, so the retry is what
    # has to carry the fix.
    bad = {**good, "title": "x" * 200}

    with _anthropic_transport_sequence([_tool_use_body(bad), _tool_use_body(good)]) as seen:
        out = AnthropicSummaryClient(api_key="sk-test").summarize(
            system_prompt="Summarize.", transcript="A: hello.",
            model="claude-x", max_tokens=512,
        )

    assert out.title == "Standup"
    assert len(seen) == 2
    first = seen[0]["messages"][0]["content"]
    second = seen[1]["messages"][0]["content"]
    assert second != first, "attempt 2 re-issued an identical request"
    assert "title" in second, "attempt 2 does not name the field that failed"
    assert "rejected" in second
    # The transcript stays in the retry: a content-level violation cannot be
    # fixed from the error text alone.
    assert "A: hello." in second


def test_anthropic_first_attempt_carries_no_repair_preamble() -> None:
    # The repair text is retry-only, so a normal run pays nothing for it.
    from mp.summarize import summary_request

    first = summary_request("A: hello.")
    assert "rejected" not in first
    assert first == summary_request("A: hello.", retry_error=None)


def test_anthropic_missing_tool_block_also_feeds_the_retry() -> None:
    # A reply with no tool_use block is the same class of failure and used to
    # re-issue the same request too.
    from mp.summarize import AnthropicSummaryClient

    good = {
        "title": "Standup", "summary": ["A point."], "decisions": [], "actions": [],
        "questions": [], "attendees": [], "detected_language": "en",
    }
    empty = _message_response([{"type": "text", "text": "sorry"}], "end_turn")

    with _anthropic_transport_sequence([empty, _tool_use_body(good)]) as seen:
        out = AnthropicSummaryClient(api_key="sk-test").summarize(
            system_prompt="Summarize.", transcript="A: hello.",
            model="claude-x", max_tokens=512,
        )

    assert out.title == "Standup"
    assert "No tool_use block" in seen[1]["messages"][0]["content"]


def test_anthropic_stringified_section_needs_no_retry_at_all() -> None:
    # The shared coercion means the shape that fired three times on the real
    # corpus now validates on attempt 1, so it costs no second paid call.
    from mp.summarize import AnthropicSummaryClient

    stringified = {
        "title": "Standup", "summary": json.dumps(["A point.", "Another."]),
        "decisions": [], "actions": [], "questions": [], "attendees": [],
        "detected_language": "en",
    }

    with _anthropic_transport_sequence([_tool_use_body(stringified)]) as seen:
        out = AnthropicSummaryClient(api_key="sk-test").summarize(
            system_prompt="Summarize.", transcript="A: hello.",
            model="claude-x", max_tokens=512,
        )

    assert out.summary == ["A point.", "Another."]
    assert len(seen) == 1, "a repairable shape still cost a second call"


def test_anthropic_free_form_request_pins_the_same_temperature() -> None:
    # `engine.AnthropicTextClient` is the free-form sibling behind ask / digest /
    # classify. It carried no temperature either, so the default backend answered
    # the same question differently every time it was asked.
    from mp.engine import AnthropicTextClient

    body = _message_response([{"type": "text", "text": "an answer"}], "end_turn")
    with _anthropic_transport(body) as seen:
        text = AnthropicTextClient(api_key="sk-test", model="claude-x").complete(
            system_prompt="Answer.", user_message="a question", max_tokens=64,
        )

    assert text == "an answer"
    assert seen[0]["temperature"] == SAMPLING_TEMPERATURE
