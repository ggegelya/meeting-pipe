"""The one table of summarization backends (PIPE19).

Before this, backend choice was an if/elif over the same ids in four places
(`summarize._select_backend`, `engine.complete_text`,
`diarize_cleanup._select_cleanup_backend`, `orchestrate._will_summarize_locally`),
each with its own subset. Cleanup's subset missed `openai` and `claude_cli`, raised
a `ValueError` that `run_all` swallowed as non-fatal, and so the Preferences
cleanup toggle silently did nothing on two offered engines. Adding a backend now
means adding one row here; `test_providers.py` fails if a `BackendName` has none.

Each row says where the backend runs (`locality`) and how to build its three
client shapes. A builder of `None` means "this backend has no such path", and the
caller fails loudly with the backend id. `stand_in` names the row a Python path
runs on instead: Apple Intelligence summarizes in the Swift daemon, so its free-form
text and speaker cleanup run on the local MLX model.

`config.effective_backend` stays the one zero-egress chokepoint. Every caller
resolves the id through it before looking a row up here, so nothing in this table
decides whether cloud is allowed.

This is also the seam T6's fake provider plugs into: swap a row, not a call site.

Builders import their clients lazily, so importing this module costs nothing a
non-local install does not already pay (the pipeline's lazy-import contract), and
so the modules that own the clients can import this one without a cycle.
"""
from __future__ import annotations

import functools
import os
from collections.abc import Callable
from dataclasses import dataclass
from typing import TYPE_CHECKING, Any, Literal

from .config import BACKENDS, Config, parse_local_endpoint, require_env

if TYPE_CHECKING:
    from .diarize_cleanup import CleanupClient
    from .services import SummaryClient

Locality = Literal["on_device", "cloud", "cloud_then_local"]


@dataclass(frozen=True)
class Provider:
    backend_id: str
    locality: Locality
    build_summary: Callable[[Config], SummaryClient] | None
    # `model` overrides the configured model for one free-form call (`mp ask`).
    build_text: Callable[[Config, str | None], Any] | None
    build_cleanup: Callable[[Config], CleanupClient] | None
    stand_in: str | None = None


def lookup(backend: str) -> Provider:
    """The row for `backend`, which the caller has already passed through
    `effective_backend`. An unknown id raises with the id in the message."""
    row = PROVIDERS.get(backend)
    if row is None:
        raise ValueError(
            f"unknown summarization.backend: {backend!r}; choose one of "
            f"{', '.join(sorted(BACKENDS))}"
        )
    return row


# ----- summary builders -----


def _local_summary(cfg: Config) -> SummaryClient:
    from .summarize_local import LocalSummaryClient

    s = cfg.summarization
    host, port = parse_local_endpoint(s.local_endpoint)
    return LocalSummaryClient(
        model=s.local_model,
        host=host,
        port=port,
        startup_timeout_sec=s.local_startup_timeout_sec,
        request_timeout_sec=s.local_request_timeout_sec,
        summary_language=s.summary_language,
        # PIPE4: one knob drives both the cloud paste-bundle guard and the local
        # map-reduce routing, so a long local meeting summarizes instead of bundling.
        map_reduce_above_chars=s.skip_above_chars,
        # LOCAL9: opt-in fine-tuned adapter; empty config keeps the base model.
        adapter_path=s.local_adapter_path or None,
        # LOCAL16: the free-RAM floor this run aborts under, rather than
        # letting a long meeting push the Mac into swapping.
        memory_floor_pct=s.local_memory_floor_pct,
    )


def _anthropic_summary(cfg: Config) -> SummaryClient:
    from .summarize import AnthropicSummaryClient

    return AnthropicSummaryClient(api_key=require_env("ANTHROPIC_API_KEY"))


def _auto_summary(cfg: Config) -> SummaryClient:
    from .summarize import AutoFallbackClient

    return AutoFallbackClient(cfg)


def _claude_cli_summary(cfg: Config) -> SummaryClient:
    # PROV1: no API key; rides the user's Claude Code auth. A cloud backend, so it
    # is unreachable under zero_egress (effective_backend forced local) and refuses
    # to spawn if the guard is somehow armed.
    from .provider_claude_cli import ClaudeCLIClient

    return ClaudeCLIClient()


def _openai_summary(cfg: Config) -> SummaryClient:
    from .provider_openai import OpenAIClient

    return OpenAIClient(api_key=require_env("OPENAI_API_KEY"), model=cfg.summarization.openai_model)


