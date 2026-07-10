"""Tests for `summarize._select_backend` and the regulated+local
zero-egress contract.

The egress test does not block at the OS level (that would need root
or a network namespace). Instead it patches `httpx.Client.send` and
the `anthropic.Anthropic` constructor so any non-localhost outbound
call fails the test loudly. That covers both the explicit Anthropic
SDK path and any hidden httpx call inside summarize.py.
"""
from __future__ import annotations

from typing import Any
from unittest.mock import patch

import anthropic
import httpx
import pytest

from mp.config import Config
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
    # require_env raises SystemExit(2) by design (fail-fast for missing
    # secrets at the top of the pipeline). _select_backend bubbles that
    # out unchanged for the explicit "anthropic" mode. The auto-fallback
    # mode reads os.environ directly so it can fall back instead.
    cfg = _local_cfg("anthropic")
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    with pytest.raises(SystemExit):
        _select_backend(cfg)


def test_select_backend_unknown_raises() -> None:
    cfg = _local_cfg("local")
    cfg.summarization.backend = "made-up"  # type: ignore[assignment]
    with pytest.raises(ValueError):
        _select_backend(cfg)


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
