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

Why a subprocess and not a library import: ``mlx_lm`` keeps the
loaded model in process memory for the life of the interpreter. A
short-lived CLI invocation pays a 10-30 s warm-up per call and a
~8 GB resident footprint for a 14 B 4-bit model (larger for 32 B). Running the server lets us
amortize the load across calls and shut it down on idle.
"""
from __future__ import annotations

import json
import logging
import os
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
from typing import Any

import httpx
from pydantic import ValidationError

from . import egress_guard, local_server
from .chunking import chunked_windows
from .json_extract import largest_balanced_json_object
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
# AppleIntelligenceSummarizer's LOCAL3 batched reduce out of Swift. A transcript
# over this many chars would overflow the model context in one call (AI2 measured
# ~4K tokens safe on the owner's Mac; 16K OOM-crashed it), so summarize() windows
# it, summarizes each window, then reduces the partials in batches. The threshold
# is `summarization.skip_above_chars` in production (one knob drives both the cloud
# paste-bundle guard and this local routing); the default here matches its default.
DEFAULT_MAP_REDUCE_ABOVE_CHARS = 80_000
# Per-window char budget. Cyrillic tokenizes at ~1.7 tokens/char, so ~1500 chars
# keeps a worst-case map call near the ~4K-token safe budget once the fixed system
# prompt, JSON schema, and output are added; an English window carries proportionally
# more text under the same token ceiling. Overlap keeps a sentence spanning a window
# boundary in at least one window (chunking.py snaps to whitespace).
_MAP_WINDOW_CHARS = 1_500
_MAP_OVERLAP_CHARS = 200
# Partial summaries merged per reduce call, so the reduce input also stays under the
# budget. Bounded below at 2 so the reduce always makes progress toward one summary.
_REDUCE_BATCH = 4


def scaled_request_timeout(base_sec: float, max_tokens: int) -> float:
    """Per-request read timeout: a fixed ``base_sec`` budget (connect + prefill
    + slack) plus generation time for ``max_tokens`` at a conservative speed
    floor. Scales with the requested output length so a long summary is not cut
    off mid-stream, while the daemon's 20-min watchdog remains the hard backstop
    (LOCAL2/AUD-21). Pure so it is unit-testable without a server."""
    return base_sec + max(0, max_tokens) * _SECONDS_PER_OUTPUT_TOKEN_FLOOR


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
    """
    if shutil.which("mlx_lm.server") is not None:
        cmd = ["mlx_lm.server"]
    else:
        cmd = [sys.executable, "-m", "mlx_lm.server"]
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

        self._proc: subprocess.Popen[bytes] | None = None
        self._lock = threading.Lock()
        self._idle_timer: threading.Timer | None = None
        # Base client timeout; the chat-completion POST overrides the read leg
        # per call, scaled to max_tokens (LOCAL2). Health checks override to 2s.
        self._http = httpx.Client(timeout=httpx.Timeout(request_timeout_sec, connect=5.0))

    @property
    def model(self) -> str:
        """Repo id of the MLX model this client is pinned to.

        Read by ``mp.summarize._identify_backend`` so the run sidecar
        records the actual model that produced a summary, even when
        Preferences swaps the configured model later.
        """
        return self._model

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
        """
        with self._lock:
            self._ensure_running()
            self._reset_idle_timer()

            target = expected_summary_language(self._summary_language, transcript)
            if self._map_reduce_above_chars and len(transcript) > self._map_reduce_above_chars:
                # PIPE4: too long for one context; window -> map -> reduce.
                return self._summarize_map_reduce(
                    system_prompt=system_prompt, transcript=transcript,
                    target=target, max_tokens=max_tokens,
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
        system_content = self._augment_with_schema(system_prompt)
        if target:
            # Restate the target after the schema, where the local model's token
            # attention is highest; the base directive already rode in via the
            # system prompt but was being ignored (LOCAL7).
            system_content += language_reinforcement(target)
        messages = [
            {"role": "system", "content": system_content},
            {"role": "user", "content": self._compose_user_message(text)},
        ]
        summary, last_text = self._summarize_with_schema_retry(messages, max_tokens)
        return summary, last_text, messages

    def _summarize_map_reduce(
        self, *, system_prompt: str, transcript: str, target: str | None, max_tokens: int,
    ) -> MeetingSummary:
        """Hierarchical map-reduce for a transcript too long for one call (PIPE4),
        generalizing ``AppleIntelligenceSummarizer.generate`` (LOCAL3). Windows the
        transcript (Cyrillic-safe char budget), summarizes each window, then reduces
        the partials in batches until one remains. Called with the lock held and the
        server running (from ``summarize``); the final summary still passes through
        the language-mismatch repair, so a drifted merge is caught."""
        windows = list(chunked_windows(
            transcript, max_chars=_MAP_WINDOW_CHARS, overlap_chars=_MAP_OVERLAP_CHARS,
        ))
        log.info("map-reduce: %d chars -> %d windows", len(transcript), len(windows))
        if len(windows) <= 1:
            summary, last_text, messages = self._summarize_once(
                system_prompt, windows[0].text if windows else transcript, target, max_tokens
            )
            if target:
                summary = self._retry_on_language_mismatch(
                    summary, last_text, messages, target, max_tokens
                )
            return summary
        partials = [self._map_window(system_prompt, w.text, target, max_tokens) for w in windows]
        return self._reduce_partials(partials, target, max_tokens)

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
        self, partials: list[MeetingSummary], target: str | None, max_tokens: int,
    ) -> MeetingSummary:
        """Merge partials in batches of ``_REDUCE_BATCH`` until one remains, so every
        reduce call's input also stays under the context budget."""
        while len(partials) > 1:
            nxt: list[MeetingSummary] = []
            for group in _batched(partials, _REDUCE_BATCH):
                nxt.append(group[0] if len(group) == 1 else self._reduce_group(group, target, max_tokens))
            partials = nxt
        return partials[0]

    def _reduce_group(
        self, group: list[MeetingSummary], target: str | None, max_tokens: int,
    ) -> MeetingSummary:
        self._reset_idle_timer()
        combined = "\n\n---\n\n".join(_render_for_reduce(p) for p in group)
        system_content = self._augment_with_schema(_reduce_instructions())
        if target:
            system_content += language_reinforcement(target)
        messages = [
            {"role": "system", "content": system_content},
            {"role": "user", "content": (
                "Merge these partial meeting summaries into one summary of the whole "
                "meeting. Reply with ONLY the JSON object described in the system "
                "message.\n\n" + combined
            )},
        ]
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
            log.warning("attempt 1 failed schema validation; replaying with correction")
            correction_messages = messages + [
                {"role": "assistant", "content": first_text},
                {
                    "role": "user",
                    "content": (
                        "Your previous reply did not parse as a JSON object that"
                        " validates against the schema. Error:\n\n"
                        f"{e}\n\n"
                        "Reply with ONLY a valid JSON object that matches the"
                        " schema in the system message. No prose, no Markdown"
                        " fences, no commentary."
                    ),
                },
            ]
            second_text = self._chat_completion(
                messages=correction_messages, max_tokens=max_tokens
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
        if self._is_healthy():
            return
        if not self._manage_subprocess:
            raise LocalSummaryError(
                f"No server reachable at {self.base_url} and manage_subprocess=False"
            )
        self._spawn()
        self._wait_for_health(self._startup_timeout_sec)

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
            raise LocalSummaryError(
                f"Model {self._model!r} is not in the local HuggingFace cache, and this "
                f"is a regulated/NDA run, so it cannot be downloaded now. Fetch it "
                f"outside a zero-egress meeting first:\n"
                f"    mp prefetch-model {self._model}"
            )
        cmd = build_server_command(self._model, self._host, self._port, self._adapter_path)
        log.info("spawning mlx_lm.server: %s", " ".join(cmd))
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.DEVNULL,
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
        local_server.write_marker(pid=proc.pid, port=self._port, model=self._model)

    def _wait_for_health(self, timeout_sec: float) -> None:
        deadline = time.monotonic() + timeout_sec
        last_err: Exception | None = None
        while time.monotonic() < deadline:
            if self._proc is not None and self._proc.poll() is not None:
                rc = self._proc.returncode
                self._proc = None
                raise LocalSummaryError(
                    f"mlx_lm.server exited during startup (rc={rc}). "
                    "Check that the model name resolves and you have enough RAM."
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

    def _compose_user_message(self, transcript: str) -> str:
        # Fence the transcript as untrusted content (TECH-SEC6); the system
        # prompt (via _load_system_prompt) explains the markers.
        return (
            "Summarize this meeting. Reply with ONLY the JSON object described "
            "in the system message.\n\n" + wrap_untrusted(transcript)
        )

    def _chat_completion(
        self,
        *,
        messages: list[dict[str, str]],
        max_tokens: int,
        response_format: dict[str, Any] | None = None,
    ) -> str:
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
            # layer 2 of the fallback was firing on most calls.
            "temperature": 0.2,
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
            raise LocalSummaryError(
                f"local backend returned {r.status_code}: {r.text[:500]}"
            )
        data = r.json()
        try:
            return data["choices"][0]["message"]["content"]
        except (KeyError, IndexError, TypeError) as e:
            raise LocalSummaryError(f"unexpected response shape: {data}") from e

    # ----- Output extraction -----

    def _extract_summary(self, text: str) -> MeetingSummary:
        """3-layer fallback. Each layer returns a MeetingSummary or
        raises; only the final layer's failure propagates out."""
        # Layer 1: parse the response body verbatim as JSON.
        for layer, candidate in self._candidates(text):
            try:
                obj = json.loads(candidate)
            except json.JSONDecodeError:
                continue
            try:
                summary = MeetingSummary.model_validate(obj)
            except ValidationError as ve:
                log.warning("layer %d schema violation: %s", layer, ve)
                continue
            if layer > 1:
                log.info("recovered MeetingSummary via layer %d fallback", layer)
            return summary
        raise LocalSummaryError(
            "local model output did not contain a schema-valid JSON object after 3 layers"
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
        return out


# The balanced-object scan moved to `json_extract` (PROV1) so `claude_cli` shares
# it. Kept as a module-level alias because `test_summarize_local` imports this
# name directly; new call sites use `largest_balanced_json_object`.
_largest_balanced_json_object = largest_balanced_json_object


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

    from .config import Config, parse_local_endpoint

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    cfg = Config.load()
    host, port = parse_local_endpoint(cfg.summarization.local_endpoint)
    host = _loopback_only(host)
    model = cfg.summarization.local_model
    # LOCAL9: the warm server serves the configured adapter too, so it matches the
    # lazy per-call spawn (LocalSummaryClient) and the daemon reuses one server.
    cmd = build_server_command(model, host, port, cfg.summarization.local_adapter_path or None)
    log.info("serve-local: exec %s", " ".join(cmd))
    try:
        os.execvp(cmd[0], cmd)
    except OSError as e:
        log.error(
            "serve-local could not exec %s: %s. Install mlx-lm "
            "(`pip install mlx-lm`) for the local backend.",
            cmd[0], e,
        )
        return 1
    return 0  # unreachable after a successful execvp


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main(sys.argv[1:]))
