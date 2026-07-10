"""Tests for the one cloud-then-local `auto` ladder (PIPE7).

`summarize._AutoFallbackClient` and `engine.complete_text` both route through
`run_with_local_fallback`, so the policy is pinned once here and the two call
sites only pin their own wiring.
"""
from __future__ import annotations

import anthropic
import httpx
import pytest

from mp.backend_fallback import fallback_exceptions, run_with_local_fallback

_REQ = httpx.Request("POST", "https://api.anthropic.com/v1/messages")


def _status_error(cls: type[anthropic.APIStatusError], code: int) -> anthropic.APIStatusError:
    return cls("boom", response=httpx.Response(code, request=_REQ), body=None)


def test_no_key_takes_the_local_branch_without_calling_cloud(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)

    def _cloud() -> str:
        raise AssertionError("cloud must not be called without a key")

    assert run_with_local_fallback(cloud=_cloud, local=lambda: "local") == ("local", "local")


def test_cloud_answers_when_it_can(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")

    def _local() -> str:
        raise AssertionError("local must not be called when cloud succeeds")

    assert run_with_local_fallback(cloud=lambda: "cloud", local=_local) == ("cloud", "anthropic")


@pytest.mark.parametrize(
    "exc",
    [
        anthropic.APIConnectionError(request=_REQ),
        anthropic.APITimeoutError(request=_REQ),
        _status_error(anthropic.AuthenticationError, 401),
        _status_error(anthropic.PermissionDeniedError, 403),
        _status_error(anthropic.RateLimitError, 429),
        _status_error(anthropic.InternalServerError, 500),
    ],
    ids=["connection", "timeout", "auth_401", "permission_403", "rate_limit_429", "server_500"],
)
def test_unreachable_cloud_falls_back_to_local(
    monkeypatch: pytest.MonkeyPatch, exc: BaseException
) -> None:
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")

    def _cloud() -> str:
        raise exc

    assert run_with_local_fallback(cloud=_cloud, local=lambda: "local") == ("local", "local")


@pytest.mark.parametrize(
    "exc",
    [
        _status_error(anthropic.BadRequestError, 400),
        _status_error(anthropic.NotFoundError, 404),
        ValueError("caller bug"),
    ],
    ids=["bad_request_400", "not_found_404", "caller_bug"],
)
def test_caller_bugs_propagate_instead_of_degrading(
    monkeypatch: pytest.MonkeyPatch, exc: BaseException
) -> None:
    # A second model will not fix a malformed request; silently answering from
    # local would hide the bug and misattribute the run.
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")

    def _cloud() -> str:
        raise exc

    def _local() -> str:
        raise AssertionError("local must not be reached on a caller bug")

    with pytest.raises(type(exc)):
        run_with_local_fallback(cloud=_cloud, local=_local)


def test_timeout_is_covered_despite_subclassing_connection_error() -> None:
    # APITimeoutError subclasses APIConnectionError. The explicit listing is
    # belt-and-braces; this asserts the coverage rather than the listing.
    assert isinstance(anthropic.APITimeoutError(request=_REQ), fallback_exceptions())
