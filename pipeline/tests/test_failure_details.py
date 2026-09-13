import json

import anthropic
import httpx
import pytest

from mp import orchestrate, summarize


def api_error(status=400, message="Your credit balance is too low to access the Anthropic API."):
    response = httpx.Response(status, request=httpx.Request("POST", "https://api.anthropic.com/v1/messages"),
                              headers={"request-id": "req_0123456789abcdef"})
    cls = anthropic.AuthenticationError if status == 401 else anthropic.BadRequestError
    return cls(message, response=response, body={"error": {"type": "invalid_request_error", "message": message}})


@pytest.mark.parametrize("module,command,suffix", [(summarize, "summarize", ".md"),
                                                  (orchestrate, "run_all", ".wav")])
def test_command_boundary_preserves_native_failure_beyond_traceback_tail(tmp_path, monkeypatch, module, command, suffix):
    report = tmp_path / "process-failure.json"
    monkeypatch.setenv("MP_FAILURE_PATH", str(report))
    source = tmp_path / ("synthetic" + suffix)
    source.write_text("synthetic input")

    def fail(*args, **kwargs):
        raise api_error(message="Your credit balance is too low to access the Anthropic API. " + "x" * 9000)

    monkeypatch.setattr(module, command, fail)
    assert module.main([str(source)]) == 1
    payload = json.loads(report.read_text())
    assert payload["cause"] == "credits"
    assert payload["operation"] == "summary"
    assert payload["provider"] == "anthropic"
    assert payload["http_status"] == 400
    assert payload["request_id"] == "req_0123456789abcdef"
    assert "synthetic input" not in report.read_text()
    assert len(report.read_text()) < 512


@pytest.mark.parametrize("error,cause", [
    (api_error(), "credits"),
    (api_error(message="invalid argument"), "unknown"),
    (api_error(401, "invalid x-api-key"), "rejected_key"),
    (api_error(401, "API key has expired"), "expired_key"),
    (httpx.ReadTimeout("secret request body"), "timeout"),
    (httpx.ConnectError("secret request body"), "connection"),
    (RuntimeError("unclassified secret request body"), "unknown"),
])
def test_classification_uses_evidence(error, cause):
    from mp.failure_details import describe
    payload = describe(error, operation="summary")
    assert payload["cause"] == cause
    assert "secret request body" not in json.dumps(payload)


def test_missing_key_and_quota_are_not_temporary_limits():
    from mp.config import MissingSecretError
    from mp.failure_details import describe
    assert describe(MissingSecretError("ANTHROPIC_API_KEY"), operation="ask")["cause"] == "missing_key"
    response = httpx.Response(429, request=httpx.Request("POST", "https://api.openai.com/v1/responses"))
    for code, expected in [("insufficient_quota", "quota"), ("rate_limit_exceeded", "rate_limit")]:
        response._content = json.dumps({"error": {"code": code}}).encode()
        error = httpx.HTTPStatusError("rejected", request=response.request, response=response)
        assert describe(error, operation="ask")["cause"] == expected


def test_report_is_allowlisted_even_with_hostile_metadata():
    from mp.failure_details import describe
    error = api_error()
    error.request_id = "req_fake-secret /Users/private/Meeting Title Bearer sk-test"
    data = describe(error, operation="unknown /Users/private", provider="Bearer sk-test")
    assert data["operation"] == "processing"
    assert "request_id" not in data
    assert "sk-test" not in json.dumps(data)


def test_optional_transport_does_not_write_a_meeting_sidecar(tmp_path, monkeypatch):
    from mp.failure_details import emit_failure
    monkeypatch.delenv("MP_FAILURE_PATH", raising=False)
    monkeypatch.chdir(tmp_path)
    emit_failure(api_error(), operation="summary")
    assert list(tmp_path.iterdir()) == []


def test_standalone_missing_secret_keeps_exit_two(tmp_path, monkeypatch):
    from mp import __main__
    from mp.config import MissingSecretError
    source = tmp_path / "synthetic.md"
    source.write_text("synthetic transcript")
    report = tmp_path / "failure.json"
    monkeypatch.setenv("MP_FAILURE_PATH", str(report))

    def fail(*args, **kwargs):
        raise MissingSecretError("ANTHROPIC_API_KEY")

    monkeypatch.setattr(summarize, "summarize", fail)
    monkeypatch.setattr("sys.argv", ["mp", "summarize", str(source)])
    assert __main__.main() == 2
    assert json.loads(report.read_text())["cause"] == "missing_key"


def test_transport_keeps_the_inner_operation_and_ignores_stale_implicit_context(tmp_path, monkeypatch):
    from mp.failure_details import describe, emit_failure
    target = tmp_path / "failure.json"
    monkeypatch.setenv("MP_FAILURE_PATH", str(target))
    emit_failure(api_error(), operation="publish")
    emit_failure(RuntimeError("outer run-all wrapper"), operation="summary")
    assert json.loads(target.read_text())["operation"] == "publish"
    error = RuntimeError("a new unrelated error")
    error.__context__ = api_error()
    assert describe(error, operation="summary")["cause"] == "unknown"
