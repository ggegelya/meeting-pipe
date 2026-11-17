"""Process-wide egress firewall (TECH-SEC3, hardened by SEC13 and SEC19).

When armed, four things become true for the rest of the process:

1. Every outbound HTTP request through httpx to a non-loopback host raises
   `EgressBlocked` before a connection opens, and so does any httpx request whose
   transport is a proxy, whatever its URL host (SEC19: the host check reads the
   URL, not where a proxied transport actually connects). This is the layer the
   user sees, because it names the host. The Anthropic SDK, the Notion
   publisher, the local-model client and huggingface-hub 1.x all build httpx
   clients today.
2. Every `socket.connect` / `connect_ex` on an `AF_INET` / `AF_INET6` socket to
   an address that is not loopback raises `EgressBlocked` (SEC19). This is the
   library-agnostic backstop: `http.client`, `urllib`, `requests`/urllib3,
   httpcore and an `httpx2` client all end in it, so a dependency that changes
   HTTP stacks is still fenced. A hostname is resolved once and allowed only when
   every answer is loopback, and the connect then goes to the checked address, not
   the name. `AF_UNIX` and other families pass untouched. Not covered: an
   unconnected UDP `sendto`, and a socket created by C code that never calls the
   Python method. DNS lookups themselves are not gated; they carry no meeting
   content.
3. The managed cloud tokens are removed from `os.environ` and `load_secrets()`
   stops refilling them, so a consumer that reads only the environment fails
   closed on a missing credential rather than egressing.
4. `HF_HUB_OFFLINE` / `HF_HUB_DISABLE_TELEMETRY` are set, so huggingface_hub
   (mlx_embeddings, `mlx_lm.server`'s model load) refuses to fetch, and every
   `*_proxy` variable is dropped with `NO_PROXY=*` set (SEC19). A forwarder
   listening on 127.0.0.1 passes the socket check of (2), since that connect
   really is loopback, so the environment is what keeps urllib and httpx from
   routing through one; `NO_PROXY=*` also stops both reading the macOS system
   web proxy. One caveat: urllib's module-level opener keeps the proxies it read
   on first use, so a `urlopen` made before `arm()` would keep its proxy. Nothing
   in `mp` calls `urlopen`, and entry points arm first.

Both patches are installed lazily on the first `arm()` and gate on a module-level
flag, so `disarm()` (used by tests) leaves inert pass-throughs rather than
unpatching.

(3) and (4) also cover subprocesses, which inherit the scrubbed environment; a
socket patch cannot reach a child. `child_env()` makes that explicit for spawn
sites that pass `env=` rather than relying on inheritance, so a token re-added
to `os.environ` after arming still cannot reach a child.

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
import socket
from collections.abc import Callable
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from .config import Config

log = logging.getLogger("mp.egress_guard")

# Hostnames that resolve to the local machine. IP literals are checked
# structurally via `ipaddress`; these are the names that need a lookup table.
_LOOPBACK_HOSTNAMES = frozenset({"localhost"})

# Forced into the environment on arm(): huggingface_hub refuses to fetch a model
# or phone home, and (SEC19) no client consults an env or macOS system proxy.
_OFFLINE_ENV = {
    "HF_HUB_OFFLINE": "1",
    "HF_HUB_DISABLE_TELEMETRY": "1",
    "NO_PROXY": "*",
    "no_proxy": "*",
}

_armed = False
_patched = False
# The real httpx transport handlers, captured on first arm() and called through
# to when a request is permitted. Module-level (not closure-local) so the patch
# is installed exactly once and tests can stub the downstream without sockets.
# The guarded wrappers therefore read them at call time, never at definition time.
_orig_sync: Callable[..., Any] | None = None
_orig_async: Callable[..., Any] | None = None
# The real `socket.socket.connect` / `connect_ex` (SEC19), same contract.
_orig_connect: Callable[..., Any] | None = None
_orig_connect_ex: Callable[..., Any] | None = None


class EgressBlocked(RuntimeError):
    """Raised when a non-loopback request is attempted while the guard is armed
    (regulated_mode or workflow_nda_mode)."""


def _ip_is_loopback(host: str) -> bool | None:
    """Whether an IP literal is loopback; None when `host` is not an IP literal.
    An IPv4-mapped IPv6 address is judged by the IPv4 address it carries."""
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        return None
    if isinstance(ip, ipaddress.IPv6Address) and ip.ipv4_mapped is not None:
        return ip.ipv4_mapped.is_loopback
    return ip.is_loopback


def _is_loopback(host: str | None) -> bool:
    if not host:
        return False
    if host in _LOOPBACK_HOSTNAMES:
        return True
    return bool(_ip_is_loopback(host))


def _is_proxied(transport: Any) -> bool:
    """Whether an httpx transport sends through a proxy (SEC19). A transport with
    no connection pool to inspect counts as proxied: the armed guard cannot tell
    where it connects, so it fails closed."""
    import httpcore

    pool = getattr(transport, "_pool", None)
    if pool is None:
        return True
    return isinstance(
        pool,
        (httpcore.HTTPProxy, httpcore.SOCKSProxy, httpcore.AsyncHTTPProxy, httpcore.AsyncSOCKSProxy),
    )


def _is_proxy_key(key: str) -> bool:
    lowered = key.lower()
    return lowered.endswith("_proxy") and lowered != "no_proxy"


def _checked_address(sock: socket.socket, address: Any) -> Any:
    """The address an armed connect may go to, or `EgressBlocked` (SEC19).

    An IP literal is judged directly. A name is resolved once and allowed only
    when every answer is loopback; the first answer is returned so the connect
    goes to the address that was checked rather than resolving the name again.
    A resolution failure raises the resolver's own `OSError`, which is what the
    connect would have raised anyway, and nothing has left the machine."""
    if not _armed or sock.family not in (socket.AF_INET, socket.AF_INET6):
        return address
    host = address[0] if isinstance(address, tuple) and address else None
    if not isinstance(host, str):
        raise EgressBlocked(f"connect to {address!r} blocked by the regulated/NDA egress guard")
    literal = _ip_is_loopback(host)
    if literal is True:
        return address
    if literal is False:
        raise EgressBlocked(f"connect to {host!r} blocked by the regulated/NDA egress guard")
    answers = socket.getaddrinfo(host, address[1], sock.family, sock.type)
    if not answers or not all(_ip_is_loopback(str(a[4][0])) for a in answers):
        raise EgressBlocked(
            f"connect to {host!r} blocked by the regulated/NDA egress guard "
            "(it does not resolve to loopback only)"
        )
    return answers[0][4]


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
    for key in [k for k in os.environ if _is_proxy_key(k)]:
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
    for key in [k for k in env if _is_proxy_key(k)]:
        env.pop(key, None)
    env.update(_OFFLINE_ENV)
    return env


def arm(reason: str = "regulated/nda") -> None:
    """Block all non-loopback egress process-wide. Idempotent: installs the
    httpx transport and socket patches on the first call, flips the flag and
    re-scrubs the environment on every call."""
    global _armed, _patched, _orig_sync, _orig_async, _orig_connect, _orig_connect_ex
    _armed = True
    _scrub_environment()
    if _patched:
        return

    import httpx

    _orig_sync = httpx.HTTPTransport.handle_request
    _orig_async = httpx.AsyncHTTPTransport.handle_async_request

    def _refuse(transport: Any, request: httpx.Request) -> None:
        if not _armed:
            return
        if not _is_loopback(request.url.host):
            raise EgressBlocked(
                f"egress to {request.url.host!r} blocked by the regulated/NDA egress guard"
            )
        if _is_proxied(transport):
            raise EgressBlocked(
                f"proxied request to {request.url.host!r} blocked by the regulated/NDA "
                "egress guard (a proxy is where the bytes would go)"
            )

    def _guarded_sync(self: httpx.HTTPTransport, request: httpx.Request) -> httpx.Response:
        _refuse(self, request)
        handler = _orig_sync  # read at call time: tests stub the global
        if handler is None:  # pragma: no cover - arm() sets it before installing us
            raise EgressBlocked("egress guard installed without capturing the real transport")
        return handler(self, request)

    async def _guarded_async(self: httpx.AsyncHTTPTransport, request: httpx.Request) -> httpx.Response:
        _refuse(self, request)
        handler = _orig_async  # read at call time: tests stub the global
        if handler is None:  # pragma: no cover - arm() sets it before installing us
            raise EgressBlocked("egress guard installed without capturing the real transport")
        return await handler(self, request)

    httpx.HTTPTransport.handle_request = _guarded_sync  # type: ignore[method-assign]
    httpx.AsyncHTTPTransport.handle_async_request = _guarded_async  # type: ignore[method-assign]

    _orig_connect = socket.socket.connect
    _orig_connect_ex = socket.socket.connect_ex

    def _guarded_connect(self: socket.socket, address: Any) -> None:
        target = _checked_address(self, address)
        handler = _orig_connect  # read at call time: tests stub the global
        if handler is None:  # pragma: no cover - arm() sets it before installing us
            raise EgressBlocked("egress guard installed without capturing socket.connect")
        return handler(self, target)

    def _guarded_connect_ex(self: socket.socket, address: Any) -> int:
        target = _checked_address(self, address)
        handler = _orig_connect_ex  # read at call time: tests stub the global
        if handler is None:  # pragma: no cover - arm() sets it before installing us
            raise EgressBlocked("egress guard installed without capturing socket.connect_ex")
        return handler(self, target)

    socket.socket.connect = _guarded_connect  # type: ignore[method-assign]
    socket.socket.connect_ex = _guarded_connect_ex  # type: ignore[method-assign]
    _patched = True
    log.info(
        "egress guard armed (%s): non-loopback HTTP and sockets are blocked, proxies "
        "refused, cloud tokens scrubbed, huggingface_hub offline", reason
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
