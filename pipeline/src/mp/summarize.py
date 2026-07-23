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

from . import entry, storage, transcript_corrections
from .backend_fallback import run_with_local_fallback
from .config import (
    Config,
    ExtraSectionSpec,
    effective_backend,
    extract_backend_flag,
    parse_local_endpoint,
    require_env,
    with_backend_override,
)
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
    """What `summarize()` wrote, and which path wrote it. `backend` / `model` /
    `adapter_path` are what the run sidecar records, so a summary can always be
    attributed to the engine that actually answered (`auto` resolves per call, and
    LOCAL11 resolves `model` / `adapter_path` to what the local server was really
    serving rather than what config asked for). `adapter_path` is "" for every
    backend but a local one running a LoRA adapter."""

    json: Path
    md: Path
    backend: str
    model: str
    adapter_path: str

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


def _extra_sections_directive(specs: list[ExtraSectionSpec] | None) -> str:
    """WF7: the system-prompt block that asks the model to fill `extra_sections`.

    A trusted instruction (the workflow author's, not the transcript's). When a
    workflow defines no sections the model is told to leave `extra_sections`
    empty, so an ordinary meeting's summary shape is unchanged."""
    if not specs:
        return "Leave `extra_sections` empty: no extra sections are requested for this meeting."
    lines = [
        "In addition to the standard fields, fill `extra_sections` with EXACTLY the "
        "sections listed below, using each `name` verbatim and following its "
        "instruction. Include a section even when this meeting gives it nothing "
        "(use an empty `content` list). Do NOT add any section that is not listed here.",
        "",
    ]
    for i, s in enumerate(specs, 1):
        lines.append(f'{i}. "{s.name}": {s.instruction}')
    return "\n".join(lines)


