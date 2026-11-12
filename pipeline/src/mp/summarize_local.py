"""Local-LLM summarization via ``mlx_lm.server``.

Implements the ``SummaryClient`` protocol against an OpenAI-compatible
endpoint exposed by Apple's ``mlx_lm.server``. The audio, transcript,
and resulting summary never leave the machine.

Lifecycle
---------
The first ``summarize()`` call lazy-launches an ``mlx_lm.server``
subprocess on the configured host:port, polls the health endpoint
until ready, then forwards the chat completion. Subsequent calls
reuse the running server. After ``idle_timeout_sec`` of inactivity
the server is gracefully shut down to free RAM (default 5 min).

JSON discipline
---------------
Local models do not support Anthropic's ``tool_choice: required``,
so this client uses a free-form prompt that demands a single JSON
object matching ``MeetingSummary``. The 3-layer fallback in
``_extract_summary`` is the contract:

  1. JSON-parse the message body, validate against the Pydantic model.
  2. Strip Markdown code fences and retry parse + validate.
  3. Regex-extract the largest balanced JSON object and validate.

Failures from all three layers raise. The constrained-generation
layer (outlines / lm-format-enforcer) is added in a separate change
(see Roadmap P2.2).

Shapes
------
The default shape is one call per meeting, windowed and reduced when the
request would not fit its token budget or the transcript is over
``map_reduce_above_chars`` (LOCAL23: see ``request_budget``). LOCAL14 adds a second, staged shape in
``summarize_staged``: extract fact rows, compose each section from those rows,
verify deterministically, one critic pass. It is reached only when the
``MP_STAGED_LOCAL`` bake-off toggle is set, and it declines back to this module's
single-pass path on a degenerate transcript. Which one becomes the default is an
owner decision gated on the `mp dogfood` thresholds LOCAL14 pre-registers.

Why a subprocess and not a library import: ``mlx_lm`` keeps the
loaded model in process memory for the life of the interpreter. A
short-lived CLI invocation pays a 10-30 s warm-up per call and a
~8 GB resident footprint for a 14 B 4-bit model (larger for 32 B). Running the server lets us
amortize the load across calls and shut it down on idle.
"""
from __future__ import annotations

import json
import logging
import math
import os
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from typing import Any

import httpx
from pydantic import ValidationError

from . import egress_guard, local_server, resource_guard, summarize_staged
from .chunking import chunked_windows
from .config import SAMPLING_TEMPERATURE
from .json_extract import largest_balanced_json_object, repair_missing_commas
from .prefetch_model import model_is_cached
from .prompt_safety import wrap_untrusted
from .schemas import MeetingSummary, SUMMARY_TOOL
from .summary_language import (
    divergent_sections,
    expected_summary_language,
    language_correction_message,
    language_reinforcement,
)

log = logging.getLogger("mp.summarize_local")

DEFAULT_MODEL = "mlx-community/Qwen2.5-7B-Instruct-4bit"
DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8765
DEFAULT_STARTUP_TIMEOUT_SEC = 120.0
DEFAULT_REQUEST_TIMEOUT_SEC = 120.0
DEFAULT_IDLE_TIMEOUT_SEC = 300.0

# Conservative floor on local generation speed (seconds per output token).
# Real M-series 4-bit throughput is 10-80 tok/s; 0.1 s/token (10 tok/s) is a
# safe floor even for a 32B model on modest hardware, so the scaled read
# timeout never fires before a legitimate generation completes (LOCAL2/AUD-21).
_SECONDS_PER_OUTPUT_TOKEN_FLOOR = 0.1

# Map-reduce for long transcripts on the local backend (PIPE4), generalizing
# AppleIntelligenceSummarizer's LOCAL3 batched reduce out of Swift: summarize()
# windows the transcript, summarizes each window, then reduces the partials in
# batches. Since LOCAL23 it routes on estimated tokens (`request_budget`), and this
# char threshold is only an upper bound on one request: a transcript over it is
# always windowed, and no window is longer than it. It is
# `summarization.skip_above_chars` in production (the cloud paste-bundle knob); the
# default here matches its default. 0 removes the char bound, not the token one.
DEFAULT_MAP_REDUCE_ABOVE_CHARS = 80_000
# Qwen2.5's native context window: `max_position_embeddings` in every curated
# preset's config.json (read off the cached 3B on 2026-10-25). Used for a Custom
# model id too, since nothing here reads an arbitrary model's config and every
# model this product has shipped is Qwen2.5. A request's input budget is this
# minus the `max_tokens` it asks to generate (LOCAL23).
NATIVE_CONTEXT_TOKENS = 32_768
# Floor on a map window, in chars. Window size is derived from the token budget
# left after the fixed prompt (LOCAL23); this floor keeps a window carrying real
# transcript even when that budget is nearly gone, and is also the smallest window
# a tight tier's ceiling must leave room for before `request_budget` honours it.
# Overlap keeps a sentence spanning a window boundary in at least one window
# (chunking.py snaps to whitespace).
_MIN_MAP_WINDOW_CHARS = 1_500
_MAP_OVERLAP_CHARS = 200
# Most partial summaries merged per reduce call. Within that cap a batch also stops
# growing at the token budget. Bounded below at 2 so the reduce always makes
# progress toward one summary.
_REDUCE_BATCH = 4
# Candidate layers `_extract_summary` walks: raw, de-fenced, balanced scan, and the
# lenient comma repair. Named so the error message and the docstring cannot drift
# from the list (the message read "3 layers" for the whole life of layer 4's absence).
_EXTRACT_LAYERS = 4


def scaled_request_timeout(base_sec: float, max_tokens: int) -> float:
    """Per-request read timeout: a fixed ``base_sec`` budget (connect + prefill
    + slack) plus generation time for ``max_tokens`` at a conservative speed
    floor. Scales with the requested output length so a long summary is not cut
    off mid-stream, while the daemon's 20-min watchdog remains the hard backstop
    (LOCAL2/AUD-21). Pure so it is unit-testable without a server."""
    return base_sec + max(0, max_tokens) * _SECONDS_PER_OUTPUT_TOKEN_FLOOR


def request_tokens(messages: list[dict[str, str]]) -> int:
    """Estimated input tokens of one chat request: each message at its own script's
    rate (`resource_guard.estimate_tokens`). The quantity AI2's ceiling and `mp
    ask`'s clamp both measure, so it is what every LOCAL23 budget is compared to."""
    return sum(resource_guard.estimate_tokens(m["content"]) for m in messages)


