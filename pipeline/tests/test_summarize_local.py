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

from mp import egress_guard
from mp.summarize_local import (
    DEFAULT_REQUEST_TIMEOUT_SEC,
    LocalSummaryClient,
    LocalSummaryError,
    _largest_balanced_json_object,
    scaled_request_timeout,
)


def test_scaled_request_timeout_grows_with_max_tokens():
    """The read timeout must scale with the requested output length so a long
    generation is not cut off, while staying under the daemon's 20-min (1200s)
    watchdog so that watchdog remains the hard backstop (LOCAL2/AUD-21)."""
    base = DEFAULT_REQUEST_TIMEOUT_SEC
    assert scaled_request_timeout(base, 0) == base
    assert scaled_request_timeout(base, 1000) > base
    assert scaled_request_timeout(base, 4000) > scaled_request_timeout(base, 1000)
    assert base < scaled_request_timeout(base, 4000) < 1200
    # A negative/garbage max_tokens never shortens below the base budget.
    assert scaled_request_timeout(base, -5) == base


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


# ----- Language honoring (LOCAL7) -----


def _uk_summary_obj() -> dict:
    return {
        "title": "Планування спринту",
        "summary": ["Обговорили обсяг, ризики і терміни релізу."],
        "decisions": [],
        "actions": [],
        "questions": [],
        "attendees": ["Олена"],
        "detected_language": "uk",
    }


def test_language_mismatch_triggers_one_retry(
    fake_server: tuple[str, int, ThreadingHTTPServer]
) -> None:
    # summary_language=uk, but attempt 1 answers in English; the client must
    # detect the drift and replay once, returning the corrected Ukrainian summary.
    host, port, server = fake_server
    calls = {"n": 0}

    def builder(_: dict) -> dict:
        calls["n"] += 1
        obj = _valid_summary_obj() if calls["n"] == 1 else _uk_summary_obj()
        return {"choices": [{"message": {"content": json.dumps(obj)}}]}

    server.builder = builder  # type: ignore[attr-defined]
    with LocalSummaryClient(
        host=host, port=port, manage_subprocess=False, summary_language="uk"
    ) as c:
        s = c.summarize(
            system_prompt="Summarize.", transcript="A: привіт, є питання.",
            model="ignored", max_tokens=512,
        )
    assert calls["n"] == 2, "expected exactly one language-correction retry"
    assert s.title == "Планування спринту"


def test_action_only_language_drift_triggers_retry(
    fake_server: tuple[str, int, ThreadingHTTPServer]
) -> None:
    # LANG1: a summary whose ONLY drifted section is `actions` must still trigger
    # the local retry. Before LANG1 the local detector omitted the action items,
    # so a Russian/English action block inside an on-target summary shipped
    # unchecked. summary_language=uk; attempt 1 is Ukrainian except for an English
    # action task; the per-section check must catch it and replay once.
    host, port, server = fake_server
    calls = {"n": 0}

    def _uk_with_english_actions() -> dict:
        obj = _uk_summary_obj()
        obj["actions"] = [{
            "task": "Prepare the regression report before the release on Friday.",
            "owner": None, "due": None, "confidence": "medium", "resolved": False,
        }]
        return obj

    def builder(_: dict) -> dict:
        calls["n"] += 1
        obj = _uk_with_english_actions() if calls["n"] == 1 else _uk_summary_obj()
        return {"choices": [{"message": {"content": json.dumps(obj)}}]}

    server.builder = builder  # type: ignore[attr-defined]
    with LocalSummaryClient(
        host=host, port=port, manage_subprocess=False, summary_language="uk"
    ) as c:
        c.summarize(
            system_prompt="Summarize.", transcript="A: привіт, є питання.",
            model="ignored", max_tokens=512,
        )
    assert calls["n"] == 2, "an English-only action block must trigger the language retry"


