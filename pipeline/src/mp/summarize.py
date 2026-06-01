"""Anthropic-API-driven meeting summarization with structured output.

Uses tool-use to force schema compliance — the model is required to call
`emit_meeting_summary` exactly once, and its arguments validate against
MeetingSummary. One retry on schema violation; otherwise we surface the error.

Prompt caching is enabled on the system prompt so repeated calls within the
5-minute window only pay ~0.1x for the system block. The transcript itself is
the volatile part and goes after the cache breakpoint.

Two retry layers:
  - `_create_message`: tenacity-wrapped; retries on rate limits, 5xx, and
    transient connection errors with exponential backoff.
  - `_call_with_retry`: one retry on a schema-violating tool_use response.
"""
from __future__ import annotations

import logging
import os
import sys
from importlib import resources
from pathlib import Path
from typing import Any

import anthropic
from pydantic import ValidationError
from tenacity import (
    before_sleep_log,
    retry,
    retry_if_exception_type,
    stop_after_attempt,
    wait_exponential,
)

from .config import Config, load_secrets, require_env
from .schemas import SUMMARY_TOOL, MeetingSummary
from .services import SummaryClient
from .workflow import apply_overrides as apply_workflow_overrides

log = logging.getLogger("mp.summarize")

# Retry only on transient failures. BadRequestError / AuthenticationError /
# PermissionDeniedError / NotFoundError are caller bugs — failing fast is right.
_RETRYABLE_ANTHROPIC = (
    anthropic.RateLimitError,
    anthropic.APIConnectionError,
    anthropic.APITimeoutError,
    anthropic.InternalServerError,
)


@retry(
    reraise=True,
    stop=stop_after_attempt(4),
    # 2s, 4s, 8s — capped at 30s. Anthropic's `retry-after` header would be
    # ideal, but tenacity doesn't read it; this is a reasonable default that
    # respects the SDK's own internal retries (it adds 2 more on top).
    wait=wait_exponential(multiplier=1, min=2, max=30),
    retry=retry_if_exception_type(_RETRYABLE_ANTHROPIC),
    before_sleep=before_sleep_log(log, logging.WARNING),
)
def _create_message(client: anthropic.Anthropic, **kwargs: Any) -> Any:
    """Anthropic call with tenacity retry on rate limits / 5xx / connection errors."""
    return client.messages.create(**kwargs)


def _load_system_prompt(team_context: str, summary_language: str = "auto") -> str:
    # Loaded from the package so the installed venv has the prompt available.
    text = resources.files("mp.prompts").joinpath("meeting_summary.md").read_text(encoding="utf-8")
    text = text.replace("{team_context}", team_context or "(no team context configured)")
    return text.replace(
        "{summary_language_directive}",
        _summary_language_directive(summary_language),
    )


def _summary_language_directive(summary_language: str) -> str:
    """Map the config knob to a one-paragraph directive for the model.

    "auto" → match the transcript's detected language (Russian transcript
    yields a Russian summary). An ISO 639-1 code → force that language
    regardless of transcript language. Anything else falls back to auto
    rather than confusing the model with a malformed directive.
    """
    code = (summary_language or "auto").strip().lower()
    if code == "auto" or len(code) != 2 or not code.isalpha():
        return (
            "Write the summary in the SAME language as the transcript. "
            "If the transcript is in Russian, write everything in Russian. "
            "If it's in Ukrainian, write everything in Ukrainian. English transcript, English summary. "
            "Match the transcript's dominant language for code-switched content."
        )
    return (
        f"Write the summary in language `{code}` (ISO 639-1) regardless of the "
        "transcript's language. Translate quoted phrases as needed; preserve "
        "proper nouns and code identifiers verbatim."
    )


