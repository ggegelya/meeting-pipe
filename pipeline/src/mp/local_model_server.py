"""The hardened entry point `mp` launches instead of a bare `mlx_lm.server` (SEC27).

`python -m mp.local_model_server <the argv mlx_lm.server would take>`

Stock `mlx_lm.server` 0.31.3 is an unauthenticated loopback HTTP server that
answers `Access-Control-Allow-Origin: *` and loads whatever `model`,
`draft_model` and `adapters` a request body names, which for a model directory
means executing the Python file its `config.json` points at. That is fine on a
machine where nothing untrusted can open a loopback socket and wrong on this
one: a sandboxed app, another local account, or a web page can all POST to
127.0.0.1. This shim keeps the real server and narrows it:

- the server is started on a snapshot *directory* (never a repo id, so nothing
  reaches the downloader), offline, and the snapshot is verified here again;
- every request needs `Authorization: Bearer <bearer_for(token)>`, where the
  per-spawn token arrives in the environment (never argv) and the bearer is a
  one-way derivation of it, so the wire credential is not the proof key,
  except `GET /health`, which is the server proving *itself* to the client: it
  answers an HMAC of the caller's nonce that only a holder of the token can
  compute (see `local_server.health_proof`);
- once bound and listening the server records its token (0600) for later
  clients; a spawn that loses a port race never reaches that line;
- a request carrying an `Origin` header, or a `Host` other than a loopback name
  with the bound port (DNS rebinding), is refused, and so is every preflight;
- the body may name only the configured model (or the alias `default_model`),
  the configured adapter, and no draft model, checked on the raw request before
  mlx-lm sees it, and again in `ModelProvider.load` as a second wall.

CORS alone would not be the fix: a blind `text/plain` POST has its side effect
whether or not the response is readable.

The checks live in `Policy`, pure and unit-testable without mlx; `install`
grafts them onto mlx-lm's handler. The graft patches methods on the
`APIHandler` *class*, because `_run_http_server` captures that class object as a
default argument and rebinding the module attribute would change nothing.
"""
from __future__ import annotations

import argparse
import hmac
import io
import json
import os
import re
import sys
from collections.abc import Mapping
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlsplit

from . import local_server

TOKEN_ENV = "MP_LOCAL_SERVER_TOKEN"  # noqa: S105 - the variable's name, not a secret
DEFAULT_MODEL_ALIAS = "default_model"

#: A chat request is a transcript, so it can be large; this only bounds a
#: hostile Content-Length from allocating memory before auth is even decided.
MAX_BODY_BYTES = 8 * 1024 * 1024

#: Shorter than this is not a token we generated (`secrets.token_urlsafe(32)` is 43).
MIN_TOKEN_CHARS = 32

_LOOPBACK_HOSTS = frozenset({"127.0.0.1", "localhost", "::1"})
#: What a loopback `Host` header looks like. The names are the whole point: a
#: rebinding attacker's own hostname is never one of these.
_LOOPBACK_HOST_NAMES = ("127.0.0.1", "localhost", "[::1]")

HEALTH_PATH = "/health"
SERVER_ID = "mp-local-model-server"


class Refusal(Exception):
    """A request the policy will not serve: HTTP status plus a short reason."""

    def __init__(self, status: int, reason: str) -> None:
        super().__init__(reason)
        self.status = status
        self.reason = reason


