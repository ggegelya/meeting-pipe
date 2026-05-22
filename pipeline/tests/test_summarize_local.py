"""Unit tests for ``LocalSummaryClient``.

The subprocess + HTTP plumbing is exercised against a fake
``mlx_lm.server`` (a tiny in-process ``http.server`` listening on a
free port) so the tests never depend on having mlx-lm installed or a
working Apple Silicon model on disk. The test seam is the
``manage_subprocess=False`` constructor flag plus a fixture that
points the client at the fake server.

The 3-layer extraction fallback is unit-tested directly via
``_extract_summary`` since that path has no I/O.
"""
from __future__ import annotations

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Callable

import pytest

from mp.summarize_local import (
    LocalSummaryClient,
    LocalSummaryError,
    _largest_balanced_json_object,
)


# ----- Fake mlx_lm.server -----

# Each test installs its own response builder; the handler reads it off
# the server instance set by the fixture.
_NoBody = object()


class _FakeHandler(BaseHTTPRequestHandler):
    def log_message(self, *_: object) -> None:  # silence test output
        pass

    def do_GET(self) -> None:  # noqa: N802 (BaseHTTPRequestHandler API)
        if self.path == "/v1/models":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"data": [{"id": "fake"}]}')
            return
        self.send_response(404)
        self.end_headers()

    def do_POST(self) -> None:  # noqa: N802
        if self.path != "/v1/chat/completions":
            self.send_response(404)
            self.end_headers()
            return
        builder: Callable[[dict], dict] = self.server.builder  # type: ignore[attr-defined]
        length = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(length) or b"{}")
        out = builder(body)
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(out).encode("utf-8"))


@pytest.fixture
def fake_server() -> tuple[str, int, ThreadingHTTPServer]:
    server = ThreadingHTTPServer(("127.0.0.1", 0), _FakeHandler)
    server.builder = lambda _payload: {  # type: ignore[attr-defined]
        "choices": [{"message": {"content": "{}"}}]
    }
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    host, port = server.server_address[0], server.server_address[1]
    yield host, port, server
    server.shutdown()
    server.server_close()


def _valid_summary_obj() -> dict:
    return {
        "title": "Standup",
        "summary": ["Discussed sprint progress."],
        "decisions": [],
        "actions": [],
        "questions": [],
        "attendees": ["Alice"],
        "detected_language": "en",
    }


# ----- Happy path -----

def test_summarize_layer1_clean_json(fake_server: tuple[str, int, ThreadingHTTPServer]) -> None:
    host, port, server = fake_server
    server.builder = lambda _: {  # type: ignore[attr-defined]
        "choices": [{"message": {"content": json.dumps(_valid_summary_obj())}}]
    }
    with LocalSummaryClient(host=host, port=port, manage_subprocess=False) as c:
        s = c.summarize(
            system_prompt="Summarize.",
            transcript="A: hello.",
            model="ignored",
            max_tokens=512,
        )
    assert s.title == "Standup"
    assert s.attendees == ["Alice"]


def test_summarize_layer2_markdown_fences(
    fake_server: tuple[str, int, ThreadingHTTPServer]
) -> None:
    host, port, server = fake_server
    body = "Here is the result:\n```json\n" + json.dumps(_valid_summary_obj()) + "\n```\n"
    server.builder = lambda _: {  # type: ignore[attr-defined]
        "choices": [{"message": {"content": body}}]
    }
    with LocalSummaryClient(host=host, port=port, manage_subprocess=False) as c:
        s = c.summarize(
            system_prompt="Summarize.",
            transcript="A: hello.",
            model="ignored",
            max_tokens=512,
        )
    assert s.title == "Standup"


def test_summarize_layer3_largest_balanced_object(
    fake_server: tuple[str, int, ThreadingHTTPServer]
) -> None:
    host, port, server = fake_server
    body = (
        "Sure! I'll think about it... { not a real one }"
        " and then: " + json.dumps(_valid_summary_obj()) + " followed by trailing prose."
    )
    server.builder = lambda _: {  # type: ignore[attr-defined]
        "choices": [{"message": {"content": body}}]
    }
    with LocalSummaryClient(host=host, port=port, manage_subprocess=False) as c:
        s = c.summarize(
            system_prompt="Summarize.",
            transcript="A: hello.",
            model="ignored",
            max_tokens=512,
        )
    assert s.title == "Standup"


def test_summarize_no_valid_json_raises(
    fake_server: tuple[str, int, ThreadingHTTPServer]
) -> None:
    host, port, server = fake_server
    server.builder = lambda _: {  # type: ignore[attr-defined]
        "choices": [{"message": {"content": "I cannot do that, Dave."}}]
    }
    with LocalSummaryClient(host=host, port=port, manage_subprocess=False) as c:
        with pytest.raises(LocalSummaryError):
            c.summarize(
                system_prompt="Summarize.",
                transcript="A: hello.",
                model="ignored",
                max_tokens=512,
            )


