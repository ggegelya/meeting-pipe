"""Anthropic-API-driven meeting summarization with structured output.

Uses tool-use to force schema compliance — the model is required to call
`emit_meeting_summary` exactly once, and its arguments validate against
MeetingSummary. One retry on schema violation; otherwise we surface the error.

Prompt caching is enabled on the system prompt so repeated calls within the
5-minute window only pay ~0.1x for the system block. The transcript itself is
the volatile part and goes after the cache breakpoint.

Two retry layers, and one repair:
  - `_create_message`: tenacity-wrapped; retries on rate limits, 5xx, and
    transient connection errors with exponential backoff. Inside it, a
    one-shot retry for a timeout the Mac slept through (PIPE10).
  - `AnthropicSummaryClient.summarize`: one retry on a tool_use response that is
    missing or schema-violating. That retry replays the validator's complaint
    through `summary_request` (PIPE15); it used to re-issue a byte-identical
    request, so the model could not know it had failed and the same malformed
    reply could recur until the run died.
  - `schemas.normalize_model_summary`: the shared repair every backend inherits,
    which is where a section arriving as a JSON-encoded string is decoded (PIPE15)
    and where FEAT10's `{text, evidence}` shape is flattened.

This is deliberately thinner than the local backend's ladder (three recovery
layers plus `summarize_local.repair_messages`), because a tool call is already
schema-constrained at the API. What it must not be is *blind*, which is what it
was: the normalizer is the shared half of the fix, and the replay the cheap half.
"""
from __future__ import annotations

import logging
import os
import sys
import time
from dataclasses import dataclass
from importlib import resources
from pathlib import Path
from typing import TYPE_CHECKING, Any, NotRequired, TypedDict

import anthropic
from pydantic import ValidationError
from tenacity import (
    before_sleep_log,
    retry,
    retry_if_exception,
    stop_after_attempt,
    wait_exponential,
)

from . import (
    corrections,
    entry,
    events,
    evidence,
    providers,
    speaker_overlay,
    storage,
    transcript_corrections,
    usage,
    visibility,
)
from .backend_fallback import run_with_local_fallback
from .config import (
    SAMPLING_TEMPERATURE,
    Config,
    ExtraSectionSpec,
    anthropic_sampling,
    effective_backend,
    extract_backend_flag,
    extract_fallback_flags,
    with_backend_override,
    zero_egress,
)
from .markdown import render_markdown, render_summary_md
from .markers import FLAGGED_INSTRUCTION, flagged_moments_block, markers_path
from .prompt_safety import UNTRUSTED_GUIDANCE, wrap_untrusted
from .schemas import SUMMARY_TOOL, MeetingSummary
from .services import SummaryClient
from .summary_language import (
    divergent_sections,
    expected_summary_language,
    language_reinforcement,
)
from .workflow import read_meta

if TYPE_CHECKING:  # summarize_local is imported lazily at its call sites
    from .summarize_local import MapPartials

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
    # OBS2: present only when an `auto` run dropped to local on a cloud failure, so the run
    # sidecar can say so; absent on a run that did not fall back.
    fallback_from: NotRequired[str]
    fallback_cause: NotRequired[str]
    # PIPE25: the language the refused engine could not take, when the caller knew it.
    fallback_language: NotRequired[str]
    # PIPE27: tokens every metered call in this process spent, absent when none ran.
    usage: NotRequired[dict[str, int]]
    # OBS8: anchors the model proposed that survived verification, and that did not;
    # absent when it proposed none.
    evidence_kept: NotRequired[int]
    evidence_dropped: NotRequired[int]

# Retry only on transient failures. BadRequestError / AuthenticationError /
# PermissionDeniedError / NotFoundError are caller bugs, so failing fast is right.
_RETRYABLE_ANTHROPIC = (
    anthropic.RateLimitError,
    anthropic.APIConnectionError,
    anthropic.APITimeoutError,
    anthropic.InternalServerError,
    # PIPE24: HTTP 529 ("Anthropic is overloaded") is `OverloadedError`, a sibling
    # of InternalServerError rather than a subclass, so it escaped this list and
    # the auto fallback both. The same "transient, cloud unwilling" class.
    anthropic.OverloadedError,
)


