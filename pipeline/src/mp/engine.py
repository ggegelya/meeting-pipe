"""Engine-backed free-form text completion honouring `effective_backend()`.

The shared LLM-text spine for `mp ask` (AI3, cited answers) and `mp digest`
(AI4, weekly review). Unlike `summarize.py`'s tool-use path, which forces the
`MeetingSummary` schema, this returns the raw assistant text.

Zero-egress contract:

- `effective_backend(cfg)` applies the regulated / NDA force-local rule, so under
  a zero-egress mode the backend resolves to `local` and there is NO cloud
  fallback (the `auto` path is only reachable when not regulated).
- Both the Anthropic SDK and the local `mlx_lm.server` route through httpx, so
  the process-wide egress guard (armed at the CLI entry via `arm_for_config`)
  clamps either path structurally. This module assumes the caller armed it.

The heavy local backend (`summarize_local`) is imported lazily inside the local
branch, per the pipeline's lazy-import contract; importing this module costs only
the light `anthropic` dep the package already carries.
"""
from __future__ import annotations

import logging
import os
from dataclasses import dataclass

from . import events, providers
from .backend_fallback import run_with_local_fallback
from .config import (
    SAMPLING_TEMPERATURE,
    Config,
    anthropic_sampling,
    effective_backend,
    parse_local_endpoint,
)

log = logging.getLogger("mp.engine")

# Same rationale as summarize: bound a stalled connection instead of the SDK's
# ~10-minute default. ask / digest are latency-tolerant (async / background), so
# a generous read budget with a tight connect is right.
_CONNECT_TIMEOUT = 10.0
_READ_TIMEOUT = 120.0


class EngineError(RuntimeError):
    """The configured engine could not produce a completion (no backend
    reachable, missing credentials, model unavailable). Carries a
    user-actionable message; the CLI surfaces it verbatim."""


@dataclass
class EngineResult:
    text: str
    backend: str
    model: str
    # PIPE12: the backend the user actually configured, when this call could not
    # run on it and something else answered instead. `backend` above is always
    # what ran, so on its own it cannot tell a user who picked Apple Intelligence
    # that a multi-GB local model was spawned for their question. None whenever
    # the configured backend is the one that answered, which is every path but
    # the apple_intelligence substitution below.
    substituted_from: str | None = None


class AnthropicTextClient:
    """Free-form single-turn completion over Anthropic's messages API.

    The tool-use / schema-forcing path lives in `summarize.AnthropicSummaryClient`;
    this returns plain assistant text for ask / digest. `max_retries` is left to
    the SDK (a small internal backoff) since neither caller has summarize's
    timeout-to-local-fallback requirement.
    """

    backend_id = "anthropic"

    def __init__(self, *, api_key: str, model: str) -> None:
        import anthropic
        import httpx

        self.model = model
        self._client = anthropic.Anthropic(
            api_key=api_key,
            timeout=httpx.Timeout(_READ_TIMEOUT, connect=_CONNECT_TIMEOUT),
            max_retries=2,
        )

    def complete(self, *, system_prompt: str, user_message: str, max_tokens: int) -> str:
        response = self._client.messages.create(
            model=self.model,
            # PIPE12: parity with summarize and with the local / openai backends.
            # Unset, this ran at the API default of 1.0, so the same question asked
            # twice of the same library gave two differently-worded answers. Dropped
            # on models that reject it; see `anthropic_sampling`.
            **anthropic_sampling(self.model, max_tokens, temperature=SAMPLING_TEMPERATURE),
            system=[{"type": "text", "text": system_prompt, "cache_control": {"type": "ephemeral"}}],
            messages=[{"role": "user", "content": user_message}],
        )
        # `b.type == "text"` rather than `getattr(b, "type", None)`: every content
        # block carries `.type`, and the direct compare narrows the union down to
        # TextBlock so `.text` is actually known to exist.
        parts = [b.text for b in response.content if b.type == "text"]
        text = "".join(parts).strip()
        if not text:
            raise EngineError(f"Anthropic returned no text (stop_reason={response.stop_reason})")
        return text


def _local_client(cfg: Config, model: str | None):
    """A `LocalSummaryClient` pinned to (host, port) from config. Lazy import so
    non-local installs never pay the mlx cost for an ask that never runs local.

    Deliberately not every setting `summarize._select_backend` passes. Two are
    skipped on purpose, recorded at the keyword arguments below, so a later reader
    can tell a decision from an omission (PIPE12; the adapter was the omission).
    """
    from .summarize_local import LocalSummaryClient

    host, port = parse_local_endpoint(cfg.summarization.local_endpoint)
    return LocalSummaryClient(
        model=model or cfg.summarization.local_model,
        host=host,
        port=port,
        startup_timeout_sec=cfg.summarization.local_startup_timeout_sec,
        request_timeout_sec=cfg.summarization.local_request_timeout_sec,
        # LOCAL16: `mp ask` answers through here, and the 2026-07-29 incident
        # that hard-rebooted this Mac started on exactly this path, so the same
        # floor applies to an answer as to a summary.
        memory_floor_pct=cfg.summarization.local_memory_floor_pct,
        # PIPE12/LOCAL9: the configured LoRA adapter, served per request since
        # LOCAL15. This was dropped, so a trained adapter answered every summary
        # and no ask, digest, or classification, silently and with no way to tell
        # from the answer. An adapter tuned on this owner's meetings is at least as
        # relevant to a question about them as to a summary of one.
        adapter_path=cfg.summarization.local_adapter_path or None,
        # `summary_language` is deliberately NOT passed. It pins the *summary's*
        # output language and drives a re-ask when the local model drifts off it
        # (LOCAL7); a question is not a summary, and an ask answered in the
        # configured summary language rather than the language it was asked in
        # would be a bug, not parity. Free-form callers own their own language
        # instruction in their prompt (`rag.RAG_SYSTEM`, digest's narrate system).
        #
        # `map_reduce_above_chars` is deliberately NOT passed either. It routes an
        # over-long *transcript* through a windowed map-reduce (PIPE4); every
        # free-form caller here packs its own prompt to a budget first (ask to
        # `--context-tokens` clamped by RAM tier, digest to a formatted fact
        # list), so there is nothing left for it to window. The default is what
        # LocalSummaryClient already applies.
    )