class AnthropicSummaryClient:
    """Concrete `SummaryClient` backed by Anthropic's tool-use API.

    Holds a single `anthropic.Anthropic` instance for connection reuse and
    encapsulates the tool-use round-trip plus one schema-violation retry.
    Constructed once per `summarize()` call; tests substitute a fake
    implementing the same `SummaryClient` protocol.
    """

    def __init__(self, *, api_key: str) -> None:
        self._client = anthropic.Anthropic(api_key=api_key)

    def summarize(
        self,
        *,
        system_prompt: str,
        transcript: str,
        model: str,
        max_tokens: int,
    ) -> MeetingSummary:
        last_err: Exception | None = None
        for attempt in (1, 2):
            log.info("Anthropic call attempt %d (model=%s)", attempt, model)
            response = _create_message(
                self._client,
                model=model,
                max_tokens=max_tokens,
                system=[
                    {
                        "type": "text",
                        "text": system_prompt,
                        "cache_control": {"type": "ephemeral"},
                    },
                ],
                tools=[SUMMARY_TOOL],
                tool_choice={"type": "tool", "name": "emit_meeting_summary"},
                messages=[
                    {
                        "role": "user",
                        "content": (
                            "Summarize this meeting. Call `emit_meeting_summary` exactly once.\n\n"
                            "TRANSCRIPT:\n\n" + transcript
                        ),
                    }
                ],
            )

            tool_blocks = [b for b in response.content if b.type == "tool_use"]
            if not tool_blocks:
                last_err = RuntimeError(f"No tool_use block (stop_reason={response.stop_reason})")
                log.warning("Attempt %d: %s", attempt, last_err)
                continue

            try:
                return MeetingSummary.model_validate(tool_blocks[0].input)
            except ValidationError as ve:
                last_err = ve
                log.warning("Attempt %d: schema violation: %s", attempt, ve)
                continue

        assert last_err is not None
        raise last_err


def summarize(
    transcript_md: Path,
    cfg: Config | None = None,
    *,
    client: SummaryClient | None = None,
    out_suffix: str | None = None,
) -> dict[str, Path | str]:
    """Read `<stem>.md` and write `<stem>.summary.json` + `<stem>.summary.md`.

    The transcript path is the speaker-segmented Markdown produced by the
    daemon (FluidAudio) and finalized by `mp run-all` (rendered to <stem>.md
    by markdown.render_markdown). The .json sidecar is the canonical structured
    output; the .summary.md is a human-readable rendering for Notion / quick review.

    Pass a custom `client` to swap the LLM provider or to inject a fake
    in tests; defaults to `AnthropicSummaryClient`.

    Returns a dict with the written paths plus ``backend`` / ``model``
    naming which path actually produced the summary. Phase 2's
    correction loop reads those fields from the run sidecar.
    """
    cfg = cfg or Config.load()
    # Workflow overlay (TECH-B4). Apply when the daemon wrote a meta
    # sidecar for this stem so the standalone `mp summarize` (used by
    # the Library's "Regenerate" action) honours the same per-meeting
    # context / backend overrides that `run-all` would.
    cfg = apply_workflow_overrides(cfg, transcript_md)
    load_secrets()

    transcript = transcript_md.read_text(encoding="utf-8")
    if not transcript.strip():
        raise ValueError(f"Empty transcript: {transcript_md}")

    system_prompt = _load_system_prompt(
        cfg.summarization.team_context,
        cfg.summarization.summary_language,
    )

    owns_client = client is None
    if client is None:
        client = _select_backend(cfg)

    try:
        summary = client.summarize(
            system_prompt=system_prompt,
            transcript=transcript,
            model=cfg.summarization.model,
            max_tokens=cfg.summarization.max_tokens,
        )
    finally:
        # The plain `local` backend owns an mlx_lm.server subprocess;
        # close it so it does not outlive this CLI process, matching the
        # `auto` path which already scopes its local client in a `with`.
        # Only a client summarize() built itself is closed; an injected
        # client is the caller's to manage, and anthropic/auto have no
        # subprocess and no `close`.
        if owns_client:
            close = getattr(client, "close", None)
            if callable(close):
                close()

    stem = transcript_md.stem
    out_dir = transcript_md.parent
    # `out_suffix` ("candidate") writes a preview sidecar next to the live one
    # without overwriting it (TECH-A16); empty for the normal live output.
    infix = f".{out_suffix}" if out_suffix else ""
    json_path = out_dir / f"{stem}.summary{infix}.json"
    md_path = out_dir / f"{stem}.summary{infix}.md"

    json_path.write_text(
        summary.model_dump_json(indent=2, exclude_none=False),
        encoding="utf-8",
    )
    md_path.write_text(_render_summary_md(summary), encoding="utf-8")

    backend, model_used = _identify_backend(client, cfg)
    log.info("Wrote %s and %s", json_path, md_path)
    return {
        "json": json_path,
        "md": md_path,
        "backend": backend,
        "model": model_used,
    }


