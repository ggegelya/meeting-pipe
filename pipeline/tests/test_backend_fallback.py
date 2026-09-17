"""Tests for the one cloud-then-local `auto` ladder (PIPE7).

`summarize._AutoFallbackClient` and `engine.complete_text` both route through
`run_with_local_fallback`, so the policy is pinned once here and the two call
sites only pin their own wiring.
"""
from __future__ import annotations

import anthropic
import httpx
import pytest

from mp.backend_fallback import (
    fallback_exceptions,
    is_billing_exhaustion,
    run_with_local_fallback,
)

_REQ = httpx.Request("POST", "https://api.anthropic.com/v1/messages")

# Verbatim from the 2026-09-07 / 2026-09-08 failures: Anthropic reports an
# exhausted prepaid balance as a 400 invalid_request_error, the same status a
# malformed request gets, so the message is the only thing that tells them apart.
_CREDIT_BODY = {
    "type": "error",
    "error": {
        "type": "invalid_request_error",
        "message": "Your credit balance is too low to access the Anthropic API. "
        "Please go to Plans & Billing to upgrade or purchase credits.",
    },
}


def _status_error(cls: type[anthropic.APIStatusError], code: int) -> anthropic.APIStatusError:
    return cls("boom", response=httpx.Response(code, request=_REQ), body=None)


def _credit_exhausted() -> anthropic.BadRequestError:
    return anthropic.BadRequestError(
        f"Error code: 400 - {_CREDIT_BODY}",
        response=httpx.Response(400, request=_REQ),
        body=_CREDIT_BODY,
    )


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


def test_exhausted_credit_falls_back_to_local_despite_being_a_400(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # The 2026-09-07 failures: four meetings lost their summaries to a 400 that
    # meant "no credit left", which is the cloud being unwilling, not a caller
    # bug. Under `auto` that earns the local branch like a 401 does.
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")

    def _cloud() -> str:
        raise _credit_exhausted()

    assert run_with_local_fallback(cloud=_cloud, local=lambda: "local") == ("local", "local")


def test_billing_exhaustion_is_the_message_not_the_status() -> None:
    # A plain 400 keeps propagating (pinned above); only the credit message
    # opts a BadRequestError into the ladder.
    assert is_billing_exhaustion(_credit_exhausted())
    assert not is_billing_exhaustion(_status_error(anthropic.BadRequestError, 400))
    assert not is_billing_exhaustion(_status_error(anthropic.AuthenticationError, 401))
