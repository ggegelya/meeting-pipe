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
from typing import Any, TypedDict

import anthropic
import httpx
from pydantic import ValidationError
from tenacity import (
    before_sleep_log,
    retry,
    retry_if_exception,
    stop_after_attempt,
    wait_exponential,
)

from . import entry
from .backend_fallback import run_with_local_fallback
from .config import Config, effective_backend, parse_local_endpoint, require_env
from .markdown import render_summary_md
from .markers import FLAGGED_INSTRUCTION, flagged_moments_block
from .prompt_safety import UNTRUSTED_GUIDANCE, wrap_untrusted
from .schemas import SUMMARY_TOOL, MeetingSummary
from .services import SummaryClient
from .summary_language import (
    divergent_sections,
    expected_summary_language,
    language_reinforcement,
)
from .workflow import read_meta

log = logging.getLogger("mp.summarize")


class SummaryOutput(TypedDict):
    """What `summarize()` wrote, and which path wrote it. `backend` / `model` are
    what the run sidecar records, so a summary can always be attributed to the
    engine that actually answered (`auto` resolves per call)."""

    json: Path
    md: Path
    backend: str
    model: str

# Retry only on transient failures. BadRequestError / AuthenticationError /
# PermissionDeniedError / NotFoundError are caller bugs, so failing fast is right.
_RETRYABLE_ANTHROPIC = (
    anthropic.RateLimitError,
    anthropic.APIConnectionError,
    anthropic.APITimeoutError,
    anthropic.InternalServerError,
)


def _should_retry_anthropic(exc: BaseException) -> bool:
    """Retry transient failures, but NOT a timeout.

    A timeout means a stalled connection; retrying just re-hangs the run. A
    stall should drop straight to the backend fallback (local) instead. Rate
    limits, 5xx, and connection resets are genuinely transient and worth a
    backed-off retry. (APITimeoutError subclasses APIConnectionError, so the
    explicit exclusion below is load-bearing, not redundant.)
    """
    if isinstance(exc, anthropic.APITimeoutError):
        return False
    return isinstance(exc, _RETRYABLE_ANTHROPIC)


# Bound every request so a stalled connection fails in ~2 min and falls back to
# local, instead of the SDK's ~10-minute default (a real 8.8k-char summary hung
# the pipeline for the full 10 minutes). Chunked summarization bounds each call's
# output, so 120 s is generous for legitimate generation while still catching a
# stall. Paired with max_retries=0 on the client so the SDK does not internally
# re-try a timeout before this layer's fallback sees it.
_REQUEST_TIMEOUT = httpx.Timeout(120.0, connect=10.0)


@retry(
    reraise=True,
    stop=stop_after_attempt(4),
    # 2s, 4s, 8s, capped at 30s. tenacity is the sole retry layer now: the client
    # is built with max_retries=0, so a timeout is not internally re-tried before
    # the timeout-aware fallback sees it. (Anthropic's retry-after header would be
    # ideal for 429s, but tenacity does not read it; this backoff is a substitute.)
    wait=wait_exponential(multiplier=1, min=2, max=30),
    retry=retry_if_exception(_should_retry_anthropic),
    before_sleep=before_sleep_log(log, logging.WARNING),
)
def _create_message(client: anthropic.Anthropic, **kwargs: Any) -> Any:
    """Anthropic call with tenacity retry on rate limits / 5xx / connection errors."""
    return client.messages.create(**kwargs)


def _load_system_prompt(
    team_context: str,
    summary_language: str = "auto",
    prior_context: str | None = None,
    flagged_note: bool = False,
) -> str:
    # Loaded from the package so the installed venv has the prompt available.
    text = resources.files("mp.prompts").joinpath("meeting_summary.md").read_text(encoding="utf-8")
    text = text.replace("{team_context}", team_context or "(no team context configured)")
    text = text.replace(
        "{summary_language_directive}",
        _summary_language_directive(summary_language),
    )
    # AI6: recurring-series continuity. Trusted block (our own prior summary),
    # so it sits before the untrusted-transcript boundary below.
    if prior_context:
        text = text + "\n\n" + prior_context
    # FEAT8: the flag-a-moment instruction is trusted; the excerpts it points at
    # ride in the (untrusted) transcript.
    if flagged_note:
        text = text + "\n\n" + FLAGGED_INSTRUCTION
    # Prompt-injection boundary (TECH-SEC6): the transcript is wrapped in
    # untrusted markers in the user message; tell the model not to obey it.
    return text + "\n\n" + UNTRUSTED_GUIDANCE


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


# AI6: bound the injected prior-meeting block so it stays a hint, not a second
# transcript. Latest prior meeting only.
_AI6_MAX_DECISIONS = 12
_AI6_MAX_ACTIONS = 12
_AI6_MAX_ITEM_CHARS = 240


def _ai6_trim(s: str) -> str:
    s = s.strip()
    return s if len(s) <= _AI6_MAX_ITEM_CHARS else s[: _AI6_MAX_ITEM_CHARS - 3].rstrip() + "..."


