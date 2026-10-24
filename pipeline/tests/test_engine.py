"""Tests for `engine.complete_text` backend routing + the zero-egress contract.

CI-safe: the local and Anthropic clients are faked, so no model loads and no
socket opens. What is under test is the routing (which backend answers) and the
regulated / NDA force-local rule, not the vendor SDKs.
"""
from __future__ import annotations

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import anthropic
import httpx
import pytest

from mp import engine
from mp.config import Config
from mp.engine import EngineError, EngineResult, complete_text


def _cfg(backend: str = "local", regulated: bool = False, nda: bool = False) -> Config:
    return Config.model_validate({
        "summarization": {"backend": backend, "local_model": "fake-local", "model": "fake-cloud"},
        "modes": {"regulated_mode": regulated, "workflow_nda_mode": nda},
    })


class _FakeLocal:
    def __init__(self, text: str = "local answer", model: str = "fake-local") -> None:
        self._text = text
        self.model = model
        self.closed = False

    def complete(self, *, system_prompt: str, user_message: str, max_tokens: int, response_format) -> str:
        return self._text

    def close(self) -> None:
        self.closed = True


class _FakeAnthropic:
    last: "_FakeAnthropic | None" = None
    backend_id = "anthropic"

    def __init__(self, *, api_key: str, model: str) -> None:
        self.model = model
        _FakeAnthropic.last = self

    def complete(self, *, system_prompt: str, user_message: str, max_tokens: int) -> str:
        return "cloud answer"


def _patch_local(monkeypatch, fake: _FakeLocal) -> _FakeLocal:
    monkeypatch.setattr(engine, "_local_client", lambda cfg, model: fake)
    return fake


def _call(cfg: Config) -> EngineResult:
    return complete_text(cfg, system_prompt="s", user_message="u", max_tokens=64)


def test_local_backend_uses_local_and_closes_it(monkeypatch: pytest.MonkeyPatch) -> None:
    fake = _patch_local(monkeypatch, _FakeLocal())
    res = _call(_cfg("local"))
    assert res.backend == "local"
    assert res.text == "local answer"
    assert fake.closed  # the server subprocess is always closed