def request_budget(
    model_id: str,
    ram_gb: float | None,
    *,
    max_tokens: int,
    fixed_tokens: int,
    tokens_per_char: float,
    guard_enabled: bool = True,
) -> tuple[int | None, str | None]:
    """The input-token budget for one local request, and a warning when a tier
    ceiling could not be honoured (LOCAL23). Pure, so the policy is testable
    without a machine.

    The budget is the native context minus ``max_tokens``. A model that sits
    ``tight`` in this Mac's tier (``resource_guard.assess``: the 7B on 16 GB, the
    14B on 24 to 32 GB, the population that produced the OOM reports) is held to
    the tier's ``context_token_ceiling`` instead, but only when that ceiling still
    leaves room for one ``_MIN_MAP_WINDOW_CHARS`` window above ``fixed_tokens``
    (the system prompt, schema, and user wrapper). Where it does not, as on the
    4,000-token tiers whose ceiling the fixed prompt alone reaches, map calls
    would exceed it as well, so the native budget stands and the second value
    names the gap for the caller to log.

    ``ram_gb`` None (unreadable) returns no budget at all, and the caller keeps
    the char-only routing that predates this.

    ``guard_enabled`` False (``MP_RAM_GUARD=0``, the owner's bench override,
    decided 2026-11-12) drops the per-Mac ceiling and leaves only the model's
    own context budget, the same way that switch drops the size refusal and the
    watchdog.
    """
    if ram_gb is None:
        return None, None
    native = NATIVE_CONTEXT_TOKENS - max(0, max_tokens)
    if not guard_enabled:
        return native, None
    assessment = resource_guard.assess(model_id, ram_gb)
    ceiling = assessment.tier.context_token_ceiling
    if assessment.fit != "tight" or ceiling >= native:
        return native, None
    smallest = fixed_tokens + math.ceil(_MIN_MAP_WINDOW_CHARS * tokens_per_char)
    if smallest <= ceiling:
        return ceiling, None
    return native, (
        f"{model_id} is a tight fit for this {ram_gb:g} GB Mac, whose tier keeps one "
        f"request under {ceiling:,} tokens, but the fixed prompt is about "
        f"{fixed_tokens:,} tokens before any transcript (about {smallest:,} with the "
        f"smallest window), so no window can honour that ceiling; using the model's "
        f"native budget of {native:,} tokens and relying on the memory watchdog"
    )


@dataclass(frozen=True)
class MapPartials:
    """The map stage of the last transcript a client windowed (LOCAL23).

    Kept so a LANG1 language repair, which re-asks the same client with the same
    transcript and an extended system prompt, re-runs only the reduce rather than
    every map call again. Reused only when the transcript and target match and
    the new system prompt extends ``system_prompt``; the extension is what the
    repair's reduce adds to its own instructions.
    """
    transcript: str
    target: str | None
    system_prompt: str
    partials: tuple[MeetingSummary, ...]


def _batched(items: list[MeetingSummary], size: int) -> list[list[MeetingSummary]]:
    """Partition ``items`` into groups of ``size`` (floored at 2 so a reduce always
    shrinks the list). Mirrors ``AppleIntelligenceSummarizer.batched`` (PIPE4)."""
    step = max(2, size)
    return [items[i:i + step] for i in range(0, len(items), step)]


def _render_for_reduce(summary: MeetingSummary) -> str:
    """Serialize a partial summary as compact JSON for the next reduce round's input
    (mirrors ``AppleIntelligenceSummarizer.renderForReduce``)."""
    return summary.model_dump_json()


def _reduce_instructions() -> str:
    """System prompt for a reduce call: merge partial summaries of DIFFERENT parts of
    one meeting into a single whole-meeting summary (mirrors the Swift reduce prompt)."""
    return (
        "You merge several partial summaries of DIFFERENT parts of ONE meeting into a "
        "single summary of the whole meeting. Deduplicate bullets, decisions, action "
        "items, questions, and attendees; when the same action appears more than once "
        "keep the one with the clearest owner. Do not invent anything not present in "
        "the partials. Produce at most 5 summary bullets."
    )


# Loopback hosts the local model server may bind / be reached on.
# meeting-pipe always runs that server on the same machine; a
# non-loopback host (a stray "0.0.0.0" in config) would bind the
# unauthenticated inference server to every interface and expose every
# transcript on the LAN, so it is clamped back to loopback.
_LOOPBACK_HOSTS = frozenset({"127.0.0.1", "localhost", "::1"})


def _loopback_only(host: str) -> str:
    if host.strip().lower() in _LOOPBACK_HOSTS:
        return host
    log.warning(
        "local backend host %r is not loopback; clamping to %s so the "
        "inference server is not exposed beyond this machine",
        host, DEFAULT_HOST,
    )
    return DEFAULT_HOST


def augment_with_schema(system_prompt: str) -> str:
    """Append the ``MeetingSummary`` JSON schema and a strict-output
    directive to the existing system prompt. The local model has no
    tool-use forcing, so we lean on prompt discipline to keep the
    output parseable. Layer 1 of the 3-layer fallback in
    ``_extract_summary``.

    The reinforcement block restates the failure modes the local
    model exhibited in dogfood (decision-vs-intent confusion, owner
    propagation, empty questions) right before the schema, where
    token attention is highest. Belt-and-suspenders with the master
    prompt's worked examples.

    Module-level (not a `LocalSummaryClient` method) because `mp train-adapter`
    has to build the identical system turn to train on, and a LoRA tuned on a
    prompt shape the server never sends is a LoRA tuned for nothing (LOCAL9).
    """
    schema = json.dumps(SUMMARY_TOOL["input_schema"], indent=2)
    reinforcement = (
        "\n\n---\n\n## Before you reply, double-check these rules:\n"
        "1. `decisions` must contain ONLY statements with explicit"
        " commitment language (will/agreed/decided/approved). Plans to"
        " analyze, intentions to study, or ideas being floated are NOT"
        " decisions. If unsure, leave the array empty.\n"
        "2. `owner` for each action must be a person literally named in"
        " the transcript for THAT task. Do not assign every action to one"
        " person. Use null when the transcript does not name an owner.\n"
        "3. `questions` should not be empty unless the meeting truly"
        " closed every loop. Look for unresolved clarifications,"
        " expressed uncertainty, or deferred decisions.\n"
        "4. Tools (Claude, Notion, Anthropic) are never owners.\n\n"
    )
    directive = (
        "Your reply MUST be a single JSON object that validates"
        " against this JSON Schema. Output the JSON object and nothing else:"
        " no prose, no Markdown fences, no commentary.\n\n"
        f"```json-schema\n{schema}\n```"
    )
    return system_prompt + reinforcement + directive


def compose_user_message(transcript: str) -> str:
    """The user turn the local client sends. Shared with `mp train-adapter` for the
    same reason `augment_with_schema` is."""
    # Fence the transcript as untrusted content (TECH-SEC6); the system
    # prompt (via _load_system_prompt) explains the markers.
    return (
        "Summarize this meeting. Reply with ONLY the JSON object described "
        "in the system message.\n\n" + wrap_untrusted(transcript)
    )


def repair_messages(prior_text: str, error_detail: str) -> list[dict[str, str]]:
    """A FRESH two-turn conversation asking the model to repair its own reply.

    Deliberately not the failed conversation with the bad reply and a correction
    appended, which is the obvious shape and does not work here: mlx-lm 0.31.3
    reuses the cached prompt prefix, so the replay came back byte-identical on
    every one of six measured runs, burning a ~40s generation to change nothing.
    A conversation that shares no prefix with the failed one generates afresh and
    repairs the JSON (measured 2026-07-27, the run that lost a meeting).

    Module-level for the same reason as `augment_with_schema`: the exact turns
    the server sees are worth being able to build and inspect from outside the
    client. `error_detail` carries the real parser or validator complaint, which
    is what makes the ask actionable rather than "it did not work".
    """
    schema = json.dumps(SUMMARY_TOOL["input_schema"], indent=2)
    system = (
        "You repair a malformed JSON object so that it parses and validates"
        " against the schema below. Preserve the content you are given and change"
        " only what it takes to make it valid: do not re-summarize, do not"
        " editorialize, do not drop sections. Reply with ONLY the corrected JSON"
        " object: no prose, no Markdown fences, no commentary.\n\n"
        f"```json-schema\n{schema}\n```"
    )
    # The reply is transcript-derived, so it stays inside the untrusted fence
    # (TECH-SEC6) exactly like the transcript that produced it.
    user = (
        "This was meant to be a single JSON object matching the schema, but it"
        f" could not be read:\n\n{error_detail}\n\nHere is the text to repair."
        " Return the corrected object and nothing else.\n\n"
        + wrap_untrusted(prior_text)
    )
    return [{"role": "system", "content": system}, {"role": "user", "content": user}]