def _prior_meeting_context(transcript_md: Path, cfg: Config) -> str | None:
    """AI6: a bounded continuity block from the same workflow's latest prior
    meeting (its decisions + still-open actions), or None.

    The workflow is the explicit series key (resolved per meeting in the meta
    sidecar); no fuzzy series inference. Assembled from local disk, so cloud and
    local backends receive it identically and the egress profile is unchanged
    (it routes to whichever backend already summarizes this transcript). The
    first meeting in a workflow, or one with no prior decisions/open actions, is
    a clean no-op.
    """
    workflow_id = read_meta(transcript_md).get("workflow_id")
    if not workflow_id:
        return None
    out_dir = cfg.recording.output_dir
    if not out_dir.exists():
        return None

    current_stem = transcript_md.name.split(".", 1)[0]
    prior_stem: str | None = None
    prior_path: Path | None = None
    for summary_json in out_dir.glob("*.summary.json"):
        stem = summary_json.name.split(".", 1)[0]
        if stem >= current_stem:  # self or a later meeting; stems sort chronologically
            continue
        if read_meta(summary_json).get("workflow_id") != workflow_id:
            continue
        if prior_stem is None or stem > prior_stem:
            prior_stem, prior_path = stem, summary_json
    if prior_path is None:
        return None

    try:
        prior = MeetingSummary.model_validate_json(prior_path.read_text(encoding="utf-8"))
    except (OSError, ValidationError) as e:
        log.warning("AI6: skipping unreadable prior summary %s: %s", prior_path, e)
        return None

    decisions = [d.strip() for d in prior.decisions if d.strip()][:_AI6_MAX_DECISIONS]
    open_actions = [a for a in prior.actions if not a.resolved][:_AI6_MAX_ACTIONS]
    if not decisions and not open_actions:
        return None

    workflow_name = read_meta(transcript_md).get("workflow_name") or "this"
    lines = [
        "## Previous meeting in this series",
        "",
        f'This meeting continues the "{workflow_name}" series. The items below are '
        f'carried over from the previous meeting ("{prior.title}"). If any of them '
        "recur, treat them as carried over (a continuing decision, an action still "
        "in progress) and say so, rather than re-listing them as brand-new "
        "discoveries.",
    ]
    if decisions:
        lines += ["", "Decisions already made:"]
        lines += [f"- {_ai6_trim(d)}" for d in decisions]
    if open_actions:
        lines += ["", "Open action items still outstanding:"]
        for a in open_actions:
            owner = (a.owner or "unassigned").strip() or "unassigned"
            due = f" (due {a.due})" if a.due else ""
            lines.append(f"- {owner}: {_ai6_trim(a.task)}{due}")
    return "\n".join(lines)


