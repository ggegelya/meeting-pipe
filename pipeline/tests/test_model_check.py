"""`mp check-model` and doctor's configured-model check (PIPE28). Mock transports only."""
from __future__ import annotations

import json
from collections.abc import Callable

import httpx
import pytest

from mp import doctor, model_check
from mp.config import Config


def _route(monkeypatch: pytest.MonkeyPatch, handler: Callable[[httpx.Request], httpx.Response]) -> list[httpx.Request]:
    seen: list[httpx.Request] = []

    def wrapped(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return handler(request)

    client = httpx.Client(transport=httpx.MockTransport(wrapped))
    monkeypatch.setattr(httpx, "get", client.get)
    monkeypatch.setattr(httpx, "post", client.post)
    return seen


@pytest.mark.parametrize("status,verdict", [(200, "found"), (404, "not_found"), (429, "inconclusive"),
                                            (500, "inconclusive")])
def test_the_verdict_follows_the_models_endpoint(monkeypatch, status, verdict):
    seen = _route(monkeypatch, lambda r: httpx.Response(status, request=r))
    assert model_check.check_anthropic_model("claude-x", "sk-test") == verdict
    assert seen[0].url.path == "/v1/models/claude-x"
    assert seen[0].headers["x-api-key"] == "sk-test"


def test_a_network_error_is_inconclusive_never_not_found(monkeypatch):
    def boom(_r: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("offline")

    _route(monkeypatch, boom)
    assert model_check.check_anthropic_model("claude-x", "sk-test") == "inconclusive"


def _cfg(regulated: bool = False) -> Config:
    return Config.model_validate({"modes": {"regulated_mode": regulated}})


def test_the_subcommand_prints_one_json_line(monkeypatch, capsys):
    monkeypatch.setattr("mp.entry.prepare", lambda *_a, **_k: _cfg())
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")
    _route(monkeypatch, lambda r: httpx.Response(404, request=r))
    assert model_check.main(["claude-gone"]) == 0
    assert json.loads(capsys.readouterr().out) == {"model": "claude-gone", "verdict": "not_found"}


def test_the_subcommand_never_egresses_under_regulated_mode(monkeypatch, capsys):
    monkeypatch.setattr("mp.entry.prepare", lambda *_a, **_k: _cfg(regulated=True))
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")
    seen = _route(monkeypatch, lambda r: httpx.Response(200, request=r))
    assert model_check.main(["claude-x"]) == 0
    assert json.loads(capsys.readouterr().out)["verdict"] == "inconclusive"
    assert seen == []


def test_the_subcommand_without_a_key_is_inconclusive(monkeypatch, capsys):
    monkeypatch.setattr("mp.entry.prepare", lambda *_a, **_k: _cfg())
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    seen = _route(monkeypatch, lambda r: httpx.Response(200, request=r))
    model_check.main(["claude-x"])
    assert json.loads(capsys.readouterr().out)["verdict"] == "inconclusive"
    assert seen == []


# ----- doctor -----


def _doctor_cfg(backend: str = "anthropic", model: str = "claude-gone-1") -> Config:
    return Config.model_validate({"summarization": {"backend": backend, "model": model}})


def test_doctor_names_a_configured_model_the_api_does_not_know(monkeypatch, capsys):
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")

    def handler(r: httpx.Request) -> httpx.Response:
        return httpx.Response(404 if r.url.path.startswith("/v1/models/") else 200, request=r)

    seen = _route(monkeypatch, handler)
    doctor.check_anthropic(True, _doctor_cfg())
    out = capsys.readouterr().out
    assert "[FAIL] configured model claude-gone-1 not found" in out
    # The key check keeps its cheap pinned probe; the *configured* id goes to the models endpoint.
    assert any(r.url.path == "/v1/models/claude-gone-1" for r in seen)


def test_doctor_confirms_a_configured_model_that_exists(monkeypatch, capsys):
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")
    _route(monkeypatch, lambda r: httpx.Response(200, request=r))
    doctor.check_anthropic(True, _doctor_cfg(model="claude-sonnet-5-5"))
    assert "[ OK ] configured model claude-sonnet-5-5 exists" in capsys.readouterr().out


def test_doctor_does_not_check_an_anthropic_model_another_backend_ignores(monkeypatch, capsys):
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")
    seen = _route(monkeypatch, lambda r: httpx.Response(200, request=r))
    doctor.check_anthropic(True, _doctor_cfg(backend="local"))
    assert all(not r.url.path.startswith("/v1/models/") for r in seen)


def test_doctor_checks_the_openai_model_against_the_list_it_already_fetched(monkeypatch, capsys):
    monkeypatch.setenv("OPENAI_API_KEY", "sk-test")
    body = {"data": [{"id": "gpt-4o"}, {"id": "gpt-4o-mini"}]}
    _route(monkeypatch, lambda r: httpx.Response(200, request=r, json=body))
    cfg = Config.model_validate({"summarization": {"backend": "openai", "openai_model": "gpt-9"}})
    doctor.check_openai(True, cfg)
    assert "[FAIL] configured model gpt-9 not found" in capsys.readouterr().out
    cfg = Config.model_validate({"summarization": {"backend": "openai", "openai_model": "gpt-4o"}})
    doctor.check_openai(True, cfg)
    assert "[ OK ] configured model gpt-4o exists" in capsys.readouterr().out