# LOCAL22: how many finished requests' KV caches `mlx_lm.server` keeps. Its
# default is 10 with no byte cap, and every completion inserts a full prompt-plus-
# generation copy, so one map-reduce held 3 to 5 GB on the 7B (10 to 18 GB on the
# 14B) beyond the weights, for the daemon's lifetime on the warm server. One entry
# is what lets each map window reuse the shared system-prompt prefix of the call
# before it; the second absorbs an overlapping lane (an `mp ask` against the same
# warm server, or a schema retry). Not `--prompt-cache-bytes`: mlx-lm 0.31.3
# enforces that only on its batch path, so the count is the bound that holds on
# every path. Not 0 either: every window would re-prefill the ~16K-char prompt.
SERVER_PROMPT_CACHE_SIZE = 2


def build_server_command(
    model: str, host: str, port: int, adapter_path: str | None = None
) -> list[str]:
    """Argv for an ``mlx_lm.server`` bound to (host, port) serving ``model``.

    Shared by ``LocalSummaryClient`` (its lazy per-call spawn) and ``mp
    serve-local`` (the daemon's optional launch-time warm process), so both
    start the identical server and the warm one is reused by the health check.
    Prefers the standalone entry point; falls back to ``python -m`` so the user
    does not have to manage which interpreter has mlx-lm installed.

    ``adapter_path`` (LOCAL9), when set, serves a locally-trained LoRA adapter on
    top of the base model; empty/None serves the base model unchanged.

    ``--prompt-cache-size`` (LOCAL22) bounds the server's retained KV caches; see
    ``SERVER_PROMPT_CACHE_SIZE``.
    """
    if shutil.which("mlx_lm.server") is not None:
        cmd = ["mlx_lm.server"]
    else:
        cmd = [sys.executable, "-m", "mlx_lm.server"]
    cmd = cmd + ["--prompt-cache-size", str(SERVER_PROMPT_CACHE_SIZE)]
    cmd = cmd + ["--model", model, "--host", host, "--port", str(port)]
    if adapter_path:
        cmd += ["--adapter-path", adapter_path]
    return cmd


# Language honoring (LOCAL7) lives in `summary_language` now (LANG1 promoted it so
# the Anthropic path shares the same detector). Local MLX models ignore the
# summary-language directive that Anthropic obeys, so this client still reinforces
# the target before the transcript and replays once when the produced summary's
# language disagrees; both moves use the shared, per-section helpers imported above.


class LocalSummaryError(RuntimeError):
    """Raised when the local backend cannot satisfy the request."""