def _identify_backend(client: SummaryClient, cfg: Config) -> tuple[str, str]:
    """Map the client that handled the call back to a (backend, model)
    pair for the run sidecar.

    For ``_AutoFallbackClient`` we read ``last_used_*`` which it
    populates per call; the other clients are stable per instance so
    we infer from type + cfg.
    """
    if isinstance(client, _AutoFallbackClient):
        return (
            client.last_used_backend or "anthropic",
            client.last_used_model or cfg.summarization.model,
        )
    if isinstance(client, AnthropicSummaryClient):
        return "anthropic", cfg.summarization.model
    # Local backend: import lazily so non-local installs do not pay
    # the mlx_lm import cost for an isinstance check.
    try:
        from .summarize_local import LocalSummaryClient
    except Exception:
        return "unknown", cfg.summarization.model
    if isinstance(client, LocalSummaryClient):
        return "local", client.model
    return "unknown", cfg.summarization.model


def _select_backend(cfg: Config) -> SummaryClient:
    """Resolve the backend per `summarization.backend`.

    Four backend values (regulated_mode forces local regardless):
      "anthropic":          requires ANTHROPIC_API_KEY.
      "local":              never call Anthropic; build a LocalSummaryClient.
      "auto":               return a _AutoFallbackClient that tries Anthropic
                            first, falls back to local on network/auth failure.
      "apple_intelligence": daemon-only (Swift); raises here if reached directly.
    """
    backend = cfg.summarization.backend
    # regulated_mode is a hard zero-egress guarantee: force the on-device
    # path regardless of the configured backend, mirroring how nda_mode
    # forces local in workflow.apply_overrides. Without this the default
    # backend="anthropic" would still send a confidential transcript out.
    if cfg.modes.regulated_mode and backend != "local":
        log.info("regulated_mode=true; forcing local backend (was %s)", backend)
        backend = "local"
    if backend == "apple_intelligence":
        # The Apple Intelligence summary is produced in the Swift daemon (the
        # macOS 26 Foundation Model is Swift-only). run-all hands off before
        # this is reached; a direct `mp summarize` with this backend is a
        # misconfiguration, so fail loudly rather than silently degrade.
        raise ValueError(
            "summarization.backend='apple_intelligence' runs in the daemon (Swift), "
            "not the Python summarizer. The daemon produces the summary on-device."
        )
    if backend == "local":
        from .summarize_local import LocalSummaryClient
        host, port = _parse_local_endpoint(cfg.summarization.local_endpoint)
        return LocalSummaryClient(
            model=cfg.summarization.local_model,
            host=host,
            port=port,
        )
    if backend == "anthropic":
        api_key = require_env("ANTHROPIC_API_KEY")
        return AnthropicSummaryClient(api_key=api_key)
    if backend == "auto":
        return _AutoFallbackClient(cfg)
    raise ValueError(f"unknown summarization.backend: {backend!r}")


def _parse_local_endpoint(endpoint: str) -> tuple[str, int]:
    # "http://127.0.0.1:8765" → ("127.0.0.1", 8765). Defaults match
    # LocalSummaryClient's defaults so a partially-malformed value
    # degrades to "the right answer most of the time".
    default_host, default_port = "127.0.0.1", 8765
    s = endpoint.strip()
    for prefix in ("http://", "https://"):
        if s.startswith(prefix):
            s = s[len(prefix):]
            break
    if "/" in s:
        s = s.split("/", 1)[0]
    if ":" in s:
        host, port_s = s.rsplit(":", 1)
        try:
            return (host or default_host, int(port_s))
        except ValueError:
            return (host or default_host, default_port)
    return (s or default_host, default_port)