def _load_system_prompt(
    team_context: str,
    summary_language: str = "auto",
    prior_context: str | None = None,
    flagged_note: bool = False,
    extra_sections: list[ExtraSectionSpec] | None = None,
) -> str:
    # Loaded from the package so the installed venv has the prompt available.
    text = resources.files("mp.prompts").joinpath("meeting_summary.md").read_text(encoding="utf-8")
    text = text.replace("{team_context}", team_context or "(no team context configured)")
    text = text.replace(
        "{summary_language_directive}",
        _summary_language_directive(summary_language),
    )
    text = text.replace("{extra_sections_directive}", _extra_sections_directive(extra_sections))
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
    first meeting in a workflow, one with no prior decisions/open actions, or one
    whose language differs from this meeting's (LANG1: a foreign-language block
    would pull the summary into the wrong language) is a clean no-op.
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

    # LANG1/AI6: this continuity block is trusted context placed before the
    # (untrusted) transcript, so the model mirrors ITS language. When the prior
    # meeting is in a different language than this one, that pulls the whole
    # summary into the prior's language and even defeats the post-hoc language
    # repair, which re-uses this same block (an all-English meeting following a
    # Ukrainian one in the same workflow shipped a fully Ukrainian summary). Carry
    # facts only within one language: drop the block when the prior's language is
    # known and differs from this meeting's target output language.
    target_lang = expected_summary_language(
        cfg.summarization.summary_language, transcript_md.read_text(encoding="utf-8")
    )
    prior_lang = (prior.detected_language or "").strip().lower()
    if target_lang is not None and prior_lang and prior_lang != target_lang:
        log.info(
            "AI6: dropping prior %s continuity (language %s); differs from this "
            "meeting's target language %s",
            prior_stem, prior_lang, target_lang,
        )
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
    backend: str | None = None,
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

    # PIPE6: a one-shot backend override for this re-summarize, applied AFTER the
    # workflow overlay so it wins over the workflow's persisted backend but still
    # flows through effective_backend's regulated/NDA clamp. Request-scoped; the
    # workflow TOML is untouched (rewriting it is WF8's job).
    if backend is not None:
        cfg = with_backend_override(cfg, backend)
        log.info("summarize: one-shot backend override -> %s", backend)

    # FEAT3-UNDO / FEAT3-SEGMENT + PIPE9: if the user renamed/reassigned speakers or
    # edited transcript lines in the Library, apply both reversible overlays so the
    # regenerated summary + attendees reflect them. No overlay -> use <stem>.md as-is.
    overlaid = transcript_corrections.overlaid_markdown(transcript_md)
    transcript = overlaid if overlaid is not None else transcript_md.read_text(encoding="utf-8")
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
        extra_sections=cfg.summarization.extra_sections,
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

    # Atomic (PIPE8) + 0600 (SEC14): a crash mid-rewrite leaves the prior summary
    # intact rather than a truncated one; summaries carry meeting content.
    storage.atomic_write_text(json_path, summary.model_dump_json(indent=2, exclude_none=False))
    storage.atomic_write_text(md_path, render_summary_md(summary))

    backend, model_used = _identify_backend(client, cfg)
    log.info("Wrote %s and %s", json_path, md_path)
    return SummaryOutput(
        json=json_path,
        md=md_path,
        backend=backend,
        model=model_used,
        adapter_path=_identify_adapter(client),
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
    # PROV1 providers: light modules, so a direct import here is cheap.
    from .provider_claude_cli import ClaudeCLIClient
    if isinstance(client, ClaudeCLIClient):
        return "claude_cli", client.model
    from .provider_openai import OpenAIClient
    if isinstance(client, OpenAIClient):
        return "openai", client.model
    # Local backend: import lazily so non-local installs do not pay
    # the mlx_lm import cost for an isinstance check.
    try:
        from .summarize_local import LocalSummaryClient
    except Exception:
        return "unknown", cfg.summarization.model
    if isinstance(client, LocalSummaryClient):
        return "local", client.model
    return "unknown", cfg.summarization.model


def _identify_adapter(client: SummaryClient) -> str:
    """LoRA adapter the answering client served, or "" (LOCAL9/LOCAL11).

    Only the local backend has one, and only it can report the *served* value
    rather than the configured one. Duck-typed rather than isinstance-checked so
    both shapes answer with one rule: `_AutoFallbackClient` publishes
    `last_used_adapter_path` per call, `LocalSummaryClient` exposes
    `adapter_path`, and every other backend has neither."""
    for attr in ("last_used_adapter_path", "adapter_path"):
        value = getattr(client, attr, None)
        if isinstance(value, str):
            return value
    return ""


def _served_local_identity(client: object, cfg: Config) -> tuple[str, str]:
    """The ``(model, adapter_path)`` a local client reports actually serving,
    falling back to the configured pair (LOCAL11).

    Tolerant on purpose. This is attribution metadata read *after* a summary has
    already been produced, so a client that does not publish its identity must
    cost the caller a less precise sidecar, never the summary itself. Same rule
    ``orchestrate`` applies one layer up, where a failed ``write_run_sidecar`` is
    logged rather than raised.
    """
    model = getattr(client, "model", None)
    adapter = getattr(client, "adapter_path", None)
    return (
        model if isinstance(model, str) and model else cfg.summarization.local_model,
        adapter if isinstance(adapter, str) else (cfg.summarization.local_adapter_path or ""),
    )


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
            # PIPE4: one knob drives both the cloud paste-bundle guard and the local
            # map-reduce routing, so a long local meeting summarizes instead of bundling.
            map_reduce_above_chars=cfg.summarization.skip_above_chars,
            # LOCAL9: opt-in fine-tuned adapter; empty config keeps the base model.
            adapter_path=cfg.summarization.local_adapter_path or None,
        )
    if backend == "anthropic":
        api_key = require_env("ANTHROPIC_API_KEY")
        return AnthropicSummaryClient(api_key=api_key)
    if backend == "auto":
        return _AutoFallbackClient(cfg)
    if backend == "claude_cli":
        # PROV1: no API key; rides the user's Claude Code auth. A cloud backend,
        # so it is unreachable here under zero_egress (effective_backend forced
        # local) and refuses to spawn if the guard is somehow armed.
        from .provider_claude_cli import ClaudeCLIClient
        return ClaudeCLIClient()
    if backend == "openai":
        from .provider_openai import OpenAIClient
        api_key = require_env("OPENAI_API_KEY")
        return OpenAIClient(api_key=api_key, model=cfg.summarization.openai_model)
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
        self.last_used_adapter_path: str = ""
        # LOCAL11: the (model, adapter) the local client reported *serving*, read
        # off it before the `with` block closes it. The configured pair is only a
        # fallback: a warm server we do not own can be serving older weights.
        self._local_identity: tuple[str, str] | None = None

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
                # PIPE4: the auto->local fallback map-reduces a long transcript too.
                map_reduce_above_chars=self._cfg.summarization.skip_above_chars,
                # LOCAL9: opt-in fine-tuned adapter; empty config keeps the base model.
                adapter_path=self._cfg.summarization.local_adapter_path or None,
            ) as fallback:
                out = fallback.summarize(
                    system_prompt=system_prompt, transcript=transcript,
                    model=model, max_tokens=max_tokens,
                )
                # LOCAL11: read the served identity while the client is still
                # open. Reporting the *configured* local model here was the same
                # mis-attribution the local path had, one ladder rung further in.
                self._local_identity = _served_local_identity(fallback, self._cfg)
                return out

        result, backend = run_with_local_fallback(cloud=_cloud, local=_local)
        self.last_used_backend = backend
        if backend == "anthropic":
            self.last_used_model = model
            self.last_used_adapter_path = ""
        else:
            self.last_used_model, self.last_used_adapter_path = self._local_identity or (
                self._cfg.summarization.local_model,
                self._cfg.summarization.local_adapter_path or "",
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
    try:
        argv, backend_override = extract_backend_flag(argv)
    except ValueError as e:
        print(f"error: {e}", file=sys.stderr)
        return 2
    # `--candidate` writes a `<stem>.summary.candidate.json/.md` preview without
    # overwriting the live summary, for the Library's local re-run (TECH-A16).
    candidate = "--candidate" in argv
    positional = [a for a in argv if not a.startswith("--")]
    if not positional:
        print(
            "usage: mp summarize <transcript.md> [--candidate] "
            "[--backend anthropic|local|auto|apple_intelligence|claude_cli|openai]",
            file=sys.stderr,
        )
        return 2
    md = Path(positional[0]).expanduser().resolve()
    if not md.exists():
        print(f"No such file: {md}", file=sys.stderr)
        return 1
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    summarize(md, out_suffix="candidate" if candidate else None, backend=backend_override)
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main(sys.argv[1:]))