def test_summarize_invalid_schema_after_correction_raises(
    fake_server: tuple[str, int, ThreadingHTTPServer]
) -> None:
    # Both attempts return valid JSON missing required fields, so the
    # corrective retry also fails and the call raises.
    host, port, server = fake_server
    server.builder = lambda _: {  # type: ignore[attr-defined]
        "choices": [{"message": {"content": json.dumps({"title": "Only title"})}}]
    }
    with LocalSummaryClient(host=host, port=port, manage_subprocess=False) as c:
        with pytest.raises(LocalSummaryError):
            c.summarize(
                system_prompt="Summarize.",
                transcript="A: hello.",
                model="ignored",
                max_tokens=512,
            )


def test_summarize_corrective_retry_recovers(
    fake_server: tuple[str, int, ThreadingHTTPServer]
) -> None:
    # First attempt returns malformed output; second attempt (after the
    # client replays with the validation error in-context) returns a
    # valid summary. The client should return the recovered summary
    # rather than raising.
    host, port, server = fake_server
    call_count = {"n": 0}

    def builder(_: dict) -> dict:
        call_count["n"] += 1
        if call_count["n"] == 1:
            return {"choices": [{"message": {"content": json.dumps({"title": "bad"})}}]}
        return {"choices": [{"message": {"content": json.dumps(_valid_summary_obj())}}]}

    server.builder = builder  # type: ignore[attr-defined]
    with LocalSummaryClient(host=host, port=port, manage_subprocess=False) as c:
        s = c.summarize(
            system_prompt="Summarize.",
            transcript="A: hello.",
            model="ignored",
            max_tokens=512,
        )
    assert s.title == "Standup"
    assert call_count["n"] == 2, "expected exactly one corrective retry"


def test_summarize_sends_response_format_hint(
    fake_server: tuple[str, int, ThreadingHTTPServer]
) -> None:
    host, port, server = fake_server
    captured: dict = {}

    def builder(payload: dict) -> dict:
        captured.update(payload)
        return {"choices": [{"message": {"content": json.dumps(_valid_summary_obj())}}]}

    server.builder = builder  # type: ignore[attr-defined]
    with LocalSummaryClient(host=host, port=port, manage_subprocess=False) as c:
        c.summarize(
            system_prompt="Summarize.",
            transcript="A: hello.",
            model="ignored",
            max_tokens=512,
        )
    rf = captured.get("response_format")
    assert rf is not None, "response_format hint must be present in the payload"
    assert rf.get("type") == "json_schema"
    assert rf.get("json_schema", {}).get("strict") is True


# ----- Lifecycle: no server reachable -----

def test_no_server_with_manage_false_raises() -> None:
    # Port 1 is reserved and never has a listener; manage_subprocess=False
    # means we won't try to spawn one, so the call must fail fast.
    with LocalSummaryClient(host="127.0.0.1", port=1, manage_subprocess=False) as c:
        with pytest.raises(LocalSummaryError):
            c.summarize(
                system_prompt="x", transcript="x", model="x", max_tokens=1,
            )


# ----- Bind host is clamped to loopback -----

def test_non_loopback_host_is_clamped() -> None:
    # A non-loopback host (e.g. a stray bind-all address in config) would
    # expose the unauthenticated inference server on the LAN; the client
    # must clamp it back to loopback.
    c = LocalSummaryClient(host="10.0.0.5", port=8765, manage_subprocess=False)
    assert c.base_url == "http://127.0.0.1:8765"


def test_loopback_host_is_preserved() -> None:
    c = LocalSummaryClient(host="localhost", port=8765, manage_subprocess=False)
    assert c.base_url == "http://localhost:8765"


# ----- Pure helper: balanced JSON scanner -----

def test_largest_balanced_object_picks_outer() -> None:
    text = 'prefix {"a": {"b": 1}, "c": "}"} suffix'
    out = _largest_balanced_json_object(text)
    assert out == '{"a": {"b": 1}, "c": "}"}'


def test_largest_balanced_object_handles_strings_with_braces() -> None:
    text = 'noise {"x": "this } is in a string"} more'
    out = _largest_balanced_json_object(text)
    assert out == '{"x": "this } is in a string"}'


def test_largest_balanced_object_returns_largest_of_two() -> None:
    text = '{"small": 1} between {"big": {"deep": [1, 2]}}'
    out = _largest_balanced_json_object(text)
    assert out == '{"big": {"deep": [1, 2]}}'


def test_largest_balanced_object_returns_none_when_unbalanced() -> None:
    assert _largest_balanced_json_object("no braces here") is None
    assert _largest_balanced_json_object("{ unbalanced") is None
