"""Tests for the process-wide egress firewall (TECH-SEC3, hardened by SEC13).

These drive real `httpx.Client` / `httpx.AsyncClient` instances through the
default transport (the path the Anthropic SDK and the Notion publisher take),
but stub the guard's downstream (`_orig_sync` / `_orig_async`) so a permitted
request lands on a fake instead of a real socket. The block path short-circuits
before the transport, so it never opens a connection either.

The SEC13 tests below cover the process environment, which a spawned child
inherits and the huggingface_hub offline flags live in. The SEC19 tests cover
the socket layer under every client that is not httpx, and proxies.
"""
from __future__ import annotations

import asyncio
import os
import socket
import sys
import tempfile
import urllib.request
from typing import Any

import httpx
import pytest

from mp import egress_guard
from mp.config import MANAGED_SECRET_KEYS, Config, load_secrets
from mp.egress_guard import EgressBlocked


def _ok(self: Any, request: httpx.Request) -> httpx.Response:
    return httpx.Response(200, request=request, json={"ok": True})


def test_blocks_non_loopback_when_armed(monkeypatch: pytest.MonkeyPatch) -> None:
    egress_guard.arm("test")
    # If the guard were to fall through, this would fail the test loudly rather
    # than make a real request.
    monkeypatch.setattr(egress_guard, "_orig_sync",
                        lambda s, r: pytest.fail("egress reached the transport"))
    assert egress_guard.is_armed()
    with httpx.Client() as client, pytest.raises(EgressBlocked):
        client.get("https://api.notion.com/v1/search")


def test_blocks_non_loopback_async_when_armed(monkeypatch: pytest.MonkeyPatch) -> None:
    egress_guard.arm("test")
    monkeypatch.setattr(egress_guard, "_orig_async",
                        lambda s, r: pytest.fail("async egress reached the transport"))

    async def _go() -> None:
        async with httpx.AsyncClient() as client:
            await client.get("https://api.anthropic.com/v1/messages")

    with pytest.raises(EgressBlocked):
        asyncio.run(_go())


def test_loopback_passes_through_when_armed(monkeypatch: pytest.MonkeyPatch) -> None:
    egress_guard.arm("test")
    monkeypatch.setattr(egress_guard, "_orig_sync", _ok)
    with httpx.Client() as client:
        resp = client.get("http://127.0.0.1:8765/v1/health")
    assert resp.status_code == 200  # the local model endpoint is never blocked


def test_disarmed_passes_everything_through(monkeypatch: pytest.MonkeyPatch) -> None:
    egress_guard.arm("test")
    egress_guard.disarm()
    assert not egress_guard.is_armed()
    monkeypatch.setattr(egress_guard, "_orig_sync", _ok)
    # Disarmed: even a non-loopback host reaches the transport (no EgressBlocked).
    with httpx.Client() as client:
        resp = client.get("https://api.notion.com/v1/search")
    assert resp.status_code == 200


def test_is_loopback_classification() -> None:
    assert egress_guard._is_loopback("127.0.0.1")
    assert egress_guard._is_loopback("localhost")
    assert egress_guard._is_loopback("::1")
    assert not egress_guard._is_loopback("api.notion.com")
    assert not egress_guard._is_loopback("10.0.0.5")
    assert not egress_guard._is_loopback("")
    assert not egress_guard._is_loopback(None)


def test_arm_for_config_arms_under_regulated() -> None:
    cfg = Config.model_validate({"modes": {"regulated_mode": True}})
    assert egress_guard.arm_for_config(cfg) is True
    assert egress_guard.is_armed()


def test_arm_for_config_arms_under_workflow_nda() -> None:
    cfg = Config.model_validate({"modes": {"workflow_nda_mode": True}})
    assert egress_guard.arm_for_config(cfg) is True
    assert egress_guard.is_armed()


def test_arm_for_config_noop_when_unrestricted() -> None:
    cfg = Config()
    assert egress_guard.arm_for_config(cfg) is False
    assert not egress_guard.is_armed()


# ----- SEC13: the process boundary -----


def test_arm_scrubs_cloud_tokens_from_the_environment(monkeypatch: pytest.MonkeyPatch) -> None:
    for key in MANAGED_SECRET_KEYS:
        monkeypatch.setenv(key, "secret-value")
    egress_guard.arm("test")
    for key in MANAGED_SECRET_KEYS:
        assert key not in os.environ, f"{key} survived arm()"