def _should_retry_anthropic(exc: BaseException) -> bool:
    """Retry transient failures, but NOT a timeout.

    A timeout means a stalled connection; retrying just re-hangs the run. A
    stall should drop straight to the backend fallback (local) instead. Rate
    limits, 5xx, and connection resets are genuinely transient and worth a
    backed-off retry. (APITimeoutError subclasses APIConnectionError, so the
    explicit exclusion below is load-bearing, not redundant.)

    The one timeout that *is* worth re-issuing, the request the Mac slept
    through, is handled a layer in, inside `_create_message`, so this predicate
    keeps its single rule. That matters most for a workflow pinned to
    `anthropic`, where "drop to the fallback" is not an option that exists.
    """
    if isinstance(exc, anthropic.APITimeoutError):
        return False
    return isinstance(exc, _RETRYABLE_ANTHROPIC)


# How far wall-clock elapsed has to exceed monotonic elapsed before we read a
# timeout as "the Mac slept through the request" rather than "the connection
# stalled". httpx's read timeout rides the monotonic clock, which freezes while
# the machine is asleep, so a slept-through request burns its whole budget
# across dark-wake slivers and fires on lid-open. The two clocks agree to within
# scheduler noise on a machine that stayed awake, so 60 s is far above any
# false-positive margin while still catching the shortest nap that could matter.
_SLEEP_DIVERGENCE_SEC = 60.0