def test_language_match_does_not_retry(
    fake_server: tuple[str, int, ThreadingHTTPServer]
) -> None:
    host, port, server = fake_server
    calls = {"n": 0}

    def builder(_: dict) -> dict:
        calls["n"] += 1
        return {"choices": [{"message": {"content": json.dumps(_uk_summary_obj())}}]}

    server.builder = builder  # type: ignore[attr-defined]
    with LocalSummaryClient(
        host=host, port=port, manage_subprocess=False, summary_language="uk"
    ) as c:
        s = c.summarize(
            system_prompt="Summarize.", transcript="A: привіт.",
            model="ignored", max_tokens=512,
        )
    assert calls["n"] == 1, "a matching language must not trigger a retry"
    assert s.detected_language == "uk"


def test_unverifiable_forced_language_never_retries(
    fake_server: tuple[str, int, ThreadingHTTPServer]
) -> None:
    # Backend forced to German: the detector cannot verify Latin sub-languages,
    # so an English-looking summary must NOT be mistaken for a mismatch.
    host, port, server = fake_server
    calls = {"n": 0}

    def builder(_: dict) -> dict:
        calls["n"] += 1
        return {"choices": [{"message": {"content": json.dumps(_valid_summary_obj())}}]}

    server.builder = builder  # type: ignore[attr-defined]
    with LocalSummaryClient(
        host=host, port=port, manage_subprocess=False, summary_language="de"
    ) as c:
        c.summarize(
            system_prompt="Summarize.", transcript="Hallo, wir beginnen jetzt.",
            model="ignored", max_tokens=512,
        )
    assert calls["n"] == 1, "an unverifiable target must never trigger a retry"


def test_language_reinforcement_lands_in_system_prompt(
    fake_server: tuple[str, int, ThreadingHTTPServer]
) -> None:
    host, port, server = fake_server
    captured: dict = {}

    def builder(payload: dict) -> dict:
        captured.update(payload)
        return {"choices": [{"message": {"content": json.dumps(_uk_summary_obj())}}]}

    server.builder = builder  # type: ignore[attr-defined]
    with LocalSummaryClient(
        host=host, port=port, manage_subprocess=False, summary_language="uk"
    ) as c:
        c.summarize(
            system_prompt="Summarize.", transcript="A: привіт.",
            model="ignored", max_tokens=512,
        )
    system_msg = captured["messages"][0]["content"]
    assert "Ukrainian" in system_msg
    assert "українською" in system_msg


# ----- SEC13: the spawned server is inside the egress boundary -----


def _fake_spawn(monkeypatch: pytest.MonkeyPatch) -> dict:
    """Capture the argv + kwargs `_spawn` would hand `subprocess.Popen`, without
    launching anything. `_wait_for_health` polls `proc.poll()`, so the stand-in
    reports "still running" and the caller is expected to stop before that."""
    captured: dict = {}

    class _FakeProc:
        pid = 4242

        def poll(self):
            return None

    def _popen(cmd, **kwargs):
        captured["cmd"] = cmd
        captured["kwargs"] = kwargs
        return _FakeProc()

    monkeypatch.setattr("mp.summarize_local.subprocess.Popen", _popen)
    monkeypatch.setattr("mp.summarize_local.shutil.which", lambda name: f"/usr/bin/{name}")
    monkeypatch.setattr("mp.summarize_local.model_is_cached", lambda repo: True)
    return captured


def test_spawn_hands_the_child_a_scrubbed_env_when_armed(monkeypatch: pytest.MonkeyPatch) -> None:
    """The guard patches httpx in *this* process; `mlx_lm.server` is a separate
    process with its own stack. Under a zero-egress run it must inherit no cloud
    token and must find huggingface_hub pinned offline."""
    for key in ("ANTHROPIC_API_KEY", "NOTION_TOKEN", "HF_TOKEN"):
        monkeypatch.setenv(key, "secret-value")
    captured = _fake_spawn(monkeypatch)
    egress_guard.arm("test")

    LocalSummaryClient(host="127.0.0.1", port=8765)._spawn()

    env = captured["kwargs"]["env"]
    assert "ANTHROPIC_API_KEY" not in env
    assert "NOTION_TOKEN" not in env
    assert "HF_TOKEN" not in env
    assert env["HF_HUB_OFFLINE"] == "1"
    assert env["HF_HUB_DISABLE_TELEMETRY"] == "1"