def test_arm_forces_huggingface_offline(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("HF_HUB_OFFLINE", raising=False)
    egress_guard.arm("test")
    # The env is what reaches the `mlx_lm.server` child, which no in-process patch
    # does, and it stops hub fetching before any connect is attempted.
    assert os.environ["HF_HUB_OFFLINE"] == "1"
    assert os.environ["HF_HUB_DISABLE_TELEMETRY"] == "1"


def test_arm_rescrubs_on_every_call(monkeypatch: pytest.MonkeyPatch) -> None:
    """The httpx patch installs once and `arm()` early-returns after it, but the
    scrub must not be behind that early return: a caller can load secrets between
    two arms."""
    egress_guard.arm("first")
    monkeypatch.setenv("ANTHROPIC_API_KEY", "leaked-back-in")
    egress_guard.arm("second")
    assert "ANTHROPIC_API_KEY" not in os.environ


def test_child_env_is_scrubbed_when_armed() -> None:
    base = {"PATH": "/usr/bin", "ANTHROPIC_API_KEY": "k", "NOTION_TOKEN": "t", "HF_TOKEN": "h"}
    egress_guard.arm("test")
    env = egress_guard.child_env(base)
    assert env["PATH"] == "/usr/bin"
    assert "ANTHROPIC_API_KEY" not in env
    assert "NOTION_TOKEN" not in env
    assert "HF_TOKEN" not in env
    assert env["HF_HUB_OFFLINE"] == "1"
    # The caller's dict is never mutated.
    assert base["ANTHROPIC_API_KEY"] == "k"


def test_child_env_passes_through_when_disarmed() -> None:
    base = {"PATH": "/usr/bin", "ANTHROPIC_API_KEY": "k"}
    assert not egress_guard.is_armed()
    assert egress_guard.child_env(base) == base


def test_load_secrets_refills_when_disarmed(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    load_secrets(reader=lambda key: f"from-keychain-{key}")
    assert os.environ["ANTHROPIC_API_KEY"] == "from-keychain-ANTHROPIC_API_KEY"


def test_load_secrets_declines_to_refill_when_armed(monkeypatch: pytest.MonkeyPatch) -> None:
    """SEC13(b): the daemon strips the tokens for a zero-egress run (SEC5) and
    `load_secrets` used to hand them straight back from the Keychain, collapsing
    defense-in-depth to the single httpx layer."""
    monkeypatch.delenv("NOTION_TOKEN", raising=False)
    egress_guard.arm("test")
    load_secrets(reader=lambda key: pytest.fail("keychain read under a zero-egress run"))
    assert "NOTION_TOKEN" not in os.environ


def test_the_anthropic_sdk_still_sends_through_the_patched_httpx(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """CI8: the guard's httpx layer (the host-naming error and the proxy refusal)
    covers the Anthropic SDK only while the SDK speaks `httpx`. `anthropic` 1.0.0
    (2026-08-20) moved to `httpx2`, which only the SEC19 socket layer would see, and
    pyproject caps it `<1` until a deliberate lock bump. If a resolve ever crosses that
    line unflagged, this fails here.

    The type check comes first on purpose: the request below must not be the first
    thing to find out which client the SDK built.
    """
    import anthropic

    client = anthropic.Anthropic(api_key="test", max_retries=0)
    assert isinstance(client._client, httpx.Client), (
        f"the Anthropic SDK's HTTP client is {type(client._client).__mro__}, not httpx.Client; "
        "egress_guard does not patch it (see the anthropic cap in pipeline/pyproject.toml)"
    )

    egress_guard.arm("test")
    monkeypatch.setattr(egress_guard, "_orig_sync",
                        lambda s, r: pytest.fail("Anthropic egress reached the transport"))
    with pytest.raises(Exception) as raised:
        client.messages.create(
            model="claude-test", max_tokens=1, messages=[{"role": "user", "content": "x"}]
        )
    chain: list[BaseException] = []
    err: BaseException | None = raised.value
    while err is not None:
        chain.append(err)
        err = err.__cause__ or err.__context__
    assert any(isinstance(e, EgressBlocked) for e in chain), chain


# ----- SEC19: the socket layer, and proxies -----
#
# The tests below that open real sockets do so on loopback or AF_UNIX only: a
# listener the test owns, which is the one exception to "no real network
# sockets" the SEC19 spec asks for. Every block test stubs the guard's
# downstream connect to `pytest.fail`, so a miss can never reach the network.

_PUBLIC_IP = "93.184.216.34"


def _fail_connect(self: Any, address: Any) -> Any:
    pytest.fail(f"connect to {address!r} reached the real socket")


def _public_getaddrinfo(host: Any, port: Any, *args: Any, **kwargs: Any) -> list[Any]:
    return [(socket.AF_INET, socket.SOCK_STREAM, 6, "", (_PUBLIC_IP, port or 80))]


def _block_downstream(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(egress_guard, "_orig_connect", _fail_connect)
    monkeypatch.setattr(egress_guard, "_orig_connect_ex", _fail_connect)


@pytest.mark.guard_proof
def test_urllib_to_a_public_host_is_blocked_at_the_socket(monkeypatch: pytest.MonkeyPatch) -> None:
    """urllib never touches httpx, so before SEC19 nothing stopped it."""
    egress_guard.arm("test")
    _block_downstream(monkeypatch)
    monkeypatch.setattr(socket, "getaddrinfo", _public_getaddrinfo)
    with pytest.raises(EgressBlocked):
        urllib.request.urlopen("http://example.invalid/", timeout=1)


@pytest.mark.guard_proof
def test_raw_create_connection_to_a_public_ip_is_blocked(monkeypatch: pytest.MonkeyPatch) -> None:
    egress_guard.arm("test")
    _block_downstream(monkeypatch)
    with pytest.raises(EgressBlocked):
        socket.create_connection((_PUBLIC_IP, 80), timeout=1)


@pytest.mark.guard_proof
def test_connect_ex_to_a_public_ip_is_blocked(monkeypatch: pytest.MonkeyPatch) -> None:
    egress_guard.arm("test")
    _block_downstream(monkeypatch)
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s, pytest.raises(EgressBlocked):
        s.connect_ex((_PUBLIC_IP, 443))


@pytest.mark.guard_proof
def test_ipv4_mapped_public_address_is_blocked(monkeypatch: pytest.MonkeyPatch) -> None:
    egress_guard.arm("test")
    _block_downstream(monkeypatch)
    with socket.socket(socket.AF_INET6, socket.SOCK_STREAM) as s, pytest.raises(EgressBlocked):
        s.connect((f"::ffff:{_PUBLIC_IP}", 80, 0, 0))


@pytest.mark.guard_proof
def test_a_name_resolving_to_any_public_address_is_blocked(monkeypatch: pytest.MonkeyPatch) -> None:
    egress_guard.arm("test")
    _block_downstream(monkeypatch)

    def mixed(host: Any, port: Any, *a: Any, **k: Any) -> list[Any]:
        return [
            (socket.AF_INET, socket.SOCK_STREAM, 6, "", ("127.0.0.1", port)),
            (socket.AF_INET, socket.SOCK_STREAM, 6, "", (_PUBLIC_IP, port)),
        ]

    monkeypatch.setattr(socket, "getaddrinfo", mixed)
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s, pytest.raises(EgressBlocked):
        s.connect(("sometimes-local.example", 80))


@pytest.mark.guard_proof
def test_a_loopback_name_connects_to_the_address_it_was_checked_at(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Resolve once, check, connect to the checked address: handing the name back
    to connect() would resolve it a second time, and a rebinding answer could
    differ."""
    egress_guard.arm("test")
    seen: list[Any] = []
    monkeypatch.setattr(egress_guard, "_orig_connect", lambda s, a: seen.append(a))
    monkeypatch.setattr(
        socket, "getaddrinfo",
        lambda host, port, *a, **k: [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("127.0.0.1", port))],
    )
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.connect(("my-loopback-alias", 8765))
    assert seen == [("127.0.0.1", 8765)]


def _listener(family: int = socket.AF_INET, host: str = "127.0.0.1") -> socket.socket:
    srv = socket.socket(family, socket.SOCK_STREAM)
    srv.bind((host, 0))
    srv.listen(4)
    srv.settimeout(2)
    return srv


def test_loopback_connects_still_work_when_armed() -> None:
    """A direct `connect` hands the guard the name itself (`create_connection`
    would resolve it first), so this is the real-resolver path for `localhost`."""
    egress_guard.arm("test")
    with _listener() as srv:
        port = srv.getsockname()[1]
        for host in ("127.0.0.1", "localhost"):
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as cli:
                cli.settimeout(2)
                cli.connect((host, port))
            srv.accept()[0].close()


def test_unix_sockets_pass_untouched_when_armed() -> None:
    egress_guard.arm("test")
    path_dir = tempfile.mkdtemp(prefix="mp")
    path = os.path.join(path_dir, "s")
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as srv:
            srv.bind(path)
            srv.listen(1)
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as cli:
                cli.connect(path)
    finally:
        if os.path.exists(path):
            os.unlink(path)
        os.rmdir(path_dir)


@pytest.mark.guard_proof
def test_socket_layer_is_inert_after_disarm(monkeypatch: pytest.MonkeyPatch) -> None:
    egress_guard.arm("test")
    egress_guard.disarm()
    seen: list[Any] = []
    monkeypatch.setattr(egress_guard, "_orig_connect", lambda s, a: seen.append(a))
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.connect((_PUBLIC_IP, 80))
    assert seen == [(_PUBLIC_IP, 80)]  # attempted, with the address untouched


def test_is_loopback_reads_ipv4_mapped_addresses() -> None:
    assert egress_guard._is_loopback("::ffff:127.0.0.1")
    assert not egress_guard._is_loopback(f"::ffff:{_PUBLIC_IP}")


def test_arm_drops_proxy_settings_from_the_environment(monkeypatch: pytest.MonkeyPatch) -> None:
    for key in ("HTTP_PROXY", "https_proxy", "ALL_PROXY"):
        monkeypatch.setenv(key, "http://127.0.0.1:3128")
    egress_guard.arm("test")
    proxies = {k for k in os.environ if k.lower().endswith("_proxy") and k.lower() != "no_proxy"}
    assert proxies == set()
    assert os.environ["NO_PROXY"] == "*"
    assert os.environ["no_proxy"] == "*"


def test_child_env_drops_proxy_settings_when_armed() -> None:
    base = {"PATH": "/usr/bin", "HTTPS_PROXY": "http://proxy:1", "no_proxy": "corp"}
    egress_guard.arm("test")
    env = egress_guard.child_env(base)
    assert "HTTPS_PROXY" not in env
    assert env["NO_PROXY"] == "*" and env["no_proxy"] == "*"


@pytest.mark.guard_proof
def test_a_loopback_proxy_never_sees_urllib_traffic_when_armed(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A forwarder on 127.0.0.1 (Charles, a VPN helper) passes the socket check,
    because the connect really is loopback; what it forwards is not. The env scrub
    is what keeps urllib from using it."""
    real_getaddrinfo = socket.getaddrinfo

    def public_for_the_target_only(host: Any, port: Any, *a: Any, **k: Any) -> list[Any]:
        # Only the target is faked public; the proxy's own 127.0.0.1 resolves for
        # real, so a regressed scrub really dials the proxy and the test sees it.
        if host == "example.invalid":
            return _public_getaddrinfo(host, port)
        return real_getaddrinfo(host, port, *a, **k)

    # urlopen reuses a module-level opener whose proxies were read on first use,
    # so an earlier test's opener would decide this one.
    monkeypatch.setattr(urllib.request, "_opener", None)
    with _listener() as proxy:
        monkeypatch.setenv("HTTP_PROXY", f"http://127.0.0.1:{proxy.getsockname()[1]}")
        egress_guard.arm("test")
        monkeypatch.setattr(socket, "getaddrinfo", public_for_the_target_only)
        real_connect = egress_guard._orig_connect
        assert real_connect is not None

        def loopback_only(sock: Any, address: Any) -> Any:
            # A regressed scrub reaches the (loopback) proxy for real, which the
            # accept() below then catches; a public address must never be dialled.
            if address[0] != "127.0.0.1":
                pytest.fail(f"connect to {address!r} reached the real socket")
            return real_connect(sock, address)

        monkeypatch.setattr(egress_guard, "_orig_connect", loopback_only)
        with pytest.raises(EgressBlocked):
            urllib.request.urlopen("http://example.invalid/", timeout=1)
        proxy.settimeout(0.2)
        with pytest.raises(socket.timeout):
            proxy.accept()  # nothing ever connected to the proxy


@pytest.mark.skipif(sys.platform != "darwin", reason="the macOS system proxy is read only on darwin")
def test_the_macos_system_proxy_is_ignored_when_armed(monkeypatch: pytest.MonkeyPatch) -> None:
    # Any exported *_proxy (no_proxy included) stops urllib reading the system
    # proxy at all, which would make the premise below depend on the shell.
    for key in [k for k in os.environ if k.lower().endswith("_proxy")]:
        monkeypatch.delenv(key)
    monkeypatch.setattr(urllib.request, "getproxies_macosx_sysconf",
                        lambda: {"http": "http://127.0.0.1:3128"})
    assert "http" in urllib.request.getproxies()  # the premise: it is honoured by default
    egress_guard.arm("test")
    assert "http" not in urllib.request.getproxies()
    with httpx.Client() as client:
        assert not egress_guard._is_proxied(client._transport_for_url(httpx.URL("http://example.com")))


def test_armed_guard_refuses_a_proxied_httpx_transport(monkeypatch: pytest.MonkeyPatch) -> None:
    """The httpx check reads the URL host, not where the transport connects, so a
    proxied request to 127.0.0.1 used to pass and land on the proxy."""
    egress_guard.arm("test")
    monkeypatch.setattr(egress_guard, "_orig_sync",
                        lambda s, r: pytest.fail("proxied request reached the transport"))
    with httpx.Client(proxy="http://127.0.0.1:3128") as client, pytest.raises(EgressBlocked):
        client.get("http://127.0.0.1:8765/v1/models")


def test_armed_guard_refuses_a_proxied_async_transport(monkeypatch: pytest.MonkeyPatch) -> None:
    egress_guard.arm("test")
    monkeypatch.setattr(egress_guard, "_orig_async",
                        lambda s, r: pytest.fail("proxied request reached the transport"))

    async def _go() -> None:
        async with httpx.AsyncClient(proxy="http://127.0.0.1:3128") as client:
            await client.get("http://127.0.0.1:8765/v1/models")

    with pytest.raises(EgressBlocked):
        asyncio.run(_go())


def test_the_local_client_never_routes_loopback_through_a_proxy(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Unarmed too: a local summary posts the transcript, and httpx's env proxies
    do not exempt 127.0.0.1 unless NO_PROXY names it."""
    from mp.summarize_local import LocalSummaryClient

    monkeypatch.setenv("HTTP_PROXY", "http://proxy.example:3128")
    monkeypatch.setenv("ALL_PROXY", "http://proxy.example:3128")
    monkeypatch.delenv("NO_PROXY", raising=False)
    monkeypatch.delenv("no_proxy", raising=False)
    client = LocalSummaryClient(manage_subprocess=False)
    try:
        transport = client._http._transport_for_url(httpx.URL("http://127.0.0.1:8080/v1/models"))
        assert not egress_guard._is_proxied(transport)
    finally:
        client.close()


def test_huggingface_hub_still_speaks_the_patched_httpx() -> None:
    """SEC31/SEC19 fence. huggingface-hub 1.x builds an `httpx.Client`, which both
    guard layers see; 2.x moves to httpx2/httpcore2, where only the socket layer
    would. The `huggingface-hub<2` constraint holds until the lock bump that takes
    it past, so this fails if a resolve crosses it unflagged."""
    hub = pytest.importorskip("huggingface_hub")
    from huggingface_hub.utils._http import default_client_factory

    # The factory, not `get_session()`: hub caches one client per process, and an
    # earlier test may have built it while `httpx.Client` was monkeypatched.
    client = default_client_factory()
    try:
        assert isinstance(client, httpx.Client), (
            f"huggingface_hub {hub.__version__} no longer uses httpx.Client"
        )
    finally:
        client.close()


@pytest.mark.guard_proof
def test_huggingface_hub_is_stopped_by_the_socket_layer_alone(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """With the httpx-layer check taken out of the path (what an httpx2 client
    would look like to the guard), hub traffic still dies at the socket."""
    pytest.importorskip("huggingface_hub")
    from huggingface_hub.utils._http import default_client_factory

    egress_guard.arm("test")
    real = egress_guard._orig_sync
    monkeypatch.setattr(httpx.HTTPTransport, "handle_request", real)
    _block_downstream(monkeypatch)
    monkeypatch.setattr(socket, "getaddrinfo", _public_getaddrinfo)
    client = default_client_factory()  # fresh: see the fence above
    with client, pytest.raises(Exception) as raised:
        client.get("https://huggingface.co/api/models/x", timeout=1)
    chain: list[BaseException] = []
    err: BaseException | None = raised.value
    while err is not None:
        chain.append(err)
        err = err.__cause__ or err.__context__
    assert any(isinstance(e, EgressBlocked) for e in chain), chain