# PIPE24 (2026-11-13 amendment): a workflow pinned to `anthropic` has no local
# fallback, so a timeout there is terminal and cost one meeting its summary (stem
# 20261022-103101, one 124 s stall). Such a client re-issues a timed-out request
# once after this pause. Short, because the stall that timed out is a transient
# network condition and the pause only keeps the re-issue off the same dead
# socket; `auto` keeps dropping to local on the first timeout.
_TIMEOUT_REISSUE_PAUSE_SEC = 3.0


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
def _create_message(
    client: anthropic.Anthropic, *, retry_timeout_once: bool = False, **kwargs: Any
) -> Any:
    """Anthropic call with tenacity retry on rate limits / 5xx / connection errors.

    PIPE10: a timeout is normally terminal here (`_should_retry_anthropic`
    excludes it, so a stall drops to the backend fallback rather than re-hanging
    the run). But a timeout raised because the Mac *slept* mid-request is not a
    stall at all: the request never got its 120 s of awake time, and re-issuing
    it after wake succeeds. The two clocks tell the cases apart, so this retries
    exactly once on the slept-through shape and leaves genuine stalls to fail as
    before. A second timeout fails like any other, whatever the clocks say.

    Deliberately inside the tenacity-wrapped function, not around it: the retry
    predicate and the transient-error backoff classes stay exactly as they were.
    `diarize_cleanup` calls this same seam, so it inherits the fix.

    PIPE24: `retry_timeout_once` is the caller saying "there is no fallback to
    drop to" (a workflow pinned to `anthropic`), so an awake timeout is re-issued
    once after a short pause too. At most one re-issue per call whatever the
    cause: a request already re-issued for a sleep is not re-issued again, and
    the second timeout fails like any other. Off by default, so the cleanup pass
    and the `auto` rung keep failing fast.
    """
    wall_start = time.time()
    mono_start = time.monotonic()
    try:
        response = client.messages.create(**kwargs)
        events.note_progress()  # PIPE53: a finished request is the unit of progress
        usage.record_anthropic(response)  # PIPE27
        return response
    except anthropic.APITimeoutError:
        wall = time.time() - wall_start
        mono = time.monotonic() - mono_start
        if wall - mono >= _SLEEP_DIVERGENCE_SEC:
            log.warning(
                "Anthropic request timed out across a system sleep "
                "(wall %.0fs vs monotonic %.0fs, divergence %.0fs); retrying once",
                wall,
                mono,
                wall - mono,
            )
        elif retry_timeout_once:
            log.warning(
                "Anthropic request timed out and the backend is pinned to anthropic "
                "(no local fallback); re-issuing once after %.0fs",
                _TIMEOUT_REISSUE_PAUSE_SEC,
            )
            time.sleep(_TIMEOUT_REISSUE_PAUSE_SEC)
        else:
            raise

    response = client.messages.create(**kwargs)
    events.note_progress()
    usage.record_anthropic(response)
    return response


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
    local backends receive it identically (it routes to whichever backend
    already summarizes this transcript). The first meeting in a workflow, one
    with no prior decisions/open actions, or one whose language differs from
    this meeting's (LANG1: a foreign-language block would pull the summary into
    the wrong language) is a clean no-op.

    SEC34: the prompt goes to this run's backend and the summary to this run's
    sinks, so a prior that `visibility.withheld_reason` withholds (recorded under
    NDA or regulated mode) is skipped unless this run is itself zero-egress, and
    the scan moves on to the next earlier meeting in the workflow. Gated on
    `zero_egress(cfg)`, never on the backend: a local summary still publishes to
    cloud sinks when the run is not clamped. Both outcomes leave an event (stems
    and counts only).
    """
    meta = read_meta(transcript_md)
    workflow_id = meta.get("workflow_id")
    if not workflow_id:
        return None
    out_dir = cfg.recording.output_dir
    if not out_dir.exists():
        return None

    # PERF25: newest-first, stopping at the first match. Stems sort
    # chronologically, so the first earlier stem in this workflow is the newest
    # one, the same answer the old full scan gave, in usually a read or two
    # instead of one meta sidecar per earlier meeting (an evicted iCloud file
    # blocks on a download).
    current_stem = transcript_md.name.split(".", 1)[0]
    earlier = sorted(
        (
            (stem, summary_json)
            for summary_json in out_dir.glob("*.summary.json")
            # self or a later meeting is never a prior one
            if (stem := summary_json.name.split(".", 1)[0]) < current_stem
        ),
        key=lambda pair: pair[0],
        reverse=True,
    )
    may_use_withheld = zero_egress(cfg)
    prior_stem: str | None = None
    prior_path: Path | None = None
    for stem, summary_json in earlier:
        if read_meta(summary_json).get("workflow_id") != workflow_id:
            continue
        reason = None if may_use_withheld else visibility.withheld_reason(out_dir, stem)
        if reason is not None:
            log.info("SEC34: skipping withheld prior %s (%s) for continuity", stem, reason)
            events.emit("pipeline", "continuity_prior_withheld",
                        stem=current_stem, prior_stem=stem, reason=reason)
            continue
        prior_stem, prior_path = stem, summary_json
        break
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

    workflow_name = meta.get("workflow_name") or "this"
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
    events.emit("pipeline", "continuity_injected", stem=current_stem, prior_stem=prior_stem,
                decisions=len(decisions), actions=len(open_actions))
    return "\n".join(lines)


def summary_request(transcript: str, *, retry_error: Exception | None = None) -> str:
    """The user turn the Anthropic tool call sends (PIPE15).

    On attempt 1 `retry_error` is None and this is the plain ask. On attempt 2 it
    carries the real complaint from attempt 1, which is the whole point: the retry
    used to re-issue a byte-identical request, so the model had no way to know it
    had failed and the same malformed reply could recur. `summarize_local
    .repair_messages` has replayed its parser error for the local backend since
    LOCAL9; the cloud path, which is the shipped default, had nothing.

    Module-level for the same reason `repair_messages` and `augment_with_schema`
    are: the exact turn the API sees is worth being able to build and inspect from
    outside the client.

    Unlike `repair_messages` this is not a fresh conversation that shares no prefix
    with the failed one. That shape exists to defeat mlx-lm's prompt-prefix cache,
    which returned a byte-identical reply on six of six measured runs; the
    Anthropic path caches the *system* block only, by explicit `cache_control`, and
    samples the completion afresh every call, so there is no cache to defeat here.
    Keeping the transcript in the turn is what lets a content-level violation (a
    section over its `max_length`, a missing required field) actually be fixed
    rather than guessed at.

    The error text is model-authored only in the sense that pydantic quotes the
    offending value back, so it stays outside the untrusted fence around the
    transcript and is introduced as a report rather than as instructions.
    """
    ask = (
        "Summarize this meeting. Call `emit_meeting_summary` exactly once.\n\n"
        + wrap_untrusted(transcript)
    )
    if retry_error is None:
        return ask
    return (
        "Your previous call to `emit_meeting_summary` was rejected. The validator"
        f" reported:\n\n{retry_error}\n\nCall the tool again for the same meeting,"
        " correcting exactly that and changing nothing else. Every list field must"
        " be a real JSON array, never an array serialized into a string.\n\n"
        + ask
    )


class AnthropicSummaryClient:
    """Concrete `SummaryClient` backed by Anthropic's tool-use API.

    Holds a single `anthropic.Anthropic` instance for connection reuse and
    encapsulates the tool-use round-trip plus one schema-violation retry.
    Constructed once per `summarize()` call; tests substitute a fake
    implementing the same `SummaryClient` protocol.
    """

    backend_id = "anthropic"

    def __init__(self, *, api_key: str, retry_timeout_once: bool = False) -> None:
        self._client = providers.make_anthropic_client(api_key)
        # PIPE24: set by `providers._anthropic_summary`, the pinned path with no
        # local fallback. `AutoFallbackClient` and `dogfood` keep it off.
        self._retry_timeout_once = retry_timeout_once

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
                retry_timeout_once=self._retry_timeout_once,
                model=model,
                # PIPE12: the same temperature local and openai have always sampled
                # at. Left unset, this call ran at the API default of 1.0, which
                # made the *default* backend the least repeatable one to compare
                # regenerations on. Models that reject a temperature (and a forced
                # tool) get the shape they accept instead; see `anthropic_sampling`.
                **anthropic_sampling(
                    model,
                    max_tokens,
                    temperature=SAMPLING_TEMPERATURE,
                    tool_name="emit_meeting_summary",
                ),
                system=[
                    {
                        "type": "text",
                        "text": system_prompt,
                        "cache_control": {"type": "ephemeral"},
                    },
                ],
                tools=[SUMMARY_TOOL],
                # PIPE15: attempt 2 replays attempt 1's failure instead of
                # re-issuing the identical request it used to.
                messages=[
                    {
                        "role": "user",
                        "content": summary_request(transcript, retry_error=last_err),
                    }
                ],
            )

            tool_blocks = [b for b in response.content if b.type == "tool_use"]
            if not tool_blocks:
                last_err = RuntimeError(f"No tool_use block (stop_reason={response.stop_reason})")
                log.warning("Attempt %d: %s", attempt, last_err)
                continue

            try:
                return MeetingSummary.validate_generated(tool_blocks[0].input)
            except ValidationError as ve:
                last_err = ve
                log.warning("Attempt %d: schema violation: %s", attempt, ve)
                continue

        assert last_err is not None
        raise last_err


class OverlayUnreadable(Exception):
    """A meeting's edit overlay is present but cannot be read (STOR9 item 6)."""