def _apple_summary(cfg: Config) -> SummaryClient:
    # The Apple Intelligence summary is produced in the Swift daemon (the macOS 26
    # Foundation Model is Swift-only). run-all hands off before this is reached; a
    # direct `mp summarize` with this backend is a misconfiguration, so fail loudly
    # rather than silently degrade.
    raise ValueError(
        "summarization.backend='apple_intelligence' runs in the daemon (Swift), "
        "not the Python summarizer. The daemon produces the summary on-device."
    )


# ----- free-form text builders (engine.complete_text) -----
# Routed through `engine`'s module attributes so the engine tests' fakes apply.


def _local_text(cfg: Config, model: str | None) -> Any:
    from . import engine

    return engine.LocalTextClient(cfg, model)


def _anthropic_text(cfg: Config, model: str | None) -> Any:
    from . import engine

    return engine.AnthropicTextClient(
        api_key=require_env("ANTHROPIC_API_KEY"), model=model or cfg.summarization.model
    )


def _auto_text(cfg: Config, model: str | None) -> Any:
    from . import engine

    return engine.AutoTextClient(cfg, model)


# ----- speaker-cleanup builders (diarize_cleanup) -----


def _local_cleanup(cfg: Config) -> CleanupClient:
    from .diarize_cleanup import LocalCleanupClient
    from .summarize_local import LocalSummaryClient

    host, port = parse_local_endpoint(cfg.summarization.local_endpoint)
    return LocalCleanupClient(
        LocalSummaryClient(
            model=cfg.summarization.local_model, host=host, port=port,
            # LOCAL16: the configured floor, not the default, so turning the
            # watchdog down (or off) means the same thing on every local path.
            memory_floor_pct=cfg.summarization.local_memory_floor_pct,
        ),
        max_tokens=cfg.summarization.max_tokens,
    )


def _anthropic_cleanup(cfg: Config) -> CleanupClient:
    from .diarize_cleanup import AnthropicCleanupClient

    return AnthropicCleanupClient(
        api_key=require_env("ANTHROPIC_API_KEY"),
        model=cfg.summarization.model,
        max_tokens=cfg.summarization.max_tokens,
    )


def _auto_cleanup(cfg: Config) -> CleanupClient:
    # Key presence alone, no call-time fallback: `run_all` already treats a
    # cleanup failure as non-fatal and summarizes the un-cleaned transcript, so a
    # retry on a second backend would buy tidier labels at the price of a second
    # model call on an optional polish pass (PIPE7).
    return _anthropic_cleanup(cfg) if os.environ.get("ANTHROPIC_API_KEY") else _local_cleanup(cfg)


def _claude_cli_cleanup(cfg: Config) -> CleanupClient:
    from .diarize_cleanup import TextCleanupClient
    from .provider_claude_cli import ClaudeCLIClient

    return TextCleanupClient(ClaudeCLIClient().complete, max_tokens=cfg.summarization.max_tokens)


def _openai_cleanup(cfg: Config) -> CleanupClient:
    from .diarize_cleanup import TextCleanupClient

    oai = _openai_summary(cfg)
    # JSON mode: the reply is guaranteed to parse; the schema rides in the prompt.
    return TextCleanupClient(
        functools.partial(oai.complete, json_mode=True),  # type: ignore[attr-defined]
        max_tokens=cfg.summarization.max_tokens,
    )


def _plain_text(build: Callable[[Config], Any]) -> Callable[[Config, str | None], Any]:
    """A provider whose one client is both its summary and its text client, and
    which is pinned to its configured model, so the per-call override is moot."""
    return lambda cfg, _model: build(cfg)


PROVIDERS: dict[str, Provider] = {
    "local": Provider(
        "local", "on_device", _local_summary, _local_text, _local_cleanup,
    ),
    "apple_intelligence": Provider(
        "apple_intelligence", "on_device", _apple_summary, None, None, stand_in="local",
    ),
    "anthropic": Provider(
        "anthropic", "cloud", _anthropic_summary, _anthropic_text, _anthropic_cleanup,
    ),
    "auto": Provider(
        "auto", "cloud_then_local", _auto_summary, _auto_text, _auto_cleanup,
    ),
    "claude_cli": Provider(
        "claude_cli", "cloud", _claude_cli_summary, _plain_text(_claude_cli_summary),
        _claude_cli_cleanup,
    ),
    "openai": Provider(
        "openai", "cloud", _openai_summary, _plain_text(_openai_summary), _openai_cleanup,
    ),
}
