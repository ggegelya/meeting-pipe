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

import json
import logging
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


def _load_system_prompt(team_context: str) -> str:
    # Loaded from the package so the installed venv has the prompt available.
    text = resources.files("mp.prompts").joinpath("meeting_summary.md").read_text(encoding="utf-8")
    return text.replace("{team_context}", team_context or "(no team context configured)")


def summarize(transcript_md: Path, cfg: Config | None = None) -> dict[str, Path]:
    """Read `<stem>.md` and write `<stem>.summary.json` + `<stem>.summary.md`.

    The transcript path is the speaker-segmented Markdown produced by
    `mp transcribe`. The .json sidecar is the canonical structured output;
    the .summary.md is a human-readable rendering for Notion / quick review.
    """
    cfg = cfg or Config.load()
    load_secrets()
    api_key = require_env("ANTHROPIC_API_KEY")

    transcript = transcript_md.read_text(encoding="utf-8")
    if not transcript.strip():
        raise ValueError(f"Empty transcript: {transcript_md}")

    system_prompt = _load_system_prompt(cfg.summarization.team_context)
    client = anthropic.Anthropic(api_key=api_key)

    summary = _call_with_retry(client, cfg, system_prompt, transcript)

    stem = transcript_md.stem
    out_dir = transcript_md.parent
    json_path = out_dir / f"{stem}.summary.json"
    md_path = out_dir / f"{stem}.summary.md"

    json_path.write_text(
        summary.model_dump_json(indent=2, exclude_none=False),
        encoding="utf-8",
    )
    md_path.write_text(_render_summary_md(summary), encoding="utf-8")

    log.info("Wrote %s and %s", json_path, md_path)
    return {"json": json_path, "md": md_path}


def _call_with_retry(
    client: anthropic.Anthropic,
    cfg: Config,
    system_prompt: str,
    transcript: str,
) -> MeetingSummary:
    last_err: Exception | None = None
    for attempt in (1, 2):
        log.info("Anthropic call attempt %d (model=%s)", attempt, cfg.summarization.model)
        response = _create_message(
            client,
            model=cfg.summarization.model,
            max_tokens=cfg.summarization.max_tokens,
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
    if not argv:
        print("usage: mp summarize <transcript.md>", file=sys.stderr)
        return 2
    md = Path(argv[0]).expanduser().resolve()
    if not md.exists():
        print(f"No such file: {md}", file=sys.stderr)
        return 1
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    summarize(md)
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main(sys.argv[1:]))