class _AutoFallbackClient:
    """`SummaryClient` that tries Anthropic first, falls back to local
    on network/auth failure. Built once per `summarize()` call so the
    Anthropic auth check is deferred until first use; that lets the
    fallback fire even when ANTHROPIC_API_KEY is unset.
    """

    def __init__(self, cfg: Config) -> None:
        self._cfg = cfg
        # Set per call so `_identify_backend` can attribute the run
        # sidecar to whichever path actually answered.
        self.last_used_backend: str | None = None
        self.last_used_model: str | None = None

    def summarize(
        self,
        *,
        system_prompt: str,
        transcript: str,
        model: str,
        max_tokens: int,
    ) -> MeetingSummary:
        # Read directly rather than via require_env: that helper calls
        # sys.exit on miss, which would prevent us from falling back.
        api_key = os.environ.get("ANTHROPIC_API_KEY", "")
        if api_key:
            try:
                primary = AnthropicSummaryClient(api_key=api_key)
                result = primary.summarize(
                    system_prompt=system_prompt, transcript=transcript,
                    model=model, max_tokens=max_tokens,
                )
                self.last_used_backend = "anthropic"
                self.last_used_model = model
                return result
            except (anthropic.APIConnectionError, anthropic.APITimeoutError,
                    anthropic.AuthenticationError, anthropic.PermissionDeniedError) as e:
                log.warning("Anthropic backend failed (%s); falling back to local", e)
        else:
            log.warning("ANTHROPIC_API_KEY not set; using local backend")

        from .summarize_local import LocalSummaryClient
        host, port = _parse_local_endpoint(self._cfg.summarization.local_endpoint)
        local_model = self._cfg.summarization.local_model
        with LocalSummaryClient(
            model=local_model,
            host=host, port=port,
        ) as fallback:
            result = fallback.summarize(
                system_prompt=system_prompt, transcript=transcript,
                model=model, max_tokens=max_tokens,
            )
            self.last_used_backend = "local"
            self.last_used_model = local_model
            return result


def _render_summary_md(s: MeetingSummary) -> str:
    lines: list[str] = [f"# {s.title}", ""]
    if s.attendees:
        lines.append("**Attendees:** " + ", ".join(s.attendees))
        lines.append("")
    lines.append(f"_Language: {s.detected_language}_")
    lines.append("")

    lines.append("## Summary")
    for bullet in s.summary:
        lines.append(f"- {bullet}")
    lines.append("")

    if s.decisions:
        lines.append("## Decisions")
        for i, d in enumerate(s.decisions, 1):
            lines.append(f"{i}. {d}")
        lines.append("")

    if s.actions:
        lines.append("## Action Items")
        for a in s.actions:
            owner = a.owner or "_unassigned_"
            due = f" — due {a.due}" if a.due else ""
            lines.append(f"- [ ] **{owner}**: {a.task}{due}  _(confidence: {a.confidence})_")
        lines.append("")

    if s.questions:
        lines.append("## Open Questions")
        for q in s.questions:
            lines.append(f"- {q}")
        lines.append("")

    return "\n".join(lines).rstrip() + "\n"


def main(argv: list[str]) -> int:
    if argv and argv[0] == "--print-prompt":
        # Read-only surface for the daemon's Preferences pane (TECH-A15):
        # render the summarization system prompt with the configured team
        # context + summary language so the user sees exactly what the model
        # is told. No transcript, no API call.
        cfg = Config.load()
        print(_load_system_prompt(
            cfg.summarization.team_context,
            cfg.summarization.summary_language,
        ))
        return 0
    # `--candidate` writes a `<stem>.summary.candidate.json/.md` preview without
    # overwriting the live summary, for the Library's local re-run (TECH-A16).
    candidate = "--candidate" in argv
    positional = [a for a in argv if not a.startswith("--")]
    if not positional:
        print("usage: mp summarize <transcript.md> [--candidate]", file=sys.stderr)
        return 2
    md = Path(positional[0]).expanduser().resolve()
    if not md.exists():
        print(f"No such file: {md}", file=sys.stderr)
        return 1
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    summarize(md, out_suffix="candidate" if candidate else None)
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main(sys.argv[1:]))
