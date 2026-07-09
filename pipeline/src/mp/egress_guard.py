"""Process-wide egress firewall (TECH-SEC3, hardened by SEC13).

When armed, three things become true for the rest of the process:

1. Every outbound HTTP request to a non-loopback host raises `EgressBlocked`
   before the connection opens. httpx is the single in-process chokepoint: the
   Anthropic SDK, the Notion publisher, and the local-model client all route
   through httpx's default transport classes, so patching those classes once
   covers every present and future sink. The patch is installed lazily on the
   first `arm()` and gates on a module-level flag, so `disarm()` (used by
   tests) leaves an inert pass-through rather than unpatching.
2. The managed cloud tokens are removed from `os.environ` and `load_secrets()`
   stops refilling them, so a consumer that reads only the environment fails
   closed on a missing credential rather than egressing.
3. `HF_HUB_OFFLINE` / `HF_HUB_DISABLE_TELEMETRY` are set, so huggingface_hub
   (used by mlx_embeddings and by `mlx_lm.server`'s model load) refuses to
   fetch. That stack speaks `requests`, not httpx, so the transport patch of
   (1) never sees it; the env is the only lever that reaches it.

(2) and (3) also cover subprocesses, which inherit the scrubbed environment.
`child_env()` makes that explicit for spawn sites that pass `env=` rather than
relying on inheritance, so a token re-added to `os.environ` after arming still
cannot reach a child.

Entry points arm the guard via `arm_for_config(cfg)` right after the workflow
overlay is applied, when the resolved config is regulated or carries the
per-meeting `workflow_nda_mode`. `mp.entry.prepare` is the shared helper that
gets the ordering right; use it rather than hand-rolling the sequence.

Deliberately NOT armed: `mp prefetch-model`, whose whole purpose is to fetch a
model over the network so a later zero-egress run finds it cached. It is the
escape hatch the fail-closed message in `summarize_local._spawn` points at.
"""
from __future__ import annotations

import ipaddress
import logging
import os
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from .config import Config

log = logging.getLogger("mp.egress_guard")

# Hostnames that resolve to the local machine. IP literals are checked
# structurally via `ipaddress`; these are the names that need a lookup table.
_LOOPBACK_HOSTNAMES = frozenset({"localhost"})

# Forced into the environment on arm() so the huggingface_hub / requests stack,
# which the httpx patch cannot see, refuses to fetch a model or phone home.
_OFFLINE_ENV = {
    "HF_HUB_OFFLINE": "1",
    "HF_HUB_DISABLE_TELEMETRY": "1",
}

_armed = False
_patched = False
# The real httpx transport handlers, captured on first arm() and called through
# to when a request is permitted. Module-level (not closure-local) so the patch
# is installed exactly once and tests can stub the downstream without sockets.
_orig_sync = None
_orig_async = None


class EgressBlocked(RuntimeError):
    """Raised when a non-loopback request is attempted while the guard is armed
    (regulated_mode or workflow_nda_mode)."""


def _is_loopback(host: str | None) -> bool:
    if not host:
        return False
    if host in _LOOPBACK_HOSTNAMES:
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def is_armed() -> bool:
    return _armed


def disarm() -> None:
    """Lift the block (leaves the transport patch installed but inert).
    Production arms once at entry and never disarms; this exists for tests."""
    global _armed
    _armed = False


def _scrub_environment() -> None:
    """Drop the managed cloud tokens and force huggingface_hub offline (SEC13).

    Runs on every `arm()`, not just the first, because a caller may have loaded
    secrets between two arms. Popping is safe: under zero egress every consumer
    of these tokens is already unreachable (`effective_backend` pins local,
    `effective_sinks` drops Notion), so a token that is still read here is a
    regression, and `require_env` failing closed is the outcome we want.
    """
    from .config import MANAGED_SECRET_KEYS
    for key in MANAGED_SECRET_KEYS:
        os.environ.pop(key, None)
    os.environ.update(_OFFLINE_ENV)


def child_env(base: dict[str, str] | None = None) -> dict[str, str]:
    """The environment to hand a spawned child (SEC13).

    A copy of `base` (default `os.environ`), scrubbed when the guard is armed.
    Redundant with the `arm()` scrub while nothing re-adds a token, and that
    redundancy is the point: this is what a subprocess boundary sees, so the
    child cannot inherit a credential the parent picked up after arming.
    """
    env = dict(base if base is not None else os.environ)
    if not _armed:
        return env
    from .config import MANAGED_SECRET_KEYS
    for key in MANAGED_SECRET_KEYS:
        env.pop(key, None)
    env.update(_OFFLINE_ENV)
    return env


def arm(reason: str = "regulated/nda") -> None:
    """Block all non-loopback egress process-wide. Idempotent: installs the
    httpx transport patch on the first call, flips the flag and re-scrubs the
    environment on every call."""
    global _armed, _patched, _orig_sync, _orig_async
    _armed = True
    _scrub_environment()
    if _patched:
        return

    import httpx

    _orig_sync = httpx.HTTPTransport.handle_request
    _orig_async = httpx.AsyncHTTPTransport.handle_async_request

    def _guarded_sync(self: httpx.HTTPTransport, request: httpx.Request) -> httpx.Response:
        if _armed and not _is_loopback(request.url.host):
            raise EgressBlocked(
                f"egress to {request.url.host!r} blocked by the regulated/NDA egress guard"
            )
        return _orig_sync(self, request)

    async def _guarded_async(self: httpx.AsyncHTTPTransport, request: httpx.Request) -> httpx.Response:
        if _armed and not _is_loopback(request.url.host):
            raise EgressBlocked(
                f"egress to {request.url.host!r} blocked by the regulated/NDA egress guard"
            )
        return await _orig_async(self, request)

    httpx.HTTPTransport.handle_request = _guarded_sync  # type: ignore[method-assign]
    httpx.AsyncHTTPTransport.handle_async_request = _guarded_async  # type: ignore[method-assign]
    _patched = True
    log.info(
        "egress guard armed (%s): non-loopback HTTP is blocked, cloud tokens "
        "scrubbed, huggingface_hub offline", reason
    )


def arm_for_config(cfg: Config) -> bool:
    """Arm the guard iff the resolved config forbids cloud egress. Returns
    whether it armed. Call at every pipeline entry right after the workflow
    overlay is applied, so no command path can reach a sink without the clamp in
    place; `mp.entry.prepare` does this for you."""
    from .config import zero_egress
    if zero_egress(cfg):
        arm("regulated_mode" if cfg.modes.regulated_mode else "workflow_nda_mode")
        return True
    return False
