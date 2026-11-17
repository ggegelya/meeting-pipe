"""SEC27: the hardened shim around mlx-lm's server.

`mlx_lm` is not imported here (the Linux runner has none). A stand-in module
with the three names the shim grafts onto (`APIHandler`, `ModelProvider`,
`main`) is served over real loopback HTTP, so what is tested is the wire
behaviour: which requests reach the stand-in's original handlers and which are
refused before it sees them.
"""
from __future__ import annotations

import http.client
import json
import threading
import types
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

from mp import local_model_server as shim
from mp import local_server

TOKEN = "k" * 43
MODEL = "/hub/models--a--b/snapshots/" + "a" * 40
ADAPTER = "/adapters/mine"


def _fake_mlx_module() -> tuple[types.ModuleType, dict]:
    seen: dict = {"get": 0, "post": [], "loads": [], "options": 0}

    class ModelProvider:
        def load(self, model_path, adapter_path=None, draft_model_path=None):
            seen["loads"].append((model_path, adapter_path, draft_model_path))
            return "model", "tokenizer"

    class APIHandler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.0"

        def log_message(self, *_a: object) -> None:
            pass

        def do_GET(self) -> None:  # noqa: N802
            seen["get"] += 1
            self.send_response(200)
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(b'{"data": []}')

        def do_OPTIONS(self) -> None:  # noqa: N802
            seen["options"] += 1
            self.send_response(204)
            self.end_headers()

        def do_POST(self) -> None:  # noqa: N802
            n = int(self.headers["Content-Length"])
            body = json.loads(self.rfile.read(n).decode())
            seen["post"].append(body)
            ModelProvider().load(
                body.get("model", "default_model"), body.get("adapters"), body.get("draft_model")
            )
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'{"ok": true}')

    mod = types.ModuleType("fake_mlx_server")
    mod.APIHandler = APIHandler  # type: ignore[attr-defined]
    mod.ModelProvider = ModelProvider  # type: ignore[attr-defined]
    mod.main = lambda: None  # type: ignore[attr-defined]
    return mod, seen


@pytest.fixture
def served():
    mod, seen = _fake_mlx_module()
    server = ThreadingHTTPServer(("127.0.0.1", 0), mod.APIHandler)
    port = server.server_address[1]
    shim.install(mod, shim.Policy(port=port, token=TOKEN, model=MODEL, adapter=ADAPTER))
    threading.Thread(
        target=lambda: server.serve_forever(poll_interval=0.01), daemon=True
    ).start()
    yield port, seen
    server.shutdown()
    server.server_close()


def _request(port: int, method: str, path: str, *, body: object = None, headers: dict | None = None,
             host: str | None = None, token: str | None = TOKEN, raw: bytes | None = None):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    h = {"Host": host or f"127.0.0.1:{port}", **(headers or {})}
    if token is not None:
        h["Authorization"] = f"Bearer {local_server.bearer_for(token)}"
    payload = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    if payload is not None:
        h["Content-Length"] = str(len(payload))
        h.setdefault("Content-Type", "text/plain")   # the browser "simple request" shape
    conn.putrequest(method, path, skip_host=True, skip_accept_encoding=True)
    for k, v in h.items():
        conn.putheader(k, v)
    conn.endheaders(payload)
    r = conn.getresponse()
    data = r.read()
    conn.close()
    return r.status, dict(r.getheaders()), data


CHAT = "/v1/chat/completions"
GOOD = {"model": "default_model", "messages": [{"role": "user", "content": "hi"}]}


def test_the_configured_model_with_the_token_reaches_the_real_handler(served) -> None:
    port, seen = served
    status, _h, _b = _request(port, "POST", CHAT, body=GOOD)
    assert status == 200 and seen["post"] == [GOOD]
    assert seen["loads"] == [("default_model", None, None)]


def test_the_adapter_the_server_was_started_with_is_allowed(served) -> None:
    port, seen = served
    status, *_ = _request(port, "POST", CHAT, body={**GOOD, "adapters": ADAPTER})
    assert status == 200 and seen["loads"][-1][1] == ADAPTER


@pytest.mark.parametrize("override", [
    {"model": "x/y"},                          # the acceptance probe: a repo id
    {"model": "/tmp/evil-model-dir"},          # a local path with a model_file
    {"model": 7},
    {"draft_model": "x/y"},
    {"adapters": "/tmp/other-adapter"},
    {"adapters": ""},
])
def test_a_request_naming_anything_else_is_refused_before_any_load(served, override) -> None:
    port, seen = served
    status, _h, _b = _request(port, "POST", CHAT, body={**GOOD, **override})
    assert status == 403
    assert seen["post"] == [] and seen["loads"] == []   # the original handler never ran