class LocalSummaryClient:
    """``SummaryClient`` backed by an ``mlx_lm.server`` subprocess.

    One instance owns at most one server. Threading: the public
    ``summarize`` method holds a lock so concurrent callers do not
    race the spawn / shutdown logic. The shutdown timer fires from a
    background thread and acquires the same lock before terminating
    the subprocess.
    """

    backend_id = "local"

    def __init__(
        self,
        *,
        model: str = DEFAULT_MODEL,
        host: str = DEFAULT_HOST,
        port: int = DEFAULT_PORT,
        startup_timeout_sec: float = DEFAULT_STARTUP_TIMEOUT_SEC,
        request_timeout_sec: float = DEFAULT_REQUEST_TIMEOUT_SEC,
        idle_timeout_sec: float = DEFAULT_IDLE_TIMEOUT_SEC,
        summary_language: str = "auto",
        manage_subprocess: bool = True,
        map_reduce_above_chars: int = DEFAULT_MAP_REDUCE_ABOVE_CHARS,
        adapter_path: str | None = None,
        memory_floor_pct: float = resource_guard.DEFAULT_FLOOR_PCT,
    ) -> None:
        self._model = model
        self._host = _loopback_only(host)
        self._port = port
        self._startup_timeout_sec = startup_timeout_sec
        self._request_timeout_sec = request_timeout_sec
        self._idle_timeout_sec = idle_timeout_sec
        # LOCAL7: the target output language, so summarize() can reinforce it and
        # retry when the local model drifts. "auto" defers to the transcript.
        self._summary_language = summary_language
        # PIPE4: a transcript longer than this routes through a hierarchical
        # map-reduce instead of a single (context-overflowing) call. 0 disables it.
        self._map_reduce_above_chars = map_reduce_above_chars
        # Test seam: when False we assume the caller has a server
        # already running on (host, port) and never spawn one.
        self._manage_subprocess = manage_subprocess
        # LOCAL9: optional LoRA adapter path served on top of the base model.
        self._adapter_path = adapter_path
        # LOCAL16: sampled before every request, so a run that would push this Mac
        # into swapping ends with a named error instead of a beachball. Public so a
        # caller driving its own loop (a bench harness) can share the one instance.
        self.watchdog = resource_guard.MemoryWatchdog(floor_pct=memory_floor_pct)
        # LOCAL23: the map partials of the last transcript this client windowed,
        # so a language repair re-runs only the reduce. Public because the `auto`
        # ladder builds a fresh client per call and carries this across them.
        self.map_partials: MapPartials | None = None
        # LOCAL23: the tier-ceiling gap is logged once per client, not per call.
        self._ceiling_gap_logged = False

        self._proc: subprocess.Popen[bytes] | None = None
        self._lock = threading.Lock()
        self._idle_timer: threading.Timer | None = None
        # LOCAL11: what the server on this port actually turned out to be serving,
        # read back in `_ensure_running`. None until a request has been made (or
        # when the identity could not be read), which is why `model` and
        # `adapter_path` below fall back to the configured values.
        self._served: local_server.ServedIdentity | None = None
        # Base client timeout; the chat-completion POST overrides the read leg
        # per call, scaled to max_tokens (LOCAL2). Health checks override to 2s.
        self._http = httpx.Client(timeout=httpx.Timeout(request_timeout_sec, connect=5.0))

    @property
    def model(self) -> str:
        """Repo id of the MLX model that actually answered.

        Read by ``mp.summarize.summarize`` (PIPE19) so the run sidecar records the
        model that produced a summary, even when Preferences swaps the configured
        model later. LOCAL11: when the identity check found a warm server we do
        not own serving something else, this reports what *served*, not what was
        configured, so the sidecar never mis-attributes a summary. Falls back to
        the configured id before the first call and whenever identity could not be
        read.
        """
        return (self._served.model if self._served else None) or self._model

    @property
    def adapter_path(self) -> str:
        """LoRA adapter that served this run's requests, or "" for the base model
        (LOCAL9/LOCAL11/LOCAL15).

        Not the served-over-configured rule ``model`` uses, and the asymmetry is the
        point: since LOCAL15 the adapter travels in the request body, which decides
        what gets loaded no matter what the server was started with. So our own
        configured value *is* what served, in both directions. A warm server started
        with an adapter still answers our adapter-free requests from the base model,
        because mlx-lm drops its own `--adapter-path` (upstream #1248).
        """
        return self._adapter_path or ""

    # ----- Public API (SummaryClient) -----

    def summarize(
        self,
        *,
        system_prompt: str,
        transcript: str,
        model: str,  # ignored; the local server pins one model per process
        max_tokens: int,
    ) -> MeetingSummary:
        """Schema-forcing summarize with two follow-on repair loops.

        First the schema-violation retry: attempt 1 sends the schema-augmented
        system prompt and (when the backend honors it) the OpenAI
        ``response_format: json_schema`` hint; attempt 2, fired only on a schema
        violation, replays with the Pydantic error in context so the model can
        repair its own output. Then the language-mismatch retry (LOCAL7): local
        MLX models ignore the summary-language directive, so when the produced
        summary's language disagrees with the expected one we reinforce the
        target and replay once. Each attempt's body still passes through the
        3-layer extraction fallback in ``_extract_summary``.

        LOCAL14's staged pipeline sits in front of all of that, and only when its
        bake-off toggle is set. It is checked before the map-reduce routing
        because extraction *is* the map there, so a long transcript composes from
        fact rows rather than from summaries of summaries. When it declines, the
        routing below runs exactly as it always has.
        """
        with self._lock:
            self._ensure_running()
            self._reset_idle_timer()

            target = expected_summary_language(self._summary_language, transcript)
            if summarize_staged.staged_enabled():
                staged = summarize_staged.run_staged(
                    chat=self._chat_completion,
                    transcript=transcript,
                    target=target,
                    max_tokens=max_tokens,
                    keep_warm=self._reset_idle_timer,
                )
                if staged is not None:
                    return staged
            budget = self._request_budget(system_prompt, transcript, target, max_tokens)
            over_chars = bool(self._map_reduce_above_chars) and (
                len(transcript) > self._map_reduce_above_chars
            )
            over_budget = budget is not None and request_tokens(
                self._messages_for(system_prompt, transcript, target)
            ) > budget
            if over_chars or over_budget:
                # PIPE4 / LOCAL23: too long for one request; window -> map -> reduce.
                return self._summarize_map_reduce(
                    system_prompt=system_prompt, transcript=transcript,
                    target=target, max_tokens=max_tokens, budget=budget,
                )
            summary, last_text, messages = self._summarize_once(
                system_prompt, transcript, target, max_tokens
            )
            if target:
                summary = self._retry_on_language_mismatch(
                    summary, last_text, messages, target, max_tokens
                )
            return summary

    def _summarize_once(
        self, system_prompt: str, text: str, target: str | None, max_tokens: int,
    ) -> tuple[MeetingSummary, str, list[dict[str, str]]]:
        """Build the schema-forcing messages for `text` and run the one
        schema-violation repair loop. Shared by the single-pass path and each
        map window; the caller applies the language-mismatch retry. Returns the
        summary, the raw text it parsed from, and the messages (for that retry)."""
        messages = self._messages_for(system_prompt, text, target)
        summary, last_text = self._summarize_with_schema_retry(messages, max_tokens)
        return summary, last_text, messages

    def _messages_for(
        self, system_prompt: str, text: str, target: str | None,
    ) -> list[dict[str, str]]:
        """The schema-forcing request for ``text``: what a single-pass call or one
        map window sends, and what LOCAL23's budget estimates before sending it."""
        system_content = self._augment_with_schema(system_prompt)
        if target:
            # Restate the target after the schema, where the local model's token
            # attention is highest; the base directive already rode in via the
            # system prompt but was being ignored (LOCAL7).
            system_content += language_reinforcement(target)
        return [
            {"role": "system", "content": system_content},
            {"role": "user", "content": self._compose_user_message(text)},
        ]

    def _request_budget(
        self, system_prompt: str, transcript: str, target: str | None, max_tokens: int,
    ) -> int | None:
        """This run's input-token budget per request (``request_budget``), against
        the model that is actually serving and this Mac's RAM. Logs the tier-ceiling
        gap once per client. None when RAM cannot be read."""
        budget, gap = request_budget(
            self.model,
            resource_guard.physical_ram_gb(),
            max_tokens=max_tokens,
            fixed_tokens=request_tokens(self._messages_for(system_prompt, "", target)),
            tokens_per_char=resource_guard.tokens_per_char(transcript),
            guard_enabled=resource_guard.guard_enabled(),
        )
        if gap and not self._ceiling_gap_logged:
            log.warning("local summarize: %s", gap)
            self._ceiling_gap_logged = True
        return budget

    def _map_windows(
        self, system_prompt: str, transcript: str, target: str | None, budget: int,
    ) -> list[str]:
        """Window ``transcript`` so each map request fits ``budget`` (LOCAL23).

        The first size is the budget left after the fixed prompt, converted at the
        transcript's script rate, capped at the char bound and floored at
        ``_MIN_MAP_WINDOW_CHARS``. A mixed en/uk meeting can hold a window whose
        local script costs more than the average, so every window's real request is
        then estimated and the size shrunk until the worst one fits (or the floor
        is reached)."""
        fixed = request_tokens(self._messages_for(system_prompt, "", target))
        rate = resource_guard.tokens_per_char(transcript)
        max_chars = int(max(0, budget - fixed) / rate)
        if self._map_reduce_above_chars:
            max_chars = min(max_chars, self._map_reduce_above_chars)
        max_chars = max(_MIN_MAP_WINDOW_CHARS, max_chars)
        while True:
            windows = [w.text for w in chunked_windows(
                transcript, max_chars=max_chars, overlap_chars=_MAP_OVERLAP_CHARS,
            )]
            worst = max(
                (request_tokens(self._messages_for(system_prompt, w, target)) for w in windows),
                default=0,
            )
            if worst <= budget or max_chars <= _MIN_MAP_WINDOW_CHARS:
                return windows
            max_chars = max(_MIN_MAP_WINDOW_CHARS, int(max_chars * budget / worst) - 1)

    def _summarize_map_reduce(
        self,
        *,
        system_prompt: str,
        transcript: str,
        target: str | None,
        max_tokens: int,
        budget: int | None,
    ) -> MeetingSummary:
        """Hierarchical map-reduce for a transcript too long for one call (PIPE4),
        generalizing ``AppleIntelligenceSummarizer.generate`` (LOCAL3). Windows the
        transcript to the token budget (LOCAL23), summarizes each window, then
        reduces the partials in batches until one remains. Called with the lock
        held and the server running (from ``summarize``); the final summary still
        passes through the language-mismatch repair, so a drifted merge is caught.

        A repeat call on the transcript this client last windowed, with a system
        prompt that extends the one it was mapped under (LANG1's repair), reuses
        those partials and runs only the reduce, with the extension added to the
        reduce's own instructions so the repair's merge is not a byte-identical
        replay of the one it is repairing.

        Unreadable RAM (``budget`` None) keeps the char-only routing but still
        windows at the native budget rather than at the old 1,500 chars."""
        cached = self.map_partials
        if (
            cached is not None
            and cached.transcript == transcript
            and cached.target == target
            and system_prompt.startswith(cached.system_prompt)
        ):
            log.info(
                "map-reduce: reusing %d map partials, re-running only the reduce",
                len(cached.partials),
            )
            return self._reduce_partials(
                list(cached.partials), target, max_tokens, budget,
                extra_instructions=system_prompt[len(cached.system_prompt):],
            )
        size_budget = budget if budget is not None else NATIVE_CONTEXT_TOKENS - max(0, max_tokens)
        windows = self._map_windows(system_prompt, transcript, target, size_budget)
        log.info("map-reduce: %d chars -> %d windows", len(transcript), len(windows))
        if len(windows) <= 1:
            summary, last_text, messages = self._summarize_once(
                system_prompt, windows[0] if windows else transcript, target, max_tokens
            )
            if target:
                summary = self._retry_on_language_mismatch(
                    summary, last_text, messages, target, max_tokens
                )
            return summary
        partials = [self._map_window(system_prompt, w, target, max_tokens) for w in windows]
        self.map_partials = MapPartials(transcript, target, system_prompt, tuple(partials))
        return self._reduce_partials(partials, target, max_tokens, budget)

    def _map_window(
        self, system_prompt: str, text: str, target: str | None, max_tokens: int,
    ) -> MeetingSummary:
        """One map call: summarize a single window into a partial summary, reusing the
        schema-retry + language-repair loops so a partial is well-formed on its own."""
        self._reset_idle_timer()  # keep the server warm across a long map-reduce
        summary, last_text, messages = self._summarize_once(system_prompt, text, target, max_tokens)
        if target:
            summary = self._retry_on_language_mismatch(summary, last_text, messages, target, max_tokens)
        return summary

    def _reduce_partials(
        self,
        partials: list[MeetingSummary],
        target: str | None,
        max_tokens: int,
        budget: int | None,
        extra_instructions: str = "",
    ) -> MeetingSummary:
        """Merge partials in batches until one remains, so every reduce call's input
        also stays under the budget (``_reduce_batches``)."""
        while len(partials) > 1:
            nxt: list[MeetingSummary] = []
            for group in self._reduce_batches(partials, target, budget, extra_instructions):
                nxt.append(group[0] if len(group) == 1 else self._reduce_group(
                    group, target, max_tokens, extra_instructions,
                ))
            partials = nxt
        return partials[0]

    def _reduce_batches(
        self,
        partials: list[MeetingSummary],
        target: str | None,
        budget: int | None,
        extra_instructions: str,
    ) -> list[list[MeetingSummary]]:
        """Group partials for one reduce round: at most ``_REDUCE_BATCH`` each, and a
        group stops growing once the next partial would take its request over
        ``budget`` (LOCAL23). Never fewer than two in a group bar the last, so a
        round always shrinks the list even when two partials alone exceed it."""
        if budget is None:
            return _batched(partials, _REDUCE_BATCH)
        groups: list[list[MeetingSummary]] = []
        current: list[MeetingSummary] = []
        for partial in partials:
            if current and (
                len(current) >= _REDUCE_BATCH
                or (len(current) >= 2 and request_tokens(self._reduce_messages(
                    [*current, partial], target, extra_instructions,
                )) > budget)
            ):
                groups.append(current)
                current = []
            current.append(partial)
        if current:
            groups.append(current)
        return groups

    def _reduce_messages(
        self, group: list[MeetingSummary], target: str | None, extra_instructions: str,
    ) -> list[dict[str, str]]:
        combined = "\n\n---\n\n".join(_render_for_reduce(p) for p in group)
        system_content = self._augment_with_schema(_reduce_instructions() + extra_instructions)
        if target:
            system_content += language_reinforcement(target)
        return [
            {"role": "system", "content": system_content},
            {"role": "user", "content": (
                "Merge these partial meeting summaries into one summary of the whole "
                "meeting. Reply with ONLY the JSON object described in the system "
                "message.\n\n" + combined
            )},
        ]

    def _reduce_group(
        self,
        group: list[MeetingSummary],
        target: str | None,
        max_tokens: int,
        extra_instructions: str = "",
    ) -> MeetingSummary:
        self._reset_idle_timer()
        messages = self._reduce_messages(group, target, extra_instructions)
        summary, last_text = self._summarize_with_schema_retry(messages, max_tokens)
        if target:
            summary = self._retry_on_language_mismatch(summary, last_text, messages, target, max_tokens)
        return summary

    def _summarize_with_schema_retry(
        self, messages: list[dict[str, str]], max_tokens: int
    ) -> tuple[MeetingSummary, str]:
        """One schema-violation repair loop. Returns the validated summary and
        the raw assistant text it came from; that text seeds the language retry's
        conversation so the model repairs its own prior reply."""
        first_text = self._chat_completion(messages=messages, max_tokens=max_tokens)
        try:
            return self._extract_summary(first_text), first_text
        except LocalSummaryError as e:
            log.warning("attempt 1 failed schema validation; replaying with correction: %s", e)
            second_text = self._chat_completion(
                messages=repair_messages(first_text, str(e)), max_tokens=max_tokens
            )
            return self._extract_summary(second_text), second_text

    def _retry_on_language_mismatch(
        self,
        summary: MeetingSummary,
        prior_text: str,
        base_messages: list[dict[str, str]],
        target: str,
        max_tokens: int,
    ) -> MeetingSummary:
        """LOCAL7: replay once when any section of the summary reads as a language
        other than the target. Keeps the original summary when every section
        already reads as the target (or is too short to tell) or when the retry
        fails to parse, so a wrong guess costs at most one extra call, never the
        summary itself. Per-section (LANG1), so a drifted ``actions`` block is
        caught even when the rest of the summary is already on target."""
        diverging = divergent_sections(summary, target)
        if not diverging:
            return summary
        log.warning(
            "local summary sections %s diverge from expected language %r; "
            "replaying with a language directive",
            diverging, target,
        )
        # KNOWN WEAK, left as-is deliberately: this is the same append-to-the-failed
        # conversation shape that `repair_messages` had to abandon, because mlx-lm
        # 0.31.3 replays the cached prefix and returns the identical reply. That was
        # measured for the schema repair (6/6 byte-identical), NOT for this path, and
        # a language correction genuinely needs the transcript in context, so the
        # rewrite is not the same one-liner. Flagged here rather than guessed at;
        # it wants its own measurement before anyone changes it.
        retry_messages = base_messages + [
            {"role": "assistant", "content": prior_text},
            {"role": "user", "content": language_correction_message(target)},
        ]
        try:
            retried = self._extract_summary(
                self._chat_completion(messages=retry_messages, max_tokens=max_tokens)
            )
        except LocalSummaryError as e:
            log.warning(
                "language-correction retry did not parse (%s); keeping the first summary", e
            )
            return summary
        still = divergent_sections(retried, target)
        log.info(
            "language-correction retry produced a summary; diverging sections now: %s",
            still or "none",
        )
        return retried

    def complete(
        self,
        *,
        system_prompt: str,
        user_message: str,
        max_tokens: int,
        response_format: dict[str, Any] | None,
    ) -> str:
        """Generic single-turn completion against the managed server.

        ``summarize()`` uses the schema-forcing path above; the
        diarization cleanup pass (TECH-DIAR1) reuses this to run its own
        prompt + schema on the same warm server instead of duplicating
        the spawn / health / idle lifecycle. Returns the raw assistant
        message text (the caller does its own JSON extraction).
        """
        with self._lock:
            self._ensure_running()
            self._reset_idle_timer()
            return self._chat_completion(
                messages=[
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": user_message},
                ],
                max_tokens=max_tokens,
                response_format=response_format,
            )

    def close(self) -> None:
        """Shut down the server and stop the idle timer. Idempotent."""
        with self._lock:
            self._cancel_idle_timer()
            self._terminate_proc()
        self._http.close()

    # Context-manager sugar so callers can scope the server lifetime
    # to a single ``with`` block (handy in tests and one-shot CLI runs).
    def __enter__(self) -> "LocalSummaryClient":
        return self

    def __exit__(self, *exc: Any) -> None:
        self.close()

    # ----- Lifecycle -----

    @property
    def base_url(self) -> str:
        return f"http://{self._host}:{self._port}"

    def _ensure_running(self) -> None:
        if self._is_healthy() and self._reuse_is_safe():
            return
        if not self._manage_subprocess:
            raise LocalSummaryError(
                f"No server reachable at {self.base_url} and manage_subprocess=False"
            )
        self._spawn()
        self._wait_for_health(self._startup_timeout_sec)
        self._served = local_server.served_identity(self._port)

    def _reuse_is_safe(self) -> bool:
        """LOCAL11: is the warm server on this port serving what we configured?

        A bare HTTP 200 says a server is up, not *which* server, so a
        `local_model` / `local_adapter_path` change used to keep serving the old
        weights until someone killed the process by hand. Records the served
        identity either way (that is what the run sidecar reports) and returns
        False only when the caller should spawn a replacement.

        Three outcomes on a mismatch:

        - **We spawned it** (this process, or a previous `mp` whose LOCAL10 marker
          still names the pid): kill it and return False so the caller respawns.
        - **We did not** (the daemon's warm `mp serve-local`, or
          `manage_subprocess=False`): killing another owner's process would just
          race its supervisor, so warn, keep the served identity for the sidecar,
          and proceed. The daemon restarts its own preloader on a config save
          (`LocalModelPreloader.refresh`), which is the fix for that case; `mp
          doctor` names it if it persists.
        - **Identity unknown**: reuse, because a `lsof`/`ps` we could not read is
          not evidence of a mismatch and a needless respawn costs a model reload.
        """
        identity = local_server.served_identity(self._port)
        self._served = identity
        # Model only, deliberately: since LOCAL15 the adapter rides in every request,
        # which overrides whatever the server was started with (mlx-lm ignores its own
        # `--adapter-path` entirely), so a warm server started for a different adapter,
        # or for none, still serves ours correctly. Respawning a multi-GB server over
        # an adapter difference would cost a full model load and change nothing.
        if identity is None or identity.matches(
            model=self._model, adapter_path=identity.adapter_path
        ):
            return True

        want = self._model
        if not self._manage_subprocess or not self._owns(identity):
            log.warning(
                "warm mlx_lm.server on %s serves %s but this run is configured for %s; "
                "it is not ours to restart, so the run sidecar will record what served",
                self.base_url, identity.describe(), want,
            )
            return True

        log.warning(
            "mlx_lm.server on %s serves %s but this run is configured for %s; "
            "restarting it",
            self.base_url, identity.describe(), want,
        )
        if self._proc is not None:
            self._terminate_proc()
        else:
            local_server.terminate_server(identity.pid)
        self._served = None
        return False

    def _owns(self, identity: local_server.ServedIdentity) -> bool:
        """May this client kill `identity`'s server? True when we spawned it in
        this process, or when the LOCAL10 marker names that exact pid (an earlier
        `mp` spawned it and is gone). The daemon's warm server writes no marker,
        which is precisely what keeps it off-limits here."""
        if self._proc is not None and self._proc.poll() is None:
            return True
        marker = local_server.read_marker()
        return marker is not None and marker.get("pid") == identity.pid

    def _spawn(self) -> None:
        if shutil.which("mlx_lm.server") is None and shutil.which("python3") is None:
            raise LocalSummaryError(
                "Neither 'mlx_lm.server' nor 'python3' found on PATH. "
                "Install mlx-lm (`pip install mlx-lm`) before using the local backend."
            )
        # SEC13: under a zero-egress run the child gets HF_HUB_OFFLINE=1, so an
        # uncached model would strand its load inside a subprocess whose stdout
        # we throw away, surfacing as an opaque "exited during startup". Fail
        # closed here instead, and say what to do about it. Downloading the
        # model from inside a regulated / NDA run is exactly what the guard
        # exists to prevent, so this is a refusal, not a fallback.
        if egress_guard.is_armed() and not model_is_cached(self._model):
            # UX21: keep the phrase "not in the local HuggingFace cache" here. It
            # is the marker Swift's `Meeting.failureSuggestsModelDownload` matches
            # (this message becomes the failed row's reason), so the Library can
            # offer an in-app "Download model" instead of the terminal command.
            raise LocalSummaryError(
                f"Model {self._model!r} is not in the local HuggingFace cache, and this "
                f"is a regulated/NDA run, so it cannot be downloaded now. Fetch it "
                f"outside a zero-egress meeting first:\n"
                f"    mp prefetch-model {self._model}"
            )
        # LOCAL16: refuse a model this Mac cannot hold, before a multi-GB load
        # starts. Same shape and the same seam as the SEC13 refusal above: the
        # machine is the thing that cannot satisfy the request, so say so and
        # name the preset to pick instead. Fails open when the size or the RAM
        # cannot be read; the watchdog covers what the table cannot see.
        resource_guard.require_model_fits(self._model)
        cmd = build_server_command(self._model, self._host, self._port, self._adapter_path)
        log.info("spawning mlx_lm.server: %s", " ".join(cmd))
        # LOCAL16: the server's own output goes to a rotated log rather than
        # DEVNULL. Discarding it is what made every OOM read as an opaque
        # "exited during startup", and left the postmortem with nothing.
        server_log = local_server.open_server_log()
        proc = subprocess.Popen(
            cmd,
            stdout=server_log or subprocess.DEVNULL,
            stderr=subprocess.STDOUT,
            # SEC13: the guard patches httpx in *this* process; the child speaks
            # its own stack. Hand it an environment with the cloud tokens gone
            # and huggingface_hub pinned offline, so a zero-egress run cannot
            # egress from inside the model server either.
            env=egress_guard.child_env(),
            # Detach into a new process group so a Ctrl-C in the daemon does
            # not also terminate the model server before we get to clean it up.
            # None is Popen's default, so a non-POSIX host just skips it.
            preexec_fn=os.setsid if hasattr(os, "setsid") else None,
        )
        self._proc = proc
        # LOCAL10: that same setsid means a SIGKILL of this process (the daemon's
        # pipeline watchdog does exactly that to a wedged run) leaves the server
        # running with no one who knows about it. Record who it is, so `mp doctor`
        # can report it and the daemon can reap it.
        local_server.write_marker(
            pid=proc.pid, port=self._port, model=self._model,
            adapter_path=self._adapter_path,
        )
        # Popen duplicated the fd into the child, so this handle has done its
        # job. Holding it open would keep a second reference to a log the
        # rotation then renames out from under us.
        if server_log is not None:
            server_log.close()

    def _wait_for_health(self, timeout_sec: float) -> None:
        deadline = time.monotonic() + timeout_sec
        last_err: Exception | None = None
        while time.monotonic() < deadline:
            if self._proc is not None and self._proc.poll() is not None:
                rc = self._proc.returncode
                self._proc = None
                # LOCAL16: quote the server's own last words rather than
                # guessing at them. Before the log capture this message was a
                # two-cause guess ("the model name, or RAM"), which is exactly
                # what a postmortem cannot work with.
                tail = local_server.tail_server_log()
                raise LocalSummaryError(
                    f"mlx_lm.server exited during startup (rc={rc})."
                    + (f" Its last output was:\n{tail}" if tail else
                       " It logged nothing; check that the model name resolves"
                       " and you have enough RAM.")
                )
            if self._is_healthy():
                log.info("mlx_lm.server is ready at %s", self.base_url)
                return
            time.sleep(0.5)
        raise LocalSummaryError(
            f"mlx_lm.server did not become healthy within {timeout_sec:.0f}s"
            + (f": {last_err}" if last_err else "")
        )

    def _is_healthy(self) -> bool:
        try:
            r = self._http.get(f"{self.base_url}/v1/models", timeout=2.0)
            return r.status_code == 200
        except Exception:
            return False

    def _terminate_proc(self) -> None:
        proc = self._proc
        self._proc = None
        # The identity we read belonged to the server we are about to stop; a
        # later call re-reads it rather than reporting the dead one (LOCAL11).
        self._served = None
        if proc is None:
            # A server we health-checked into rather than spawned (the warm
            # `mp serve-local` path). Not ours to kill, and it has no marker.
            return
        # LOCAL10: we own this one, so drop its marker whether or not the kill
        # below finds it already dead. A marker outliving its server would make
        # the next `doctor` run lie.
        local_server.clear_marker()
        if proc.poll() is not None:
            return
        try:
            if hasattr(os, "killpg"):
                os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
            else:
                proc.terminate()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                if hasattr(os, "killpg"):
                    os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
                else:
                    proc.kill()
        except Exception as e:  # pragma: no cover
            log.warning("error terminating mlx_lm.server: %s", e)

    def _reset_idle_timer(self) -> None:
        self._cancel_idle_timer()
        if self._idle_timeout_sec <= 0:
            return
        t = threading.Timer(self._idle_timeout_sec, self._on_idle_timeout)
        t.daemon = True
        t.start()
        self._idle_timer = t

    def _cancel_idle_timer(self) -> None:
        if self._idle_timer is not None:
            self._idle_timer.cancel()
            self._idle_timer = None

    def _on_idle_timeout(self) -> None:
        log.info("mlx_lm.server idle for %.0fs, shutting down", self._idle_timeout_sec)
        with self._lock:
            self._terminate_proc()
            self._idle_timer = None

    # ----- Request shaping -----

    def _augment_with_schema(self, system_prompt: str) -> str:
        return augment_with_schema(system_prompt)

    def _compose_user_message(self, transcript: str) -> str:
        return compose_user_message(transcript)

    def _chat_completion(
        self,
        *,
        messages: list[dict[str, str]],
        max_tokens: int,
        response_format: dict[str, Any] | None = None,
    ) -> str:
        # LOCAL16: the one chokepoint every local request passes through, so a
        # single check here covers the single-pass call, each map window, each
        # reduce batch, and both repair replays. Checked BEFORE the request:
        # the point is to stop while the machine still has room, not to notice
        # afterwards. Throttled internally, so the map loop does not pay for a
        # `vm_stat` per window.
        self.watchdog.check(stage="local summarize")
        if response_format is None:
            # Default to the MeetingSummary schema so the existing
            # summarize() call site (which passes no response_format) is
            # unchanged; the cleanup pass passes its own schema.
            response_format = {
                "type": "json_schema",
                "json_schema": {
                    "name": "meeting_summary",
                    "schema": SUMMARY_TOOL["input_schema"],
                    "strict": True,
                },
            }
        payload: dict[str, Any] = {
            "model": self._model,
            "messages": messages,
            "max_tokens": max_tokens,
            # Low temperature: structured output is the priority, not
            # creative phrasing. The model's default 0.7 was producing
            # extra prose around the JSON object often enough that
            # layer 2 of the fallback was firing on most calls. PIPE12
            # promoted the literal to `config.SAMPLING_TEMPERATURE`, the
            # one value every backend now samples at.
            "temperature": SAMPLING_TEMPERATURE,
            # OpenAI structured-outputs hint. Newer mlx_lm.server builds
            # honor this and constrain decoding via outlines under the
            # hood; older builds ignore it. Either way the request
            # remains valid OpenAI-compatible JSON, and we still defend
            # against malformed output with the 3-layer extractor.
            # Token-level constraint via in-process outlines requires
            # loading the model in-process (not via HTTP), which is a
            # separate refactor; this hint is the practical bridge.
            "response_format": response_format,
        }
        if self._adapter_path:
            # LOCAL15: the per-request route is the only one that actually serves the
            # adapter. mlx-lm 0.31.3 accepts `--adapter-path` on the server and then
            # drops it: `ModelProvider.load` resolves the model alias first and then
            # keys `_adapter_map` by the resolved path, while the map is keyed
            # "default_model", so the lookup always misses and falls back to None.
            # Upstream issue ml-explore/mlx-lm#1248, fix PR #1249 unmerged since
            # 2026-05-06. `adapters` is a documented public field of the server API
            # (mlx_lm/SERVER.md), and `tuner.utils.load_adapters` raises
            # FileNotFoundError on a bad path, so a typo'd `local_adapter_path` now
            # fails loudly instead of silently serving the base model.
            payload["adapters"] = self._adapter_path
        # Scale the read timeout to the requested output length so a long
        # generation is not cut off mid-stream (LOCAL2/AUD-21). Connect stays
        # tight: a server that will not accept the connection should fail fast.
        read_timeout = scaled_request_timeout(self._request_timeout_sec, max_tokens)
        try:
            r = self._http.post(
                f"{self.base_url}/v1/chat/completions",
                json=payload,
                timeout=httpx.Timeout(read_timeout, connect=5.0),
            )
        except httpx.HTTPError as e:
            raise LocalSummaryError(f"local backend HTTP error: {e}") from e
        if r.status_code != 200:
            detail = f"local backend returned {r.status_code}: {r.text[:500]}"
            if r.status_code == 404 and self._adapter_path:
                # mlx_lm.server answers a bare 404, no body, when it cannot load the
                # adapter a request asked for (LOCAL15). The endpoint itself is fixed
                # and known-good by this point, so name the likely cause: otherwise
                # the user sees an unexplained 404 from their own machine.
                detail += (
                    f". The request asked for LoRA adapter {self._adapter_path!r}; the "
                    "server answers 404 when it cannot load one. Check that "
                    "summarization.local_adapter_path exists and holds "
                    "adapter_config.json + adapters.safetensors."
                )
            raise LocalSummaryError(detail)
        data = r.json()
        try:
            return data["choices"][0]["message"]["content"]
        except (KeyError, IndexError, TypeError) as e:
            raise LocalSummaryError(f"unexpected response shape: {data}") from e

    # ----- Output extraction -----

    def _extract_summary(self, text: str) -> MeetingSummary:
        """4-layer fallback. Each layer returns a MeetingSummary or
        raises; only the final layer's failure propagates out.

        The raised error names the layer that got furthest and quotes the real
        parser or validator complaint, because that string is what the repair
        replay hands the model. It used to say only "did not contain a
        schema-valid JSON object", which told the model nothing it could act on.
        """
        best: str = "no JSON object found in the reply"
        for layer, candidate in self._candidates(text):
            try:
                obj = json.loads(candidate)
            except json.JSONDecodeError as je:
                # A syntax error beats "no JSON found" as a diagnosis, but a
                # schema violation (below) beats both: it means we got as far as
                # a parsed object.
                if best.startswith("no JSON"):
                    best = f"layer {layer}: invalid JSON: {je}"
                continue
            try:
                summary = MeetingSummary.model_validate(obj)
            except ValidationError as ve:
                log.warning("layer %d schema violation: %s", layer, ve)
                best = f"layer {layer}: parsed as JSON but failed the schema: {ve}"
                continue
            if layer > 1:
                log.info("recovered MeetingSummary via layer %d fallback", layer)
            return summary
        raise LocalSummaryError(
            f"local model output did not contain a schema-valid JSON object "
            f"after {_EXTRACT_LAYERS} layers ({best})"
        )

    def _candidates(self, text: str) -> list[tuple[int, str]]:
        """Layered candidates. Order is tried in ``_extract_summary``."""
        out: list[tuple[int, str]] = []
        # Layer 1: raw text.
        out.append((1, text.strip()))
        # Layer 2: strip Markdown fences (```json ... ```).
        fenced = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", text, re.DOTALL)
        if fenced is not None:
            out.append((2, fenced.group(1).strip()))
        # Layer 3: longest balanced object scan. Walks the string with a
        # brace counter, tracking string state so braces inside strings
        # do not throw off the depth. Picks the biggest top-level object,
        # which is robust to leading/trailing prose.
        biggest = largest_balanced_json_object(text)
        if biggest is not None:
            out.append((3, biggest))
        # Layer 4: lenient repair of the best-formed candidate so far. Layers 1-3
        # all end in a strict `json.loads`, and layer 3 counts braces only, so a
        # single comma the model forgot between two members defeats all three and
        # loses the meeting (2026-07-27). Runs last: a reply that parses strictly
        # is never rewritten.
        repaired = repair_missing_commas(out[-1][1])
        if repaired is not None:
            out.append((4, repaired))
        return out