class LocalTextClient:
    """`TextClient` over the managed local `mlx_lm.server`, free-form (no schema).

    Owns the server for one call, so the caller closes it. `model` is read off the
    local client after the call, which is the id the server reported serving
    (LOCAL11), not just the configured one.
    """

    backend_id = "local"

    def __init__(self, cfg: Config, model: str | None) -> None:
        self._local = _local_client(cfg, model)

    @property
    def model(self) -> str:
        return self._local.model

    def complete(self, *, system_prompt: str, user_message: str, max_tokens: int) -> str:
        return self._local.complete(
            system_prompt=system_prompt,
            user_message=user_message,
            max_tokens=max_tokens,
            response_format=None,  # free-form; no schema forcing for ask / digest
        )

    def close(self) -> None:
        self._local.close()


class AutoTextClient:
    """`TextClient` for the `auto` backend: Anthropic, then local.

    Not reachable under regulated / NDA (effective_backend already forced local
    there), so falling back to local on an Anthropic failure never egresses a
    zero-egress meeting. The ladder is shared with summarize (PIPE7): only an
    unreachable-or-unwilling cloud drops to local, so a BadRequestError still
    surfaces instead of silently re-running on a different model.

    `backend_id` and `model` name whichever rung answered (PIPE19), the way
    `summarize.AutoFallbackClient` does.
    """

    def __init__(self, cfg: Config, model: str | None) -> None:
        self._cfg = cfg
        self._model = model
        self.backend_id = "auto"
        self.model = model or cfg.summarization.model

    def complete(self, *, system_prompt: str, user_message: str, max_tokens: int) -> str:
        def _cloud() -> tuple[str, str]:
            client = AnthropicTextClient(
                api_key=os.environ["ANTHROPIC_API_KEY"],
                model=self._model or self._cfg.summarization.model,
            )
            return client.complete(system_prompt=system_prompt, user_message=user_message,
                                   max_tokens=max_tokens), client.model

        def _local() -> tuple[str, str]:
            client = LocalTextClient(self._cfg, self._model)
            try:
                return client.complete(system_prompt=system_prompt, user_message=user_message,
                                       max_tokens=max_tokens), client.model
            finally:
                client.close()

        (text, self.model), self.backend_id = run_with_local_fallback(cloud=_cloud, local=_local)
        return text


def complete_text(
    cfg: Config,
    *,
    system_prompt: str,
    user_message: str,
    max_tokens: int,
    model: str | None = None,
) -> EngineResult:
    """Generate free-form assistant text under the resolved backend.

    `effective_backend(cfg)` decides the backend after the regulated / NDA
    force-local rule, so a zero-egress config never reaches a cloud call here;
    `providers` builds the client for it (PIPE19). `model` overrides the model
    for this one call (anthropic: the message model; local: the mlx server
    model); None uses the configured default. Raises `EngineError` with an
    actionable message on failure.

    The caller must have armed the egress guard (`arm_for_config`) and sourced
    secrets (`load_secrets`) at its CLI entry, exactly as summarize does.
    """
    backend = effective_backend(cfg)
    try:
        row = providers.lookup(backend)
    except ValueError as e:
        raise EngineError(str(e)) from e

    substituted_from: str | None = None
    if row.stand_in is not None:
        # The Apple Intelligence Foundation Model is Swift-only and only wired for
        # transcript summarization (the daemon produces it). ask / digest have no
        # daemon hand-off, so they run on the row's stand-in (the local MLX path):
        # still on-device, still zero-egress, just a different local model.
        #
        # PIPE12: a log line is not a surface. Someone who picked Apple
        # Intelligence precisely to avoid a resident multi-GB model gets one
        # spawned per ask, and `EngineResult.backend` reads "local", which is true
        # and explains nothing. So the substitution travels three ways now: the
        # log, a durable event, and the result the caller renders from.
        #
        # Emitted BEFORE the call, not after: the substitution is a routing fact,
        # already true whether or not the local model then answers, and a run that
        # fails is exactly when someone goes looking for why. `model` is therefore
        # the id this call asks for rather than `LocalSummaryClient.model`'s
        # read-back of what a warm server turned out to be serving (LOCAL11).
        log.info("backend %r has no Python free-form path; using %s for this call",
                 backend, row.stand_in)
        events.emit(
            "pipeline", "engine_backend_substituted",
            requested=backend, used=row.stand_in,
            model=model or cfg.summarization.local_model,
            reason="no Python free-form path",
        )
        substituted_from = backend
        row = providers.lookup(row.stand_in)

    if row.build_text is None:
        raise EngineError(f"summarization.backend {backend!r} has no free-form text path")
    client = row.build_text(cfg, model)
    try:
        text = client.complete(system_prompt=system_prompt, user_message=user_message,
                               max_tokens=max_tokens)
    finally:
        close = getattr(client, "close", None)
        if callable(close):
            close()
    text = (text or "").strip()
    if not text:
        raise EngineError(f"{client.backend_id} returned an empty completion")
    return EngineResult(text=text, backend=client.backend_id, model=client.model,
                        substituted_from=substituted_from)