class Policy:
    """What this server will answer, as pure checks over headers and bodies."""

    def __init__(self, *, port: int, token: str, model: str, adapter: str | None) -> None:
        if len(token) < MIN_TOKEN_CHARS:
            raise ValueError("token too short")
        self._token = token
        self._bearer = local_server.bearer_for(token)
        self._model = model
        self._adapter = adapter or None
        self._hosts = frozenset(f"{h}:{port}" for h in _LOOPBACK_HOST_NAMES)

    def check_origin_and_host(self, headers: Mapping[str, str | None] | Any) -> None:
        """Raise `Refusal` for a browser-borne or DNS-rebound request."""
        if headers.get("Origin") is not None:
            raise Refusal(403, "cross-origin requests are not served")
        if headers.get("Host") not in self._hosts:
            raise Refusal(403, "unexpected Host header")

    def health_proof(self, nonce: str) -> str:
        return local_server.health_proof(self._token, nonce)

    def check_headers(self, headers: Mapping[str, str | None] | Any) -> None:
        """Raise `Refusal` unless the headers are an authenticated local request.

        Order matters: the origin and host gates run first so a browser-borne or
        rebound request is refused as such even if it somehow carried a token."""
        self.check_origin_and_host(headers)
        supplied = (headers.get("Authorization") or "").strip()
        scheme, _, value = supplied.partition(" ")
        if scheme.lower() != "bearer" or not hmac.compare_digest(
            value.strip().encode("utf-8"), self._bearer.encode("utf-8")
        ):
            raise Refusal(401, "missing or wrong bearer token")

    def check_load(
        self, model: Any, adapter: Any = None, draft_model: Any = None
    ) -> None:
        """Raise `Refusal` unless this exact (model, adapter, draft) is allowed."""
        if not isinstance(model, str) or model not in (DEFAULT_MODEL_ALIAS, self._model):
            raise Refusal(403, "this server serves one model; the request named another")
        if adapter is not None and adapter != self._adapter:
            raise Refusal(403, "this server loads only its configured adapter")
        if draft_model is not None and draft_model != DEFAULT_MODEL_ALIAS:
            raise Refusal(403, "draft models are not served")

    def check_body(self, body: Any) -> None:
        """The same rule applied to a request body's three loader-reaching keys.

        Absent and explicit null both mean "default", exactly as mlx-lm reads
        them; anything else must be the configured value."""
        if not isinstance(body, dict):
            raise Refusal(400, "request should be a JSON object")
        self.check_load(
            body.get("model", DEFAULT_MODEL_ALIAS),
            body.get("adapters"),
            body.get("draft_model"),
        )


_NONCE_RE = re.compile(r"^[A-Za-z0-9_-]{16,128}$")


def _send_json(handler: Any, status: int, body: dict[str, Any]) -> None:
    payload = json.dumps(body).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(payload)))
    # No CORS headers, ever, and no keep-alive: a refused request leaves
    # whatever body it sent unread on the socket.
    handler.send_header("Connection", "close")
    handler.end_headers()
    handler.wfile.write(payload)
    handler.close_connection = True


def _deny(handler: Any, status: int, reason: str) -> None:
    _send_json(handler, status, {"error": reason})


def install(server_module: Any, policy: Policy) -> None:
    """Graft `policy` onto mlx-lm's `APIHandler` and `ModelProvider`."""
    handler_cls = server_module.APIHandler
    provider_cls = server_module.ModelProvider
    original_get = handler_cls.do_GET
    original_post = handler_cls.do_POST
    original_load = provider_cls.load

    def do_GET(self: Any) -> None:
        url = urlsplit(self.path)
        try:
            if url.path == HEALTH_PATH:
                # The one unauthenticated route: the server proving itself.
                policy.check_origin_and_host(self.headers)
                nonce = (parse_qs(url.query).get("nonce") or [""])[0]
                if not _NONCE_RE.fullmatch(nonce):
                    raise Refusal(400, "a nonce query parameter is required")
                _send_json(
                    self, 200,
                    {"status": "ok", "server": SERVER_ID, "proof": policy.health_proof(nonce)},
                )
                return
            policy.check_headers(self.headers)
        except Refusal as r:
            _deny(self, r.status, r.reason)
            return
        if self.path.startswith("/v1/models"):
            original_get(self)
            return
        _deny(self, 404, "not found")

    def do_OPTIONS(self: Any) -> None:
        # Nothing legitimate preflights: our client is not a browser.
        _deny(self, 403, "preflight requests are not served")

    def do_POST(self: Any) -> None:
        try:
            policy.check_headers(self.headers)
            raw = _read_body(self)
            try:
                body = json.loads(raw.decode("utf-8"))
            except (UnicodeDecodeError, ValueError) as e:
                raise Refusal(400, f"invalid JSON in request body: {e}") from e
            policy.check_body(body)
        except Refusal as r:
            _deny(self, r.status, r.reason)
            return
        # mlx-lm reads Content-Length bytes from rfile itself; hand it the bytes
        # we already consumed and validated, so what it parses is what we checked.
        self.rfile = io.BytesIO(raw)
        original_post(self)

    def load(
        self: Any, model_path: Any, adapter_path: Any = None, draft_model_path: Any = None
    ) -> Any:
        policy.check_load(model_path, adapter_path, draft_model_path)
        return original_load(self, model_path, adapter_path, draft_model_path)

    handler_cls.do_GET = do_GET
    handler_cls.do_OPTIONS = do_OPTIONS
    handler_cls.do_POST = do_POST
    provider_cls.load = load


