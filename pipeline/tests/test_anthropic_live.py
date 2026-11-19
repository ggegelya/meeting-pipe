"""T10: the opt-in live contract test for the three Anthropic call sites.

`test_anthropic_request_goldens.py` pins what we send; only the API can say it
accepts it. The Sonnet 5.5 bump of 2026-10-01 failed every summary on a 400 that
every mock-transport test passed. This module sends one small real request through
each call site, so a request-shape change is caught on the owner's machine before
it ships, not in the field.

It never runs in CI and never runs by default: it is marked `live` and skipped
unless BOTH `MP_LIVE_ANTHROPIC=1` and `ANTHROPIC_API_KEY` are set. CI holds no key,
a live call costs money and can flake on the network, and `ci-local.sh` stays
offline. The transcript is synthetic, never a recording.

Run it before changing the default model (`Summarization.model`), the `anthropic`
entry in `uv.lock`, or `config.anthropic_sampling`:

    cd pipeline && MP_LIVE_ANTHROPIC=1 uv run --extra dev pytest -m live -q

`MP_LIVE_MODEL=<id>` tries a candidate model instead of the default. Cost: three
small requests on your Anthropic account.

Last passing run: not yet recorded (owner walkthrough step 1 of T10).
"""
from __future__ import annotations

import os

import pytest

from mp.config import Summarization
from mp.schemas import MeetingSummary

pytestmark = [
    pytest.mark.live,
    pytest.mark.skipif(
        not (os.environ.get("MP_LIVE_ANTHROPIC") == "1" and os.environ.get("ANTHROPIC_API_KEY")),
        reason="live Anthropic contract test: set MP_LIVE_ANTHROPIC=1 and ANTHROPIC_API_KEY",
    ),
]

TRANSCRIPT = "\n".join([
    "**Alex:** Morning, everyone. Two items today: the release date and the flaky test.",
    "**Sam:** The release is planned for Thursday.",
    "**Alex:** Is anything blocking Thursday?",
    "**Sam:** Only the flaky upload test. It fails about one run in ten.",
    "**Alex:** Can you look into it today?",
    "**Sam:** Yes, I will take it and report back tomorrow morning.",
    "**Alex:** Good. If it is not fixed by Wednesday we ship with it quarantined.",
    "**Sam:** Agreed. I will write that down in the release notes.",
    "**Alex:** Anything else? No? Then we are done.",
    "**Sam:** Thanks, see you tomorrow.",
])


def _model() -> str:
    return os.environ.get("MP_LIVE_MODEL") or Summarization().model


def _key() -> str:
    return os.environ["ANTHROPIC_API_KEY"]


def test_live_summarize_returns_a_validated_summary_from_a_tool_block() -> None:
    from mp.summarize import AnthropicSummaryClient

    out = AnthropicSummaryClient(api_key=_key()).summarize(
        system_prompt="Summarize this meeting by calling the tool exactly once.",
        transcript=TRANSCRIPT,
        model=_model(),
        max_tokens=Summarization().max_tokens,
    )
    assert isinstance(out, MeetingSummary)
    assert out.title


def test_live_text_client_returns_text() -> None:
    from mp.engine import AnthropicTextClient

    text = AnthropicTextClient(api_key=_key(), model=_model()).complete(
        system_prompt="Answer in one short sentence from the transcript.",
        user_message="When is the release?\n\n" + TRANSCRIPT,
        max_tokens=200,
    )
    assert text.strip()


def test_live_cleanup_client_returns_parsed_edits() -> None:
    from mp.diarize_cleanup import AnthropicCleanupClient

    window = "\n".join(
        f"[{i}] {line.split(':', 1)[0].strip('*')}: {line.split(':', 1)[1].strip()}"
        for i, line in enumerate(TRANSCRIPT.splitlines()[:4])
    )
    edits = AnthropicCleanupClient(api_key=_key(), model=_model(), max_tokens=1000).propose_edits(
        window_prompt=window, speakers=["Alex", "Sam"],
    )
    # A list (likely empty: the labels are right). A refused request raises instead.
    assert isinstance(edits, list)
