"""The one implementation of the `auto` backend ladder: try cloud, fall back to local.

Before PIPE7 this ladder existed three times with diverging semantics:
`summarize._AutoFallbackClient` caught a named set of Anthropic transport
errors, `engine.complete_text` caught bare `Exception`, and
`diarize_cleanup._select_cleanup_backend` did no runtime fallback at all
despite a docstring claiming it mirrored summarize. Summarize and engine now
both route through `run_with_local_fallback` below; diarize_cleanup keeps its
cheaper key-presence rule and says so.

Zero-egress note: this helper never decides *whether* cloud is allowed. That is
`config.effective_backend`, which forces `local` under regulated / NDA long
before `auto` is reachable here. A caller that reaches this function has
already been cleared to talk to Anthropic.
"""
from __future__ import annotations

import logging
import os
from collections.abc import Callable
from typing import TypeVar

log = logging.getLogger("mp.backend_fallback")

T = TypeVar("T")


def fallback_exceptions() -> tuple[type[BaseException], ...]:
    """Anthropic failures that mean "the cloud is unreachable or unwilling",
    as opposed to "the caller passed something wrong".

    Only the former earns a silent drop to local. A `BadRequestError` or a
    schema `ValidationError` is a bug that a second model will not fix, so it
    propagates. `APITimeoutError` subclasses `APIConnectionError`; it is listed
    explicitly because that inheritance is easy to forget and load-bearing here.

    `anthropic` is imported lazily so that importing this module (and therefore
    `engine`) stays free for callers that never make a cloud call.
    """
    import anthropic

    return (
        anthropic.APIConnectionError,
        anthropic.APITimeoutError,
        anthropic.AuthenticationError,
        anthropic.PermissionDeniedError,
        anthropic.RateLimitError,
        anthropic.InternalServerError,
    )


def run_with_local_fallback(*, cloud: Callable[[], T], local: Callable[[], T]) -> tuple[T, str]:
    """Run `cloud()`, falling back to `local()` on an unreachable-cloud failure.

    Returns `(result, backend)` where backend is "anthropic" or "local", so the
    caller can attribute the run without inspecting which callable answered.

    `ANTHROPIC_API_KEY` is read directly rather than through `require_env`: that
    helper exits the process on a miss, which would defeat the whole point of a
    fallback. A missing key is the ordinary no-cloud-configured case, not an
    error, so it takes the local branch without a warning-level log.
    """
    if not os.environ.get("ANTHROPIC_API_KEY", ""):
        log.info("ANTHROPIC_API_KEY not set; using local backend")
        return local(), "local"

    try:
        return cloud(), "anthropic"
    except fallback_exceptions() as e:
        # A sustained 429 / 5xx has already exhausted the caller's own backoff
        # (summarize._create_message); a busy Anthropic should drop to local
        # rather than fail the whole run.
        log.warning("Anthropic backend failed (%s); falling back to local", e)

    return local(), "local"
