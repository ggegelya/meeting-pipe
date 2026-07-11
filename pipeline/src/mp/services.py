"""Service-layer protocols for external dependencies.

Concrete implementations live alongside their use sites
(`AnthropicSummaryClient` in `summarize.py`, `NotionRestPublisher` in
`publish_notion.py`). The protocols exist so callers depend on
contracts, not vendor SDKs, which:

  - lets tests inject in-memory fakes instead of mocking httpx / anthropic
  - lets us swap providers (a different LLM, a non-Notion sink) without
    touching the orchestrator
  - draws a hard boundary between "domain logic" and "this is how the
    Anthropic SDK happens to be shaped today"

Keep these protocols narrow. They describe what the orchestrator needs,
not everything the underlying SDK can do.
"""
from __future__ import annotations

from pathlib import Path
from typing import Any, Protocol, runtime_checkable

from .schemas import MeetingSummary


@runtime_checkable
class SummaryClient(Protocol):
    """Produces a structured `MeetingSummary` from a transcript.

    Implementations decide how (LLM, hand-written, file paste). The
    orchestrator only knows that calling this returns a validated summary
    or raises.
    """

    def summarize(
        self,
        *,
        system_prompt: str,
        transcript: str,
        model: str,
        max_tokens: int,
    ) -> MeetingSummary: ...


@runtime_checkable
class TextClient(Protocol):
    """Produces free-form assistant text from a single-turn prompt.

    The unstructured counterpart to `SummaryClient`, backing `mp ask` and
    `mp digest` via `engine.complete_text`. Formalized in PROV1 so a provider is
    one module implementing both call shapes (structured summarize + free-form
    complete); the two long-standing shapes previously had no shared contract for
    this one, so `engine` duck-typed against concrete classes. Anthropic's
    existing `AnthropicTextClient` satisfies it structurally and is left as-is.
    """

    def complete(
        self,
        *,
        system_prompt: str,
        user_message: str,
        max_tokens: int,
    ) -> str: ...


@runtime_checkable
class MeetingPublisher(Protocol):
    """Publishes a `MeetingSummary` to whatever sink is configured
    (Notion, an Obsidian vault, the local filesystem, ...).

    Returns a dict with at least `page_id`, `page_url`, and `idempotent`
    (or `regulated: True` when the publisher chose to no-op for
    privacy reasons; `local: True` is also acceptable for local sinks).

    `name` is a stable short identifier (e.g. "notion", "obsidian",
    "filesystem") used to derive the sink's per-stem sidecar path
    (`<stem>.<name>.json`). The orchestrator's multi-sink iteration
    relies on it so two sinks cannot collide on disk.
    """

    name: str

    def upsert(
        self,
        *,
        summary: MeetingSummary,
        transcript_md: Path | None,
        sidecar_path: Path,
    ) -> dict[str, Any]: ...


# Back-compat alias: `NotionPublisher` was the original protocol name
# when the only sink was Notion. Keep the symbol importable so an
# external caller's `from mp.services import NotionPublisher` does
# not break across this rename. New code should use `MeetingPublisher`.
NotionPublisher = MeetingPublisher