def test_the_snapshot_path_itself_is_an_allowed_model_name(served) -> None:
    port, seen = served
    status, *_ = _request(port, "POST", CHAT, body={**GOOD, "model": MODEL})
    assert status == 200


def test_the_other_completions_path_is_pinned_too(served) -> None:
    port, seen = served
    status, *_ = _request(port, "POST", "/v1/completions", body={"model": "x/y", "prompt": "p"})
    assert status == 403 and seen["loads"] == []


@pytest.mark.parametrize("token", [None, "", "wrong-token", TOKEN + "x"])
def test_a_request_without_the_token_is_refused(served, token) -> None:
    port, seen = served
    status, *_ = _request(port, "POST", CHAT, body=GOOD, token=token)
    assert status == 401 and seen["post"] == []


def test_a_request_with_an_origin_header_is_refused_even_with_the_token(served) -> None:
    """The browser path: a text/plain POST is a simple request with no preflight,
    so the Origin header is the only thing that says "this came from a page"."""
    port, seen = served
    status, hdrs, _ = _request(port, "POST", CHAT, body=GOOD,
                               headers={"Origin": "https://evil.example"})
    assert status == 403 and seen["post"] == []
    assert "Access-Control-Allow-Origin" not in hdrs


def test_a_foreign_host_header_is_refused_as_dns_rebinding(served) -> None:
    port, seen = served
    status, *_ = _request(port, "POST", CHAT, body=GOOD, host=f"rebind.evil.example:{port}")
    assert status == 403 and seen["post"] == []
    status, *_ = _request(port, "POST", CHAT, body=GOOD, host="127.0.0.1:1")   # wrong port
    assert status == 403


def test_a_preflight_is_always_refused(served) -> None:
    port, seen = served
    status, *_ = _request(port, "OPTIONS", CHAT, headers={"Origin": "https://x.example"})
    assert status == 403 and seen["options"] == 0


def test_a_malformed_body_is_a_400_not_a_crash(served) -> None:
    port, seen = served
    assert _request(port, "POST", CHAT, raw=b"{not json")[0] == 400
    assert _request(port, "POST", CHAT, raw=b"[1, 2]")[0] == 400
    assert _request(port, "POST", CHAT, raw=b"\xff\xfe")[0] == 400
    assert seen["post"] == []


def test_models_listing_needs_the_token_and_the_health_proof_does_not(served) -> None:
    port, seen = served
    assert _request(port, "GET", "/v1/models", token=None)[0] == 401
    assert _request(port, "GET", "/v1/models")[0] == 200 and seen["get"] == 1
    assert _request(port, "GET", "/nothing")[0] == 404


def test_health_returns_a_proof_only_a_token_holder_can_compute(served) -> None:
    port, seen = served
    nonce = "n" * 24
    status, _h, body = _request(port, "GET", f"/health?nonce={nonce}", token=None)
    assert status == 200
    assert json.loads(body)["proof"] == local_server.health_proof(TOKEN, nonce)
    assert json.loads(body)["proof"] != local_server.health_proof("some-other-token-" * 3, nonce)
    assert seen["get"] == 0                                  # answered by the shim itself


def test_health_refuses_a_missing_nonce_a_browser_origin_and_a_foreign_host(served) -> None:
    port, _ = served
    assert _request(port, "GET", "/health", token=None)[0] == 400
    assert _request(port, "GET", "/health?nonce=" + "n" * 24, token=None,
                    headers={"Origin": "https://evil.example"})[0] == 403
    assert _request(port, "GET", "/health?nonce=" + "n" * 24, token=None,
                    host="evil.example:80")[0] == 403


# ----- the second wall: ModelProvider.load -----


def test_provider_load_refuses_anything_but_the_configured_triple() -> None:
    mod, seen = _fake_mlx_module()
    shim.install(mod, shim.Policy(port=1, token=TOKEN, model=MODEL, adapter=None))
    provider = mod.ModelProvider()
    assert provider.load("default_model", None, "default_model") == ("model", "tokenizer")
    for bad in [("x/y", None, None), ("default_model", "/a", None), ("default_model", None, "x/y")]:
        with pytest.raises(shim.Refusal):
            provider.load(*bad)
    assert len(seen["loads"]) == 1                            # only the good call got through


def test_policy_needs_a_real_token() -> None:
    with pytest.raises(ValueError):
        shim.Policy(port=1, token="short", model=MODEL, adapter=None)


# ----- recording the token only once bound -----