def test_anthropic_backend_uses_cloud(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")
    monkeypatch.setattr(engine, "AnthropicTextClient", _FakeAnthropic)
    res = _call(_cfg("anthropic"))
    assert res.backend == "anthropic"
    assert res.text == "cloud answer"


def test_regulated_forces_local_over_anthropic(monkeypatch: pytest.MonkeyPatch) -> None:
    # Even with backend=anthropic and a key set, regulated_mode must resolve local.
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")
    fake = _patch_local(monkeypatch, _FakeLocal())
    res = _call(_cfg("anthropic", regulated=True))
    assert res.backend == "local"
    assert fake.closed


def test_nda_forces_local(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")
    _patch_local(monkeypatch, _FakeLocal())
    assert _call(_cfg("anthropic", nda=True)).backend == "local"


def test_apple_intelligence_falls_back_to_local(monkeypatch: pytest.MonkeyPatch) -> None:
    _patch_local(monkeypatch, _FakeLocal(text="apple->local"))
    res = _call(_cfg("apple_intelligence"))
    assert res.backend == "local"
    assert res.text == "apple->local"


def test_auto_prefers_anthropic_when_key_present(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")
    monkeypatch.setattr(engine, "AnthropicTextClient", _FakeAnthropic)
    _patch_local(monkeypatch, _FakeLocal())
    assert _call(_cfg("auto")).backend == "anthropic"


def test_auto_falls_back_to_local_without_key(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    _patch_local(monkeypatch, _FakeLocal())
    assert _call(_cfg("auto")).backend == "local"


def _raising_anthropic(exc: BaseException) -> type:
    class _Boom:
        backend_id = "anthropic"

        def __init__(self, *, api_key: str, model: str) -> None:
            self.model = model

        def complete(self, **kwargs) -> str:
            raise exc

    return _Boom


def test_auto_falls_back_to_local_on_anthropic_failure(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")
    req = httpx.Request("POST", "https://api.anthropic.com/v1/messages")
    monkeypatch.setattr(engine, "AnthropicTextClient",
                        _raising_anthropic(anthropic.APIConnectionError(request=req)))
    _patch_local(monkeypatch, _FakeLocal(text="fell back"))
    res = _call(_cfg("auto"))
    assert res.backend == "local"
    assert res.text == "fell back"


@pytest.mark.parametrize(
    "exc",
    [
        anthropic.RateLimitError(
            "boom",
            response=httpx.Response(
                429, request=httpx.Request("POST", "https://api.anthropic.com/v1/messages")
            ),
            body=None,
        ),
        anthropic.InternalServerError(
            "boom",
            response=httpx.Response(
                500, request=httpx.Request("POST", "https://api.anthropic.com/v1/messages")
            ),
            body=None,
        ),
        anthropic.APITimeoutError(
            request=httpx.Request("POST", "https://api.anthropic.com/v1/messages")
        ),
    ],
    ids=["rate_limit_429", "server_error_500", "timeout"],
)
def test_auto_falls_back_to_local_on_429_5xx_and_timeout(
    monkeypatch: pytest.MonkeyPatch, exc: BaseException
) -> None:
    # engine and summarize share one ladder (PIPE7), so the transport failures
    # that drop summarize to local drop ask / digest to local too.
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")
    monkeypatch.setattr(engine, "AnthropicTextClient", _raising_anthropic(exc))
    _patch_local(monkeypatch, _FakeLocal(text="fell back"))
    assert _call(_cfg("auto")).backend == "local"


def test_auto_does_not_fall_back_on_a_caller_bug(monkeypatch: pytest.MonkeyPatch) -> None:
    # PIPE7 tightened this path. It used to catch bare `Exception`, so a malformed
    # request or a bug in our own call site silently re-ran on a different model
    # and reported the local backend's answer as if nothing had happened. Only an
    # unreachable-or-unwilling cloud earns the fallback now.
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")
    monkeypatch.setattr(engine, "AnthropicTextClient",
                        _raising_anthropic(ValueError("caller bug")))
    _patch_local(monkeypatch, _FakeLocal(text="must not be reached"))
    with pytest.raises(ValueError, match="caller bug"):
        _call(_cfg("auto"))


def test_empty_local_completion_raises(monkeypatch: pytest.MonkeyPatch) -> None:
    _patch_local(monkeypatch, _FakeLocal(text="   "))
    with pytest.raises(EngineError):
        _call(_cfg("local"))


# ----- PIPE12: the apple_intelligence substitution is a fact, not a log line -----

def _events(logs_dir: Path) -> list[dict]:
    path = logs_dir / "pipeline_events.jsonl"
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]


def test_apple_intelligence_result_names_what_it_substituted_for(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # `backend` reports what ran, so on its own it says "local" and a user who
    # picked Apple Intelligence cannot tell that a multi-GB MLX model was spawned
    # for their question. `substituted_from` is what carries that to the surface.
    _patch_local(monkeypatch, _FakeLocal(text="apple->local"))
    res = _call(_cfg("apple_intelligence"))
    assert res.backend == "local"
    assert res.substituted_from == "apple_intelligence"


@pytest.mark.parametrize("backend", ["local", "anthropic", "auto"])
def test_a_backend_that_answered_for_itself_marks_no_substitution(
    monkeypatch: pytest.MonkeyPatch, backend: str
) -> None:
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")
    monkeypatch.setattr(engine, "AnthropicTextClient", _FakeAnthropic)
    _patch_local(monkeypatch, _FakeLocal())
    assert _call(_cfg(backend)).substituted_from is None


def test_apple_intelligence_substitution_is_recorded_in_the_event_log(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    logs = tmp_path / "logs"
    monkeypatch.setenv("MEETINGPIPE_LOGS_DIR", str(logs))
    _patch_local(monkeypatch, _FakeLocal(text="apple->local"))
    _call(_cfg("apple_intelligence"))

    rows = [r for r in _events(logs) if r["action"] == "engine_backend_substituted"]
    assert len(rows) == 1
    assert rows[0]["category"] == "pipeline"
    assert rows[0]["requested"] == "apple_intelligence"
    assert rows[0]["used"] == "local"
    assert rows[0]["model"] == "fake-local"


def test_the_substitution_is_recorded_even_when_the_local_answer_fails(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    # The substitution is a routing fact, already true before the local model is
    # asked anything, and a failed run is exactly when someone reads the log to
    # find out what actually ran. So it is emitted ahead of the call, not after.
    logs = tmp_path / "logs"
    monkeypatch.setenv("MEETINGPIPE_LOGS_DIR", str(logs))
    _patch_local(monkeypatch, _FakeLocal(text="   "))
    with pytest.raises(EngineError):
        _call(_cfg("apple_intelligence"))

    assert [r["action"] for r in _events(logs)] == ["engine_backend_substituted"]


def test_a_backend_that_answered_for_itself_emits_nothing(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    logs = tmp_path / "logs"
    monkeypatch.setenv("MEETINGPIPE_LOGS_DIR", str(logs))
    _patch_local(monkeypatch, _FakeLocal())
    _call(_cfg("local"))
    assert _events(logs) == []


# ----- PIPE12: the configured LoRA adapter reaches free-form calls -----

class _FakeMLXHandler(BaseHTTPRequestHandler):
    """Just enough `mlx_lm.server` for one free-form completion: a health endpoint,
    so `LocalSummaryClient` reuses this server instead of spawning a real one, and
    a chat-completions endpoint that records the request body it was sent."""

    def log_message(self, *_: object) -> None:  # silence test output
        pass

    def do_GET(self) -> None:  # noqa: N802 (BaseHTTPRequestHandler API)
        self._respond(b'{"data": [{"id": "fake"}]}')

    def do_POST(self) -> None:  # noqa: N802
        length = int(self.headers.get("Content-Length", "0"))
        self.server.captured.append(json.loads(self.rfile.read(length) or b"{}"))  # type: ignore[attr-defined]
        self._respond(json.dumps({"choices": [{"message": {"content": "a local answer"}}]}).encode())

    def _respond(self, body: bytes) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)


@pytest.fixture
def fake_mlx_server():
    server = ThreadingHTTPServer(("127.0.0.1", 0), _FakeMLXHandler)
    server.captured = []  # type: ignore[attr-defined]
    threading.Thread(target=server.serve_forever, daemon=True).start()
    yield server
    server.shutdown()
    server.server_close()


def _served_cfg(server: ThreadingHTTPServer, **summarization: object) -> Config:
    host, port = server.server_address[0], server.server_address[1]
    return Config.model_validate({
        "summarization": {
            "backend": "local",
            "local_model": "fake-local",
            "local_endpoint": f"http://{host}:{port}",
            **summarization,
        },
    })


def test_configured_adapter_serves_free_form_calls_too(
    fake_mlx_server: ThreadingHTTPServer,
) -> None:
    """`_local_client` used to build a `LocalSummaryClient` with model/host/port
    and timeouts only, while `summarize._select_backend` also passed the adapter.
    A trained LoRA (LOCAL9, served per request since LOCAL15) therefore answered
    every summary and no ask, digest, or classification, with nothing in the answer
    to say so."""
    cfg = _served_cfg(fake_mlx_server, local_adapter_path="/adapters/mine")
    res = complete_text(cfg, system_prompt="s", user_message="u", max_tokens=64)
    assert res.text == "a local answer"
    assert fake_mlx_server.captured[-1].get("adapters") == "/adapters/mine"  # type: ignore[attr-defined]


def test_no_configured_adapter_leaves_free_form_calls_on_the_base_model(
    fake_mlx_server: ThreadingHTTPServer,
) -> None:
    # An empty `local_adapter_path` must omit the key rather than send "": the
    # server raises on a path it cannot load, so an empty one would break every
    # ask on an install that has never trained an adapter.
    cfg = _served_cfg(fake_mlx_server)
    complete_text(cfg, system_prompt="s", user_message="u", max_tokens=64)
    assert "adapters" not in fake_mlx_server.captured[-1]  # type: ignore[attr-defined]
