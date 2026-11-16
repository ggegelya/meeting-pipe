"""Shared pieces of the fake model servers (SEC27).

The real server (`mp.local_model_server`) proves it holds the per-spawn token by
answering `GET /health?nonce=...` with an HMAC; the client trusts nothing that
cannot. Every fake `mlx_lm.server` in the suite therefore answers `/health` the
same way, with `TEST_TOKEN`, which the autouse fixture in `conftest.py` also
hands the client as its token.
"""
from __future__ import annotations

import json
from http.server import BaseHTTPRequestHandler
from urllib.parse import parse_qs, urlsplit

from mp import local_server

TEST_TOKEN = "test-server-token-" + "x" * 30


def answer_health(handler: BaseHTTPRequestHandler) -> bool:
    """Answer a `/health` request the way the real server does. True when the
    request was one, so a fake's `do_GET` can `return` after it."""
    url = urlsplit(handler.path)
    if url.path != "/health":
        return False
    nonce = (parse_qs(url.query).get("nonce") or [""])[0]
    payload = json.dumps(
        {"status": "ok", "proof": local_server.health_proof(TEST_TOKEN, nonce)}
    ).encode("utf-8")
    handler.send_response(200)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(payload)))
    handler.end_headers()
    handler.wfile.write(payload)
    return True