# The balanced-object scan moved to `json_extract` (PROV1) so `claude_cli` shares
# it. Kept as a module-level alias because `test_summarize_local` imports this
# name directly; new call sites use `largest_balanced_json_object`.
_largest_balanced_json_object = largest_balanced_json_object


def _redirect_output_to_server_log() -> None:
    """Point this process's stdout and stderr at the model-server log before
    `execvpe` (LOCAL16). Best-effort: a warm server that cannot log is still a
    working warm server, and the daemon nulls both streams today, so the only
    thing at stake is whether the next OOM leaves a message behind."""
    handle = local_server.open_server_log()
    if handle is None:
        return
    try:
        os.dup2(handle.fileno(), 1)
        os.dup2(handle.fileno(), 2)
    except OSError as e:
        log.warning("serve-local: could not redirect output to the server log: %s", e)
    finally:
        handle.close()


def main(argv: list[str]) -> int:
    """``mp serve-local``: start a persistent ``mlx_lm.server`` for the
    configured local model and stay in the foreground so the parent process
    (the daemon, optionally, at launch) owns its lifetime.

    This is the warm path for TECH-A15: starting the server ahead of time lets
    the first ``mp run-all`` / ``mp summarize`` skip the cold-start, because
    ``LocalSummaryClient._ensure_running`` health-checks the endpoint first and
    reuses an already-running server instead of spawning its own. We
    ``execvp`` so this process is *replaced* by the server: the daemon's child
    handle maps straight onto ``mlx_lm.server`` and terminating the child stops
    the server, with no extra supervisor layer to leak it.
    """
    if argv and argv[0] in {"-h", "--help"}:
        print("usage: mp serve-local")
        print("Start mlx_lm.server for the configured local model and block.")
        return 0

    from . import entry
    from .config import parse_local_endpoint

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    # SEC13 entry contract: arm the egress guard before we exec. No meeting anchor
    # (a library-wide warm server), and `secrets=False` because a local model
    # server never touches a cloud token. Under a regulated / NDA run this scrubs
    # the tokens from the environment and pins huggingface_hub offline, so the
    # exec'd child inherits neither, matching the lazy per-call spawn (`_spawn`).
    cfg = entry.prepare(secrets=False)
    host, port = parse_local_endpoint(cfg.summarization.local_endpoint)
    host = _loopback_only(host)
    model = cfg.summarization.local_model
    # SEC13: an armed run cannot download a model, so an uncached one would strand
    # mlx_lm.server's load inside a child whose stdout we discard. Fail closed with
    # the same guidance `_spawn` gives, pointing at the prefetch escape hatch.
    if egress_guard.is_armed() and not model_is_cached(model):
        log.error(
            "serve-local: model %r is not in the local HuggingFace cache, and this "
            "is a regulated/NDA run, so it cannot be downloaded now. Fetch it "
            "outside a zero-egress meeting first:\n    mp prefetch-model %s",
            model, model,
        )
        return 1
    # LOCAL16: the warm path refuses an over-tier model for the same reason the
    # lazy spawn does, and one step earlier in the day: a preloaded server holds
    # the model resident from launch, so getting this wrong costs the machine
    # its headroom before a meeting even starts.
    try:
        resource_guard.require_model_fits(model)
    except resource_guard.ModelTooLargeError as e:
        log.error("serve-local: %s", e)
        return 1
    # LOCAL9: the warm server serves the configured adapter too, so it matches the
    # lazy per-call spawn (LocalSummaryClient) and the daemon reuses one server.
    cmd = build_server_command(model, host, port, cfg.summarization.local_adapter_path or None)
    log.info("serve-local: exec %s", " ".join(cmd))
    # LOCAL16: point the exec'd server's own stdout/stderr at the same rotated
    # log the lazy spawn uses. `execvpe` replaces this process, so the redirect
    # has to happen here, on the fds the child inherits (dup2's result is
    # inheritable, which is what carries it across the exec).
    _redirect_output_to_server_log()
    try:
        # execvpe (not execvp): hand the child a token-stripped, offline-pinned
        # environment under a zero-egress run so it cannot egress even though it
        # speaks its own (non-httpx) stack. child_env() is a no-op copy otherwise.
        os.execvpe(cmd[0], cmd, egress_guard.child_env())
    except OSError as e:
        log.error(
            "serve-local could not exec %s: %s. Install mlx-lm "
            "(`pip install mlx-lm`) for the local backend.",
            cmd[0], e,
        )
        return 1
    return 0  # unreachable after a successful execvpe


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main(sys.argv[1:]))
