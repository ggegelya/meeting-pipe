"""T10: full-request golden snapshots for the three Anthropic call sites.

Every other Anthropic test in this suite asserts a handful of chosen fields, which
pins what we believe the API accepts and nothing else. The Sonnet 5.5 bump of
2026-10-01 (`09e7e41`) failed every summary on a request-shape 400 that no such
field list covered. These snapshots pin the whole thing each call site sends for
the default model: the body, the method and path, the `anthropic-version` header
and any `anthropic-beta`, and the client's timeout and retry settings (PIPE24's
`providers.make_anthropic_client`). A default-model bump, an `anthropic` lock
refresh, or an edit to a client or to `config.anthropic_sampling` that changes any
of it fails here until the golden is regenerated, so every shape change is a
reviewed diff rather than something the field finds first.

Regenerate (then read the diff before committing it):

    cd pipeline && MP_UPDATE_GOLDENS=1 uv run --extra dev pytest -q tests/test_anthropic_request_goldens.py

A snapshot says what we send, not that the API accepts it. Before changing the
default model, the `anthropic` entry in `uv.lock`, or `anthropic_sampling`, run the
opt-in live contract test in `test_anthropic_live.py` as well.

Nothing volatile is snapshotted: the transcript and prompts are fixed literals,
and the SDK's `user-agent` and `x-stainless-*` headers (which carry the SDK and
platform versions) are left out on purpose.
"""
from __future__ import annotations

import json
import os
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path
from typing import Any
from unittest.mock import patch

import httpx

from mp.config import Summarization

GOLDENS = Path(__file__).parent / "goldens"
UPDATE = os.environ.get("MP_UPDATE_GOLDENS") == "1"

# Synthetic, never a recording.
TRANSCRIPT = (
    "**A:** Morning. Two things today: the release date and the flaky test.\n"
    "**B:** Release is Thursday unless the flaky test blocks it.\n"
    "**A:** Then B owns the flaky test and reports back tomorrow.\n"
)
SYSTEM_PROMPT = "Summarize the meeting."
PINNED_HEADERS = ("anthropic-version", "anthropic-beta", "content-type")


def _message(content: list[dict], stop_reason: str) -> dict:
    return {
        "id": "msg_01",
        "type": "message",
        "role": "assistant",
        "model": Summarization().model,
        "content": content,
        "stop_reason": stop_reason,
        "stop_sequence": None,
        "usage": {"input_tokens": 3, "output_tokens": 2},
    }


@contextmanager
def _capture(reply: dict) -> Iterator[list[dict]]:
    """The same seam as `test_summarize_backend._anthropic_transport`: every
    `httpx.Client` the SDK builds gets a MockTransport that records the request."""
    seen: list[dict] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append({
            "method": request.method,
            "path": request.url.path,
            "headers": {k: request.headers[k] for k in PINNED_HEADERS if k in request.headers},
            "body": json.loads(request.content),
        })
        return httpx.Response(200, request=request, json=reply)

    real_init = httpx.Client.__init__

    def patched_init(self: httpx.Client, *args: Any, **kwargs: Any) -> None:
        kwargs["transport"] = httpx.MockTransport(handler)
        real_init(self, *args, **kwargs)

    with patch.object(httpx.Client, "__init__", patched_init):
        yield seen


def _client_policy(sdk_client: Any) -> dict:
    t = sdk_client.timeout
    return {
        "timeout": {"connect": t.connect, "read": t.read, "write": t.write, "pool": t.pool},
        "max_retries": sdk_client.max_retries,
    }


def _check(name: str, snapshot: dict) -> None:
    path = GOLDENS / f"anthropic-{name}-request.json"
    text = json.dumps(snapshot, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
    if UPDATE:
        path.parent.mkdir(exist_ok=True)
        path.write_text(text, encoding="utf-8")
        return
    assert path.exists(), f"{path.name} missing; regenerate with MP_UPDATE_GOLDENS=1 (module docstring)"
    expected = path.read_text(encoding="utf-8")
    assert text == expected, (
        f"The {name} request changed shape. If that is intended, regenerate with "
        "MP_UPDATE_GOLDENS=1 (module docstring), review the diff, and run the live "
        "contract test (test_anthropic_live.py) before committing it."
    )


def test_summarize_request_matches_its_golden() -> None:
    from mp.summarize import AnthropicSummaryClient

    s = Summarization()
    summary = {
        "title": "Release check", "summary": ["Release is Thursday."], "decisions": [],
        "actions": [], "questions": [], "attendees": ["A", "B"], "detected_language": "en",
    }
    reply = _message(
        [{"type": "tool_use", "id": "toolu_01", "name": "emit_meeting_summary", "input": summary}],
        "tool_use",
    )
    with _capture(reply) as seen:
        client = AnthropicSummaryClient(api_key="sk-test")
        client.summarize(
            system_prompt=SYSTEM_PROMPT, transcript=TRANSCRIPT,
            model=s.model, max_tokens=s.max_tokens,
        )
    assert len(seen) == 1
    _check("summarize", {"client": _client_policy(client._client), "request": seen[0]})


def test_text_request_matches_its_golden() -> None:
    # ask and digest both send through this client.
    from mp.engine import AnthropicTextClient

    s = Summarization()
    reply = _message([{"type": "text", "text": "Thursday."}], "end_turn")
    with _capture(reply) as seen:
        client = AnthropicTextClient(api_key="sk-test", model=s.model)
        client.complete(
            system_prompt="Answer from the meetings.",
            user_message="When is the release?\n\n" + TRANSCRIPT,
            max_tokens=s.max_tokens,
        )
    assert len(seen) == 1
    _check("text", {"client": _client_policy(client._client), "request": seen[0]})


def test_cleanup_request_matches_its_golden() -> None:
    from mp.diarize_cleanup import AnthropicCleanupClient

    s = Summarization()
    reply = _message(
        [{"type": "tool_use", "id": "toolu_01", "name": "emit_speaker_edits", "input": {"edits": []}}],
        "tool_use",
    )
    window = "[0] A: Morning.\n[1] B: Release is Thursday.\n[2] A: Then B owns the flaky test."
    with _capture(reply) as seen:
        client = AnthropicCleanupClient(api_key="sk-test", model=s.model, max_tokens=s.max_tokens)
        client.propose_edits(window_prompt=window, speakers=["A", "B"])
    assert len(seen) == 1
    _check("cleanup", {"client": _client_policy(client._client), "request": seen[0]})
