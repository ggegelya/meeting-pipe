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
70 GB-ish memory spike for a 14 B model. Running the server lets us
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

from .schemas import MeetingSummary, SUMMARY_TOOL

log = logging.getLogger("mp.summarize_local")

DEFAULT_MODEL = "mlx-community/Qwen2.5-14B-Instruct-4bit"
DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8765
DEFAULT_STARTUP_TIMEOUT_SEC = 120.0
DEFAULT_IDLE_TIMEOUT_SEC = 300.0


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
        idle_timeout_sec: float = DEFAULT_IDLE_TIMEOUT_SEC,
        manage_subprocess: bool = True,
    ) -> None:
        self._model = model
        self._host = host
        self._port = port
        self._startup_timeout_sec = startup_timeout_sec
        self._idle_timeout_sec = idle_timeout_sec
        # Test seam: when False we assume the caller has a server
        # already running on (host, port) and never spawn one.
        self._manage_subprocess = manage_subprocess

        self._proc: subprocess.Popen[bytes] | None = None
        self._lock = threading.Lock()
        self._idle_timer: threading.Timer | None = None
        self._http = httpx.Client(timeout=httpx.Timeout(120.0, connect=5.0))

    # ----- Public API (SummaryClient) -----

    def summarize(
        self,
        *,
        system_prompt: str,
        transcript: str,
        model: str,  # ignored; the local server pins one model per process
        max_tokens: int,
    ) -> MeetingSummary:
        """Two-attempt loop.

        Attempt 1 sends the schema-augmented system prompt and (when the
        backend honors it) the OpenAI ``response_format: json_schema``
        hint. Attempt 2, fired only on a schema violation from attempt
        1, replays the call with a corrective user message that includes
        the Pydantic validation error so the model can repair its own
        output. Each attempt's body still passes through the 3-layer
        extraction fallback in ``_extract_summary``.
        """
        with self._lock:
            self._ensure_running()
            self._reset_idle_timer()

            messages = [
                {"role": "system", "content": self._augment_with_schema(system_prompt)},
                {"role": "user", "content": self._compose_user_message(transcript)},
            ]
            first_text = self._chat_completion(
                messages=messages, max_tokens=max_tokens
            )
            try:
                return self._extract_summary(first_text)
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
                return self._extract_summary(second_text)

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
        # Prefer the standalone entry point if mlx-lm shipped one;
        # otherwise invoke through python -m so the user does not have
        # to manage which interpreter has mlx-lm installed.
        if shutil.which("mlx_lm.server") is not None:
            cmd = ["mlx_lm.server"]
        else:
            cmd = [sys.executable, "-m", "mlx_lm.server"]
        cmd += [
            "--model", self._model,
            "--host", self._host,
            "--port", str(self._port),
        ]
        log.info("spawning mlx_lm.server: %s", " ".join(cmd))
        # Detach into a new process group so a Ctrl-C in the daemon does
        # not also terminate the model server before we get to clean it up.
        kwargs: dict[str, Any] = {
            "stdout": subprocess.DEVNULL,
            "stderr": subprocess.STDOUT,
        }
        if hasattr(os, "setsid"):
            kwargs["preexec_fn"] = os.setsid
        self._proc = subprocess.Popen(cmd, **kwargs)

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
            return
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
        ``_extract_summary``."""
        schema = json.dumps(SUMMARY_TOOL["input_schema"], indent=2)
        directive = (
            "\n\n---\n\nYour reply MUST be a single JSON object that validates"
            " against this JSON Schema. Output the JSON object and nothing else:"
            " no prose, no Markdown fences, no commentary.\n\n"
            f"```json-schema\n{schema}\n```"
        )
        return system_prompt + directive

    def _compose_user_message(self, transcript: str) -> str:
        return (
            "Summarize this meeting. Reply with ONLY the JSON object described "
            "in the system message.\n\nTRANSCRIPT:\n\n" + transcript
        )

    def _chat_completion(
        self,
        *,
        messages: list[dict[str, str]],
        max_tokens: int,
    ) -> str:
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
            "response_format": {
                "type": "json_schema",
                "json_schema": {
                    "name": "meeting_summary",
                    "schema": SUMMARY_TOOL["input_schema"],
                    "strict": True,
                },
            },
        }
        try:
            r = self._http.post(f"{self.base_url}/v1/chat/completions", json=payload)
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
        biggest = _largest_balanced_json_object(text)
        if biggest is not None:
            out.append((3, biggest))
        return out


def _largest_balanced_json_object(text: str) -> str | None:
    best: tuple[int, int, int] | None = None  # (length, start, end)
    depth = 0
    start = -1
    in_str = False
    escape = False
    for i, ch in enumerate(text):
        if in_str:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                in_str = False
            continue
        if ch == '"':
            in_str = True
            continue
        if ch == "{":
            if depth == 0:
                start = i
            depth += 1
            continue
        if ch == "}":
            if depth == 0:
                continue
            depth -= 1
            if depth == 0 and start >= 0:
                length = i - start + 1
                if best is None or length > best[0]:
                    best = (length, start, i + 1)
                start = -1
    if best is None:
        return None
    return text[best[1]:best[2]]