def test_spawn_keeps_the_env_intact_when_disarmed(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ANTHROPIC_API_KEY", "secret-value")
    monkeypatch.delenv("HF_HUB_OFFLINE", raising=False)
    captured = _fake_spawn(monkeypatch)

    LocalSummaryClient(host="127.0.0.1", port=8765)._spawn()

    env = captured["kwargs"]["env"]
    assert env["ANTHROPIC_API_KEY"] == "secret-value"
    assert "HF_HUB_OFFLINE" not in env


def test_spawn_fails_closed_on_an_uncached_model_under_zero_egress(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Fail-closed beats silent egress: an uncached model under regulated/NDA
    would otherwise be downloaded from huggingface.co by the child."""
    _fake_spawn(monkeypatch)
    monkeypatch.setattr("mp.summarize_local.model_is_cached", lambda repo: False)
    egress_guard.arm("test")

    client = LocalSummaryClient(host="127.0.0.1", port=8765, model="mlx-community/Nope-4bit")
    with pytest.raises(LocalSummaryError) as exc:
        client._spawn()
    assert "mp prefetch-model mlx-community/Nope-4bit" in str(exc.value)


def test_spawn_allows_an_uncached_model_when_egress_is_permitted(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The cache gate is a zero-egress rule, not a general one: a normal run may
    still let mlx_lm.server pull the weights on first use."""
    captured = _fake_spawn(monkeypatch)
    monkeypatch.setattr("mp.summarize_local.model_is_cached", lambda repo: False)

    LocalSummaryClient(host="127.0.0.1", port=8765)._spawn()
    assert captured["cmd"][0].endswith("mlx_lm.server")


# ----- PIPE4: hierarchical map-reduce for long transcripts -----

def test_map_reduce_windows_and_reduces_long_transcript(
    fake_server: tuple[str, int, ThreadingHTTPServer]
) -> None:
    """A transcript over the threshold windows into several map calls, then reduces
    the partials into one summary. Every call goes to the same warm local server."""
    host, port, server = fake_server
    requests: list[dict] = []

    def builder(payload: dict) -> dict:
        requests.append(payload)
        return {"choices": [{"message": {"content": json.dumps(_valid_summary_obj())}}]}

    server.builder = builder  # type: ignore[attr-defined]
    # Comfortably longer than one 1500-char window so it splits into several.
    transcript = "\n".join(
        f"Speaker {i % 3}: point number {i} in this fairly long discussion." for i in range(200)
    )
    assert len(transcript) > 1500

    with LocalSummaryClient(
        host=host, port=port, manage_subprocess=False, map_reduce_above_chars=100
    ) as c:
        s = c.summarize(
            system_prompt="Summarize.", transcript=transcript, model="ignored", max_tokens=512
        )

    assert s.title == "Standup"  # the merged summary parsed and validated
    # More than one model call => it mapped windows and reduced, not a single pass.
    assert len(requests) > 1
    # At least one call was a reduce over the partial summaries.
    user_msgs = [
        m["content"] for r in requests for m in r["messages"] if m["role"] == "user"
    ]
    assert any("Merge these partial meeting summaries" in u for u in user_msgs)


def test_short_transcript_is_single_pass_not_map_reduce(
    fake_server: tuple[str, int, ThreadingHTTPServer]
) -> None:
    """Below the threshold the client makes exactly one call, no windows or reduce,
    so the normal-length local path is unchanged by PIPE4."""
    host, port, server = fake_server
    requests: list[dict] = []

    def builder(payload: dict) -> dict:
        requests.append(payload)
        return {"choices": [{"message": {"content": json.dumps(_valid_summary_obj())}}]}

    server.builder = builder  # type: ignore[attr-defined]
    with LocalSummaryClient(host=host, port=port, manage_subprocess=False) as c:
        c.summarize(
            system_prompt="Summarize.", transcript="A: hi. B: bye.", model="ignored", max_tokens=512
        )

    assert len(requests) == 1
    user_msgs = [
        m["content"] for r in requests for m in r["messages"] if m["role"] == "user"
    ]
    assert not any("Merge these partial" in u for u in user_msgs)