#: The owner's edits a summary is built on: (what the owner calls it, the store
#: name the event carries, where it lives).
_OVERLAYS = (
    ("speaker names", "speaker_labels", speaker_overlay.overlay_path),
    ("transcript corrections", "transcript_corrections", transcript_corrections.corrections_path),
    ("flagged moments", "markers", markers_path),
)


def refuse_unreadable_overlays(transcript_md: Path) -> None:
    """Fail the run rather than summarize without the owner's edits.

    The overlay readers return their empty value for a file they cannot read, so a
    re-summarize used to ship raw diarizer labels and misheard terms the owner had
    already fixed, then publish them. A missing overlay is the normal case (a fresh
    recording has none); only a present one that cannot be read refuses.
    """
    for label, store, path_of in _OVERLAYS:
        path = path_of(transcript_md)
        read = storage.load_json_object(path)
        if read.state != "unreadable":
            continue
        storage.report_unreadable(store, storage.StoreUnreadable(path, read), "refused", path_kind="library")
        raise OverlayUnreadable(
            f"This meeting's {label} file can't be read: {read.reason}. Nothing was summarized; "
            f"fix or remove {path.name} and try again."
        )


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
    storage.sweep_stale_temps(transcript_md.parent, transcript_md.stem)  # PIPE30
    refuse_unreadable_overlays(transcript_md)  # STOR9 item 6

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
    #
    # FEAT10: when the structured transcript is readable, the model reads a
    # timestamped render of it instead, so it can anchor each point to a turn.
    # `<stem>.md` on disk is untouched, and a meeting with only markdown (a BYO
    # paste, or a `<stem>.json` we cannot parse) falls back to exactly the old
    # path and simply produces no evidence.
    rendered = render_model_transcript(transcript_md)
    segments = rendered.segments
    transcript = rendered.text
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

    # FEAT8: the flagged excerpts rode in with the render; the system prompt carries the
    # trusted instruction to reflect them exactly when they did.
    flagged = rendered.flagged

    system_prompt = _load_system_prompt(
        team_context,
        cfg.summarization.summary_language,
        prior_context=_prior_meeting_context(transcript_md, cfg),
        flagged_note=flagged,
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
        # FEAT10: and only then check the anchors, so the pass runs on whichever
        # summary actually won the language repair. Every backend goes through
        # here, including the ones that emit no evidence at all, so "a stored
        # anchor resolves to a real segment" holds without exception.
        summary, verified = _verify_evidence(summary, segments, transcript_md)
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

    # PIPE43: the one gate every engine's answer passes before it is written. A client that
    # validated with `validate_generated` has already been through its repair loop; one that
    # built the model directly (the staged path, an injected client) is held to the floor here.
    if shortfall := summary.content_shortfall():
        raise ValueError("the engine returned an empty summary (" + "; ".join(shortfall)
                         + "); nothing was written")

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
    # AUTO2: the stored `.summary.md` is a Markdown file a human reads outside
    # the app (it is what `mp publish-from-paste` and the fs sinks copy), so its
    # citations link back to the transcript like a published note's do.
    storage.atomic_write_text(md_path, render_summary_md(summary, stem))
    if not infix:
        # PIPE43: a live summary supersedes an earlier run's no-summary marker. Re-summarize is
        # the override for a content-floor skip, and a marker left beside the new summary would
        # still route the done banner to "Too short to summarize" (`DoneRoute`, empty wins).
        try:
            (out_dir / f"{stem}.empty.json").unlink(missing_ok=True)
        except OSError as exc:
            log.warning("stale empty marker could not be removed: %s", exc)

    # PIPE19: every client names itself; the `AutoFallbackClient` reports the rung
    # that answered. A client with no model of its own (Anthropic takes it per
    # call) ran the configured one. An injected fake that names nothing is
    # "unknown" rather than a guess.
    backend_used: str = getattr(client, "backend_id", None) or "unknown"
    model_used = getattr(client, "model", None) or cfg.summarization.model
    log.info("Wrote %s and %s", json_path, md_path)
    result = SummaryOutput(
        json=json_path,
        md=md_path,
        backend=backend_used,
        model=model_used,
        adapter_path=_identify_adapter(client),
    )
    # OBS2: an `auto` run that fell back says what it fell back from and why, so the Library
    # does not render a revoked key as a deliberate local choice.
    fallback_cause = getattr(client, "last_fallback_cause", None)
    if backend_used == "local" and isinstance(fallback_cause, str):
        result["fallback_from"] = "anthropic"
        result["fallback_cause"] = fallback_cause
    spent = usage.snapshot()
    if spent:
        result["usage"] = spent
    if verified.kept or verified.dropped:
        result["evidence_kept"] = verified.kept
        result["evidence_dropped"] = verified.dropped
    return result


@dataclass(frozen=True)
class RenderedTranscript:
    """What the summarizer sends as the transcript (LOCAL27): the text, the segments its
    anchors are verified against, and whether FEAT8's flagged-moments block is in it."""

    text: str
    segments: list[dict]
    flagged: bool


def render_model_transcript(transcript_md: Path) -> RenderedTranscript:
    """The model's view of `<stem>.md`, one function for `summarize` and `mp train-adapter`.

    FEAT3-UNDO / FEAT3-SEGMENT + PIPE9: both reversible overlays apply (speaker names and
    reassignments, then line edits). FEAT10: when the structured transcript is readable,
    the model reads its timestamped render, so it can anchor each point to a turn;
    `<stem>.md` on disk is untouched, and a meeting with only markdown (a BYO paste, or a
    `<stem>.json` we cannot parse) falls back to the overlaid markdown and produces no
    evidence. FEAT8: the user-flagged excerpts are appended in the untrusted zone with the
    rest of it, and `flagged` says so, so the caller adds the trusted instruction exactly
    when they are there. LOCAL27 lifted this out of `summarize` because the adapter
    trainer had its own copy that read `<stem>.md` raw and trained on a transcript the
    server never sends.
    """
    composed = transcript_corrections.overlaid_structured(transcript_md)
    segments: list[dict] = []
    if composed is not None:
        structured, _ = composed
        segments = structured.get("segments") or []
        text = render_markdown(structured, timestamps=True)
    else:
        overlaid = transcript_corrections.overlaid_markdown(transcript_md)
        text = overlaid if overlaid is not None else transcript_md.read_text(encoding="utf-8")
    block = flagged_moments_block(transcript_md)
    if block:
        text = text + "\n\n" + block
    return RenderedTranscript(text=text, segments=segments, flagged=bool(block))


def _verify_evidence(
    summary: MeetingSummary, segments: list[dict], transcript_md: Path
) -> tuple[MeetingSummary, evidence.VerifyResult]:
    """FEAT10: drop every anchor that does not resolve against the transcript.

    Thin wrapper over `evidence.verify` so `summarize` keeps one line and the
    event emission lives next to the decision it reports. Emitted only when the
    summary carried anchors at all, so the ~half of backends that emit none (the
    local map-reduce path, Apple Intelligence) do not fill the log with zeroes.

    OBS8: the row also counts each drop by reason (`dropped_<reason>`, a zero
    reason omitted) and `dropped_quote_elsewhere`, the `quote_not_found` quotes that
    are in the transcript outside their window. Counts only, never quote text.
    """
    result = evidence.verify(summary, segments)
    if result.kept or result.dropped:
        reasons = {f"dropped_{r}": n for r, n in result.dropped_by_reason.items() if n}
        if result.dropped_quote_elsewhere:
            reasons["dropped_quote_elsewhere"] = result.dropped_quote_elsewhere
        events.emit(
            "pipeline",
            "evidence_verified",
            stem=transcript_md.stem,
            kept=result.kept,
            dropped=result.dropped,
            segments=len(segments),
            **reasons,
        )
        log.info(
            "FEAT10: kept %d evidence anchor(s), dropped %d that did not resolve",
            result.kept, result.dropped,
        )
    return result.summary, result


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
        _emit_language_check(target, diverging, "failed")
        return summary
    still = divergent_sections(repaired, target)
    if still:
        log.warning(
            "language repair still diverges (%s); keeping the original summary", still
        )
        _emit_language_check(target, diverging, "still_divergent")
        return summary
    log.info("language repair produced a summary matching %r", target)
    _emit_language_check(target, diverging, "ok")
    return repaired


def _emit_language_check(target: str, diverging: list[str], repair: str) -> None:
    """OBS2: one `pipeline.language_check` per summary whose sections diverged from the expected
    language, carrying the section names and how the repair went (`ok`, `failed`,
    `still_divergent`; the local client's own replay adds `unparsed`). A wrong-language summary
    that shipped used to leave only a WARNING line. Section names only, never their text."""
    events.emit("pipeline", "language_check", target=target, diverging=list(diverging),
                repair=repair)


def _identify_adapter(client: SummaryClient) -> str:
    """LoRA adapter the answering client served, or "" (LOCAL9/LOCAL11).

    Only the local backend has one, and only it can report the *served* value
    rather than the configured one. Duck-typed rather than isinstance-checked so
    both shapes answer with one rule: `AutoFallbackClient` publishes
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
    """Build the summary client for `summarization.backend` (PIPE19: a lookup in
    `providers`, which holds every backend's builders in one table).

    The regulated/NDA force-local rule is applied first, in one place
    (config.effective_backend, TECH-ARCH1). `apple_intelligence` raises from its
    builder: the daemon produces that summary, so reaching it here is a
    misconfiguration, and it fails loudly rather than silently degrading.
    """
    backend = effective_backend(cfg)
    if backend != cfg.summarization.backend:
        log.info("zero-egress mode active; forcing local backend (was %s)",
                 cfg.summarization.backend)
    row = providers.lookup(backend)
    if row.build_summary is None:
        raise ValueError(f"summarization.backend {backend!r} has no Python summarizer")
    return row.build_summary(cfg)


class AutoFallbackClient:
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
        # Set per call so `backend_id` / `model` attribute the run sidecar to
        # whichever path actually answered.
        self.last_used_backend: str | None = None
        self.last_used_model: str | None = None
        self.last_used_adapter_path: str = ""
        # OBS2: the typed cause of the last drop to local, None when the cloud answered or no
        # key was configured (a choice, not a degradation).
        self.last_fallback_cause: str | None = None
        # LOCAL11: the (model, adapter) the local client reported *serving*, read
        # off it before the `with` block closes it. The configured pair is only a
        # fallback: a warm server we do not own can be serving older weights.
        self._local_identity: tuple[str, str] | None = None
        # LOCAL23: the local rung's map partials, carried from one per-call client
        # to the next so a LANG1 repair of a map-reduced summary re-runs only the
        # reduce. A fresh client per call would otherwise always start empty.
        self._local_map_partials: MapPartials | None = None

    @property
    def backend_id(self) -> str:
        return self.last_used_backend or "auto"

    @property
    def model(self) -> str:
        return self.last_used_model or self._cfg.summarization.model

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
            # PIPE32: the same factory as the explicit local backend, so this rung
            # cannot drift from it (LOCAL19 was this rung missing the floor).
            with LocalSummaryClient.from_config(self._cfg) as fallback:
                fallback.map_partials = self._local_map_partials
                out = fallback.summarize(
                    system_prompt=system_prompt, transcript=transcript,
                    model=model, max_tokens=max_tokens,
                )
                self._local_map_partials = fallback.map_partials
                # LOCAL11: read the served identity while the client is still
                # open. Reporting the *configured* local model here was the same
                # mis-attribution the local path had, one ladder rung further in.
                self._local_identity = _served_local_identity(fallback, self._cfg)
                return out

        causes: list[str] = []
        result, backend = run_with_local_fallback(
            cloud=_cloud, local=_local, model=model, operation="summary",
            on_fallback=causes.append,
        )
        self.last_used_backend = backend
        self.last_fallback_cause = causes[-1] if causes else None
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
        argv, substitution = extract_fallback_flags(argv)
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
    entry.configure_logging()
    usage.reset()  # PIPE27: this re-summarize's tokens only
    try:
        out = summarize(md, out_suffix="candidate" if candidate else None, backend=backend_override)
    except Exception as error:
        from .config import MissingSecretError
        from .failure_details import emit_failure, fail_command
        if isinstance(error, MissingSecretError):
            emit_failure(error, operation="summary")
            raise  # The CLI boundary retains PIPE16's exit-2 contract.
        fail_command("summarize", error, operation="summary")
        return 1
    # PIPE25: the daemon re-ran a refused Apple Intelligence meeting here. Recorded only when
    # the run really answered on `local`, so the flag cannot relabel a run it did not describe.
    if substitution and out["backend"] == "local":
        # TYPE2: key by key, so each lands on its declared `NotRequired[str]`; these three
        # are the only keys `extract_fallback_flags` returns.
        for key in ("fallback_from", "fallback_cause", "fallback_language"):
            if key in substitution:
                out[key] = substitution[key]
    if not candidate:
        rewrite_run_sidecar(md, out)
    return 0


def rewrite_run_sidecar(transcript_md: Path, out: SummaryOutput) -> None:
    """PIPE11: keep `<stem>.run.json` truthful after a standalone `mp summarize`.

    Only `orchestrate.run_all` used to write the run sidecar, so a Library
    "Re-summarize with Anthropic" left the previous run's backend/model on disk:
    the detail header badged "On-device (MLX)" over a Sonnet summary, and the
    corrections corpus attributed the summary to an engine that never saw it.
    The answering engine is already in `SummaryOutput`, so this just persists it.

    Two rules. A `--candidate` run never gets here (the caller gates it): a
    preview writes no live summary, so rewriting the sidecar would attribute the
    live one to a run that did not produce it. And `publish_state` is carried
    across rather than reset: it describes where the summary reached, which this
    re-summarize has not changed. Since PIPE14 the Library no longer branches on
    that key (it reads `<stem>.publish.json`, the only file every publish path
    rewrites), so carrying it is about keeping this sidecar internally truthful
    for the pre-PIPE1 meetings that have no publish sidecar, not about a badge.

    Best-effort, matching `orchestrate`: attribution metadata is never worth
    failing a summary that is already safely on disk.
    """
    try:
        sidecar_path = transcript_md.parent / f"{transcript_md.stem}.run.json"
        prior = corrections.read_run_sidecar(sidecar_path) or {}
        publish_state = prior.get("publish_state") if isinstance(prior, dict) else None
        # OBS8: a standalone re-summarize does not re-run speaker cleanup, so the cleanup
        # the transcript still carries is the earlier run's; carry its counts across.
        cleanup = corrections.cleanup_counts(prior) if isinstance(prior, dict) else None
        written = corrections.write_run_sidecar(
            recordings_dir=transcript_md.parent,
            stem=transcript_md.stem,
            transcript_path=transcript_md,
            transcript_chars=len(transcript_md.read_text(encoding="utf-8")),
            summary_json_path=out["json"],
            backend=out["backend"],
            model=out["model"],
            adapter_path=out.get("adapter_path", ""),
            fallback_from=out.get("fallback_from"),
            fallback_cause=out.get("fallback_cause"),
            fallback_language=out.get("fallback_language"),
            usage=out.get("usage"),
            evidence_kept=out.get("evidence_kept"),
            evidence_dropped=out.get("evidence_dropped"),
            cleanup=cleanup,
        )
        if isinstance(publish_state, str):
            corrections.set_publish_state(written, publish_state)
        log.info("Rewrote run sidecar: %s", written)
    except Exception as e:  # noqa: BLE001
        log.warning("run sidecar rewrite failed (non-fatal): %s", e)


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main(sys.argv[1:]))
