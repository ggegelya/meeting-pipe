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


# ----- PIPE44: classify on the first matching link of the chain, outermost first -----


def _chain(*errors):
    """Wrap `errors` outermost-first with explicit `from`, as the SDK does."""
    for outer, inner in zip(errors, errors[1:]):
        outer.__cause__ = inner
    return errors[0]


_REQ = httpx.Request("POST", "https://api.anthropic.com/v1/messages")


def _real_chain_error(base_url: str):
    """What `client.messages.create` really raises against `base_url`: a real socket, so the
    error goes through httpcore. An `httpx.MockTransport` would not, and its chain would end at an
    httpx class that already matched before this fix."""
    client = anthropic.Anthropic(api_key="sk-test", base_url=base_url, max_retries=0, timeout=1.0)
    try:
        client.messages.create(model="m", max_tokens=1, messages=[{"role": "user", "content": "x"}])
    except Exception as e:  # noqa: BLE001 - the exception is the thing under test
        return e
    raise AssertionError("the request was expected to fail")


def test_a_real_anthropic_timeout_is_classified_timeout():
    import socket

    from mp.failure_details import describe

    server = socket.socket()
    server.bind(("127.0.0.1", 0))
    server.listen(1)  # accepts into the backlog and never answers
    try:
        err = _real_chain_error(f"http://127.0.0.1:{server.getsockname()[1]}")
    finally:
        server.close()
    assert isinstance(err, anthropic.APITimeoutError)
    assert type(err.__cause__.__cause__).__module__.startswith("httpcore")  # the production chain
    payload = describe(err, operation="summary")
    assert (payload["cause"], payload["provider"], payload["remedy"]) == ("timeout", "anthropic", "retry")


def test_a_real_anthropic_connection_failure_is_classified_connection():
    import socket

    from mp.failure_details import describe

    probe = socket.socket()
    probe.bind(("127.0.0.1", 0))
    port = probe.getsockname()[1]
    probe.close()  # nothing listens here now
    err = _real_chain_error(f"http://127.0.0.1:{port}")
    assert isinstance(err, anthropic.APIConnectionError)
    payload = describe(err, operation="summary")
    assert (payload["cause"], payload["provider"], payload["remedy"]) == ("connection", "anthropic", "retry")


def test_a_hand_built_chain_rooted_in_httpcore_classifies():
    import httpcore

    from mp.failure_details import describe

    timeout = _chain(anthropic.APITimeoutError(request=_REQ), httpx.ReadTimeout("t"), httpcore.ReadTimeout("t"))
    assert describe(timeout, operation="summary")["cause"] == "timeout"
    connect = _chain(anthropic.APIConnectionError(request=_REQ), httpcore.ConnectError("c"))
    assert describe(connect, operation="summary")["cause"] == "connection"
    # A chain that has only the httpcore link is still named.
    assert describe(httpcore.ReadTimeout("t"), operation="summary")["cause"] == "timeout"
    assert describe(httpcore.ConnectError("c"), operation="summary")["cause"] == "connection"


def test_a_wrapper_over_a_known_error_takes_its_classification():
    from mp.failure_details import describe

    wrapped = _chain(RuntimeError("summary stage failed"), anthropic.APITimeoutError(request=_REQ))
    payload = describe(wrapped, operation="summary")
    assert (payload["cause"], payload["provider"]) == ("timeout", "anthropic")


def test_a_chain_with_no_known_link_stays_unknown():
    from mp.failure_details import describe

    chain = _chain(RuntimeError("a"), ValueError("b"), KeyError("c"))
    assert describe(chain, operation="summary")["cause"] == "unknown"


def test_a_wrapped_status_error_keeps_its_status_and_request_id():
    from mp.failure_details import describe

    payload = describe(_chain(RuntimeError("wrapper"), api_error()), operation="summary")
    assert payload["cause"] == "credits"
    assert payload["http_status"] == 400
    assert payload["request_id"] == "req_0123456789abcdef"


def test_a_cyclic_chain_terminates():
    from mp.failure_details import describe

    a, b = RuntimeError("a"), RuntimeError("b")
    a.__cause__, b.__cause__ = b, a
    assert describe(a, operation="summary")["cause"] == "unknown"


# ----- PIPE28: a refused, retired or mistyped model id is its own cause -----


def _status(cls, code, message, *, host="api.anthropic.com", err_type="not_found_error", err_code=None):
    response = httpx.Response(code, request=httpx.Request("POST", f"https://{host}/v1/x"))
    error = {"type": err_type, "message": message}
    if err_code:
        error["code"] = err_code
    return cls(message, response=response, body={"type": "error", "error": error})


@pytest.mark.parametrize("error,provider", [
    (_status(anthropic.NotFoundError, 404, "model: claude-sonnet-9-9"), "anthropic"),
    (_status(anthropic.PermissionDeniedError, 403, "Your API key does not have access to model claude-x",
             err_type="permission_error"), "anthropic"),
])
def test_a_rejected_model_is_its_own_cause_with_the_model_remedy(error, provider):
    from mp.failure_details import describe
    payload = describe(error, operation="summary")
    assert (payload["cause"], payload["remedy"], payload["provider"]) == ("model_rejected", "model", provider)
    assert "claude-" not in json.dumps(payload)  # the id is the owner's to read in Details, not in the sidecar


def test_an_openai_model_not_found_is_a_rejected_model_too():
    from mp.failure_details import describe
    response = httpx.Response(404, request=httpx.Request("POST", "https://api.openai.com/v1/chat/completions"),
                              json={"error": {"code": "model_not_found", "message": "The model `gpt-9` does not exist"}})
    error = httpx.HTTPStatusError("404", request=response.request, response=response)
    payload = describe(error, operation="summary")
    assert (payload["cause"], payload["provider"], payload["remedy"]) == ("model_rejected", "openai", "model")


def test_a_404_or_403_that_is_not_about_a_model_is_unchanged():
    from mp.failure_details import describe
    notion = httpx.Response(404, request=httpx.Request("GET", "https://api.notion.com/v1/pages/x"),
                            json={"code": "object_not_found", "message": "Could not find model database"})
    notion_error = httpx.HTTPStatusError("404", request=notion.request, response=notion)
    assert describe(notion_error, operation="publish")["cause"] == "publish"
    other_404 = _status(anthropic.NotFoundError, 404, "resource not found")
    assert describe(other_404, operation="summary")["cause"] == "unknown"
    key_403 = _status(anthropic.PermissionDeniedError, 403, "forbidden", err_type="permission_error")
    assert describe(key_403, operation="summary")["cause"] == "unknown"