def record_token_when_listening(
    server_cls: Any, *, port: int, token: str, writer: Any
) -> None:
    """Make `server_cls` record `{port, pid, token}` the moment it is listening.

    `socketserver.TCPServer.__init__` binds and then calls `server_activate`
    (listen), and mlx-lm builds the server through a class default argument, so
    the hook goes on the class. A bind that loses a race raises before this
    runs, so the record of the server that won is never overwritten. A write
    that fails stops the server: one nobody can authenticate to is useless."""
    original = server_cls.server_activate

    def server_activate(self: Any) -> None:
        original(self)
        writer(port, token, os.getpid())

    server_cls.server_activate = server_activate


def _read_body(handler: Any) -> bytes:
    length_header = handler.headers.get("Content-Length")
    if length_header is None:
        raise Refusal(411, "Content-Length header is required")
    try:
        length = int(length_header)
    except ValueError as e:
        raise Refusal(400, "invalid Content-Length header") from e
    if length < 0:
        raise Refusal(400, "invalid Content-Length header")
    if length > MAX_BODY_BYTES:
        raise Refusal(413, "request body too large")
    return handler.rfile.read(length)


def _fail(message: str) -> int:
    print(f"mp local model server: {message}", file=sys.stderr)
    return 2


def main(argv: list[str]) -> int:
    # Before anything imports huggingface_hub, which reads these once at import.
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["TRANSFORMERS_OFFLINE"] = "1"
    # Pop, not get: nothing this process starts should inherit the token. (The
    # kernel's copy of the exec-time environment stays readable to same-user
    # tools, which is why the on-wire credential is derived from it, not it.)
    token = os.environ.pop(TOKEN_ENV, "")
    if len(token) < MIN_TOKEN_CHARS:
        return _fail(f"{TOKEN_ENV} is not set; refusing to start an unauthenticated server")

    parser = argparse.ArgumentParser(add_help=False, allow_abbrev=False)
    parser.add_argument("--model")
    parser.add_argument("--adapter-path")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--draft-model")
    parser.add_argument("--trust-remote-code", action="store_true")
    parser.add_argument("--prompt-cache-size", type=int)
    try:
        args, unknown = parser.parse_known_args(argv)
    except SystemExit:
        return _fail("could not parse the server arguments")
    # mlx-lm's own parser accepts abbreviations (`--mod`, `--draft`), so a flag
    # this one does not know could change what mlx-lm serves after we verified
    # it. Our spawners pass exactly the flags above; anything else is refused.
    if unknown:
        return _fail(f"unexpected arguments {unknown!r}")

    if args.host.strip().lower() not in _LOOPBACK_HOSTS:
        return _fail(f"--host {args.host!r} is not a loopback address")
    if args.draft_model or args.trust_remote_code:
        return _fail("--draft-model and --trust-remote-code are not allowed")
    if not args.model or not Path(args.model).is_dir():
        return _fail("--model must be a local snapshot directory, not a repo id")

    from . import local_snapshot

    try:
        local_snapshot.verify_snapshot(Path(args.model))
    except local_snapshot.SnapshotError as e:
        return _fail(str(e))

    try:
        import mlx_lm.server as server_module  # pyright: ignore[reportMissingImports]
    except ImportError as e:
        return _fail(f"mlx-lm is not installed ({e})")
    for needed in ("APIHandler", "ModelProvider", "main"):
        if not hasattr(server_module, needed):
            return _fail(f"mlx_lm.server has no {needed}; this mlx-lm is not one mp supports")

    install(
        server_module,
        Policy(port=args.port, token=token, model=args.model, adapter=args.adapter_path),
    )
    from http.server import ThreadingHTTPServer

    import atexit

    atexit.register(local_server.clear_token, os.getpid())
    record_token_when_listening(
        ThreadingHTTPServer, port=args.port, token=token, writer=local_server.write_token
    )
    # Later flags win in argparse, so this overrides the stock "*" default.
    sys.argv = ["mlx_lm.server", *argv, "--allowed-origins", ""]
    server_module.main()
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main(sys.argv[1:]))