class AnthropicSummaryClient:
    """Concrete `SummaryClient` backed by Anthropic's tool-use API.

    Holds a single `anthropic.Anthropic` instance for connection reuse and
    encapsulates the tool-use round-trip plus one schema-violation retry.
    Constructed once per `summarize()` call; tests substitute a fake
    implementing the same `SummaryClient` protocol.
    """

    def __init__(self, *, api_key: str) -> None:
        self._client = anthropic.Anthropic(
            api_key=api_key,
            timeout=_REQUEST_TIMEOUT,
            max_retries=0,
        )

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
                            + wrap_untrusted(transcript)
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
) -> SummaryOutput:
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
    # The entry contract (SEC13): overlay, arm, secrets. The overlay matters for
    # the standalone `mp summarize` (the Library's "Regenerate" action) so it
    # honours the same per-meeting context / backend overrides `run-all` would.
    cfg = entry.prepare(cfg, transcript_md)

    transcript = transcript_md.read_text(encoding="utf-8")
    if not transcript.strip():
        raise ValueError(f"Empty transcript: {transcript_md}")

    # TECH-FEAT7: an ad-hoc reprocess can override only the CONTEXT block for this
    # one run via MP_CONTEXT_OVERRIDE. It replaces the team_context VALUE fed into
    # the prompt, never the prompt template or the tool-use / schema contract, and
    # is request-scoped: cfg is not mutated and nothing is persisted. Empty or
    # whitespace-only is a no-op (a plain reprocess on the configured context).
    team_context = cfg.summarization.team_context
    override = os.environ.get("MP_CONTEXT_OVERRIDE")
    if override and override.strip():
        team_context = override
        log.info("summarize: applying request-scoped MP_CONTEXT_OVERRIDE")

    # FEAT8: append the user-flagged excerpts to the transcript (they stay in
    # the untrusted zone with the rest of it) and flag them so the system prompt
    # carries the trusted instruction to reflect them.
    flagged = flagged_moments_block(transcript_md)
    if flagged:
        transcript = transcript + "\n\n" + flagged

    system_prompt = _load_system_prompt(
        team_context,
        cfg.summarization.summary_language,
        prior_context=_prior_meeting_context(transcript_md, cfg),
        flagged_note=bool(flagged),
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
        # LANG1: verify the produced summary's language and repair it once if a
        # section drifted, for every backend. Runs while the (possibly
        # subprocess-backed) client is still open below, so a repair reuses it.
        summary = _verify_and_repair_language(
            client, summary, system_prompt, transcript, cfg
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
    md_path.write_text(render_summary_md(summary), encoding="utf-8")

    backend, model_used = _identify_backend(client, cfg)
    log.info("Wrote %s and %s", json_path, md_path)
    return SummaryOutput(
        json=json_path,
        md=md_path,
        backend=backend,
        model=model_used,
    )


def _verify_and_repair_language(
    client: SummaryClient,
    summary: MeetingSummary,
    system_prompt: str,
    transcript: str,
    cfg: Config,
) -> MeetingSummary:
    """LANG1: verify the produced summary's language and repair it once, for any
    backend.

    Before LANG1 only the local client checked its own output (LOCAL7), and even
    that omitted the action items; the Anthropic path verified nothing, so a
    cloud summary whose ``questions`` / ``actions`` came back in the wrong
    language shipped unchecked (confirmed on an all-English transcript that
    produced Russian action items). Here, once the client has answered, we detect
    the language of each language-bearing section and, if any diverges from the
    language the transcript implies, re-ask the *same* client once with a
    reinforced directive. The repair is kept only when it is clean; a failed or
    still-divergent repair falls back to the original, so verification never costs
    the summary itself.

    A no-op when the language cannot be cheaply verified
    (``expected_summary_language`` returns None) or when every section already
    matches. The local client has usually repaired its own drift by the time we
    get here (LOCAL7), so this is a cheap check for it and the first real safety
    net for the cloud path.
    """
    target = expected_summary_language(cfg.summarization.summary_language, transcript)
    if target is None:
        return summary
    diverging = divergent_sections(summary, target)
    if not diverging:
        return summary
    log.warning(
        "summary sections %s diverge from expected language %r; repairing",
        diverging, target,
    )
    try:
        repaired = client.summarize(
            system_prompt=system_prompt + language_reinforcement(target),
            transcript=transcript,
            model=cfg.summarization.model,
            max_tokens=cfg.summarization.max_tokens,
        )
    except Exception as e:  # a failed *repair* must never sink an already-valid summary
        log.warning("language repair call failed (%s); keeping the original summary", e)
        return summary
    still = divergent_sections(repaired, target)
    if still:
        log.warning(
            "language repair still diverges (%s); keeping the original summary", still
        )
        return summary
    log.info("language repair produced a summary matching %r", target)
    return repaired


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
    # The regulated/NDA force-local rule lives in one place now
    # (config.effective_backend, TECH-ARCH1). Apply it, then keep this site's
    # own apple_intelligence / auto handling below.
    backend = effective_backend(cfg)
    if backend != cfg.summarization.backend:
        log.info("zero-egress mode active; forcing local backend (was %s)",
                 cfg.summarization.backend)
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
        host, port = parse_local_endpoint(cfg.summarization.local_endpoint)
        return LocalSummaryClient(
            model=cfg.summarization.local_model,
            host=host,
            port=port,
            startup_timeout_sec=cfg.summarization.local_startup_timeout_sec,
            request_timeout_sec=cfg.summarization.local_request_timeout_sec,
            summary_language=cfg.summarization.summary_language,
        )
    if backend == "anthropic":
        api_key = require_env("ANTHROPIC_API_KEY")
        return AnthropicSummaryClient(api_key=api_key)
    if backend == "auto":
        return _AutoFallbackClient(cfg)
    raise ValueError(f"unknown summarization.backend: {backend!r}")


class _AutoFallbackClient:
    """`SummaryClient` that tries Anthropic first, falls back to local
    on network / auth / rate-limit / server-error failure (TECH-FEAT5).
    Built once per `summarize()` call so the Anthropic auth check is
    deferred until first use; that lets the fallback fire even when
    ANTHROPIC_API_KEY is unset.

    The ladder itself lives in `backend_fallback.run_with_local_fallback`,
    shared with `engine.complete_text` (PIPE7).
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
        def _cloud() -> MeetingSummary:
            primary = AnthropicSummaryClient(api_key=os.environ["ANTHROPIC_API_KEY"])
            return primary.summarize(
                system_prompt=system_prompt, transcript=transcript,
                model=model, max_tokens=max_tokens,
            )

        def _local() -> MeetingSummary:
            from .summarize_local import LocalSummaryClient
            host, port = parse_local_endpoint(self._cfg.summarization.local_endpoint)
            with LocalSummaryClient(
                model=self._cfg.summarization.local_model,
                host=host, port=port,
                startup_timeout_sec=self._cfg.summarization.local_startup_timeout_sec,
                request_timeout_sec=self._cfg.summarization.local_request_timeout_sec,
                summary_language=self._cfg.summarization.summary_language,
            ) as fallback:
                return fallback.summarize(
                    system_prompt=system_prompt, transcript=transcript,
                    model=model, max_tokens=max_tokens,
                )

        result, backend = run_with_local_fallback(cloud=_cloud, local=_local)
        self.last_used_backend = backend
        self.last_used_model = (
            model if backend == "anthropic" else self._cfg.summarization.local_model
        )
        return result


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