def test_the_token_is_recorded_after_listen_and_not_when_the_bind_fails(tmp_path: Path) -> None:
    written: list[tuple] = []
    first = type("S1", (ThreadingHTTPServer,), {})
    shim.record_token_when_listening(
        first, port=0, token=TOKEN, writer=lambda *a: written.append(a)
    )
    s = first(("127.0.0.1", 0), BaseHTTPRequestHandler)
    port = s.server_address[1]
    assert len(written) == 1 and written[0][1] == TOKEN

    second = type("S2", (ThreadingHTTPServer,), {})
    shim.record_token_when_listening(
        second, port=port, token="z" * 43, writer=lambda *a: written.append(a)
    )
    second.allow_reuse_address = False
    second.allow_reuse_port = False
    with pytest.raises(OSError):
        second(("127.0.0.1", port), BaseHTTPRequestHandler)
    assert len(written) == 1                                  # the loser never overwrote the record
    s.server_close()


# ----- main(): fail closed before importing mlx-lm -----


def _snapshot(tmp_path: Path, *, code: bool = False) -> Path:
    d = tmp_path / "snap"
    d.mkdir()
    (d / "config.json").write_text("{}")
    (d / "model.safetensors").write_bytes(b"w")
    if code:
        (d / "evil.py").write_text("x")
    return d


@pytest.fixture
def _env(monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv(shim.TOKEN_ENV, TOKEN)
    # `main` writes these two directly; setting them first registers the undo.
    monkeypatch.setenv("HF_HUB_OFFLINE", "0")
    monkeypatch.setenv("TRANSFORMERS_OFFLINE", "0")


def test_main_refuses_to_start_without_a_token(tmp_path: Path, monkeypatch, capsys) -> None:
    monkeypatch.delenv(shim.TOKEN_ENV, raising=False)
    assert shim.main(["--model", str(_snapshot(tmp_path)), "--port", "1"]) == 2
    assert "unauthenticated" in capsys.readouterr().err


@pytest.mark.parametrize("argv_extra,why", [
    (["--model", "x/y"], "snapshot directory"),
    (["--host", "0.0.0.0"], "loopback"),
    (["--draft-model", "x/y"], "not allowed"),
    (["--trust-remote-code"], "not allowed"),
    (["--mod", "/elsewhere"], "unexpected"),       # an abbreviation mlx-lm would expand
    (["--chat-template", "{{x}}"], "unexpected"),
])
def test_main_refuses_unsafe_arguments(_env, tmp_path: Path, capsys, argv_extra, why) -> None:
    base = ["--model", str(_snapshot(tmp_path)), "--port", "1"]
    argv = [a for a in base] if argv_extra[0] != "--model" else ["--port", "1"]
    assert shim.main(argv + argv_extra) == 2
    assert why in capsys.readouterr().err


def test_main_refuses_a_snapshot_that_carries_code(_env, tmp_path: Path, capsys) -> None:
    assert shim.main(["--model", str(_snapshot(tmp_path, code=True)), "--port", "1"]) == 2
    assert "Python files" in capsys.readouterr().err


def test_main_pins_offline_and_removes_the_token_from_the_environment(
    _env, tmp_path: Path, monkeypatch
) -> None:
    import os
    import sys

    mod, _seen = _fake_mlx_module()
    ran: list[list[str]] = []
    mod.main = lambda: ran.append(list(sys.argv))  # type: ignore[attr-defined]
    monkeypatch.setitem(sys.modules, "mlx_lm", types.ModuleType("mlx_lm"))
    monkeypatch.setitem(sys.modules, "mlx_lm.server", mod)
    monkeypatch.setattr(shim, "record_token_when_listening", lambda *a, **k: None)

    assert shim.main(["--model", str(_snapshot(tmp_path)), "--port", "8765",
                      "--prompt-cache-size", "2"]) == 0
    assert os.environ["HF_HUB_OFFLINE"] == "1"
    assert shim.TOKEN_ENV not in os.environ
    assert ran[0][-2:] == ["--allowed-origins", ""]           # no CORS origin at all


def test_health_never_returns_the_bearer_whatever_the_nonce_SEC27(served) -> None:
    """The amendment's hole: the bearer's label was itself a valid nonce, so the
    unauthenticated /health handed it out. Try the old label, the new label and
    the HMAC domain prefixes as nonces; none may yield the bearer."""
    port, _ = served
    bearer = local_server.bearer_for(TOKEN)
    for nonce in ("mp-local-server-bearer-v1", "mp-local-server-bearer-v2",
                  "mp-local-server-health-v2", "bearer" * 4, "health" * 4):
        status, _h, body = _request(port, "GET", f"/health?nonce={nonce}", token=None)
        assert bearer not in body.decode()
        if status == 200:
            assert json.loads(body)["proof"] != bearer


def test_the_bearer_and_health_domains_are_disjoint_SEC27() -> None:
    from mp.local_model_server import _NONCE_RE

    assert local_server.health_proof(TOKEN, "mp-local-server-bearer-v1") != local_server.bearer_for(TOKEN)
    assert local_server._BEARER_LABEL.decode() and not _NONCE_RE.match(local_server._BEARER_LABEL.decode())
