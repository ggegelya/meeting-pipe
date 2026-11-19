"""PIPE27: the tokens a run spent, summed across every metered model call it made.

The long-meeting gate exists to save money, and until this nothing recorded what a
run cost: no module read the SDK response's `usage`. Every Anthropic call goes
through `summarize._create_message` and every OpenAI call through
`provider_openai.OpenAIClient`, so those two seams record here, and the run reads one
total into `<stem>.run.json` and its `run_completed` event. Tokens only, never a
price: prices change, tokens do not.

One `mp` process is one run, so the tally is process-wide; `reset` exists for the
in-process callers (tests, and a run that starts after an earlier one in the same
interpreter). Thread-safe, since the speaker cleanup and summarize may overlap.
"""
from __future__ import annotations

import threading
from typing import Any

#: The keys a usage block may carry, in the Anthropic response's own names.
KEYS = (
    "input_tokens",
    "output_tokens",
    "cache_creation_input_tokens",
    "cache_read_input_tokens",
)

_lock = threading.Lock()
_totals: dict[str, int] = {}


def reset() -> None:
    with _lock:
        _totals.clear()


def _add(values: dict[str, int]) -> None:
    with _lock:
        _totals["calls"] = _totals.get("calls", 0) + 1
        for key, value in values.items():
            _totals[key] = _totals.get(key, 0) + value


def _count(value: Any) -> int | None:
    # `bool` is an `int` subclass and is never a token count.
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        return None
    return value


def record_anthropic(response: Any) -> None:
    """Add an Anthropic `Message`'s `usage`. A response without one (a test fake) adds
    nothing, so a run on fakes records no usage rather than a zero it never measured."""
    block = getattr(response, "usage", None)
    if block is None:
        return
    values = {k: n for k in KEYS if (n := _count(getattr(block, k, None))) is not None}
    if values:
        _add(values)


def record_openai(payload: Any) -> None:
    """Add an OpenAI chat completion's `usage` (`prompt_tokens`, `completion_tokens`,
    and `prompt_tokens_details.cached_tokens` when present), in the Anthropic names."""
    block = payload.get("usage") if isinstance(payload, dict) else None
    if not isinstance(block, dict):
        return
    values: dict[str, int] = {}
    if (n := _count(block.get("prompt_tokens"))) is not None:
        values["input_tokens"] = n
    if (n := _count(block.get("completion_tokens"))) is not None:
        values["output_tokens"] = n
    details = block.get("prompt_tokens_details")
    if isinstance(details, dict) and (n := _count(details.get("cached_tokens"))):
        values["cache_read_input_tokens"] = n
    if values:
        _add(values)


def snapshot() -> dict[str, int] | None:
    """The run's totals so far (`calls` plus whichever `KEYS` were reported), or None
    when no metered call ran, so an on-device run writes no `usage` at all."""
    with _lock:
        return dict(_totals) if _totals else None
