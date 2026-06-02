"""Process-wide HTTP egress firewall (TECH-SEC3).

When armed, every outbound HTTP request to a non-loopback host raises
`EgressBlocked` before the connection opens. This is the structural backstop
behind the per-sink regulated / NDA clamps: even a future code path that forgets
to check the flag cannot transmit off-device while the guard is armed.

httpx is the single chokepoint. The Anthropic SDK, the Notion publisher, and the
local-model client all route through httpx's default transport classes, so
patching those classes once covers every present and future sink. The patch is
installed lazily on the first `arm()` and gates on a module-level flag, so
`disarm()` (used by tests) leaves an inert pass-through rather than unpatching.

Entry points arm the guard via `arm_for_config(cfg)` right after the workflow
overlay is applied, when the resolved config is regulated or carries the
per-meeting `workflow_nda_mode`.
"""
from __future__ import annotations

import ipaddress
import logging
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from .config import Config

log = logging.getLogger("mp.egress_guard")

# Hostnames that resolve to the local machine. IP literals are checked
# structurally via `ipaddress`; these are the names that need a lookup table.
_LOOPBACK_HOSTNAMES = frozenset({"localhost"})

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


def arm(reason: str = "regulated/nda") -> None:
    """Block all non-loopback HTTP egress process-wide. Idempotent: installs the
    httpx transport patch on the first call, flips the flag on every call."""
    global _armed, _patched, _orig_sync, _orig_async
    _armed = True
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
    log.info("egress guard armed (%s): non-loopback HTTP is blocked", reason)


def arm_for_config(cfg: Config) -> bool:
    """Arm the guard iff the resolved config forbids egress (global
    `regulated_mode` or the per-meeting `workflow_nda_mode`). Returns whether it
    armed. Call at every pipeline entry right after the workflow overlay is
    applied, so no command path can reach a sink without the clamp in place."""
    if cfg.modes.regulated_mode or cfg.modes.workflow_nda_mode:
        arm("regulated_mode" if cfg.modes.regulated_mode else "workflow_nda_mode")
        return True
    return False
