"""`claude_cli` backend: summarize / complete via headless `claude -p` (PROV1).

Spawns the Claude Code CLI non-interactively and parses its `--output-format
json` result. Two motivations: a Claude subscription already pays for Claude
Code, so this summarizes at zero marginal API cost and needs no API key (it rides
the user's existing Claude Code auth).

Load-bearing security note: a CLI child egresses through a child process,
OUTSIDE this process's in-process httpx egress guard, so it is fail-closed at the
POLICY layer. `config.effective_backend` classes every CLI backend as cloud and
forces local under regulated/NDA, so a zero-egress run never selects it; on top
of that, `_run` refuses to spawn whenever the guard is armed (the SEC10 posture,
defense in depth). The prompt goes in on stdin, not argv, so a long transcript
never hits ARG_MAX, and the child gets `egress_guard.child_env()`.
"""
from __future__ import annotations

import json
import logging
import os
import shutil
import subprocess
from pathlib import Path

from pydantic import ValidationError

from . import egress_guard
from .json_extract import parse_summary
from .prompt_safety import wrap_untrusted
from .schemas import SUMMARY_TOOL, MeetingSummary

log = logging.getLogger("mp.provider_claude_cli")

CLAUDE_BINARY = "claude"
# Where the `claude` binary may live when it is not on a non-login spawn's PATH.
# `~/.local/bin` is the standalone-installer default; the others are common.
_FALLBACK_DIRS = ("~/.local/bin", "~/.claude/local", "/opt/homebrew/bin", "/usr/local/bin")

# `claude -p` starts a full agent session; a summary is one turn but the model
# can be slow, so allow a generous wall-clock. The daemon watchdog is the hard
# backstop, as with the local backend.
_DEFAULT_TIMEOUT_SEC = 300.0


class ClaudeCLIError(RuntimeError):
    """The `claude` CLI was missing, refused, timed out, or returned no usable
    result. Carries a user-actionable message the CLI surfaces verbatim."""


def find_claude() -> str | None:
    """Resolve the `claude` binary: PATH first, then the common install dirs."""
    found = shutil.which(CLAUDE_BINARY)
    if found:
        return found
    for d in _FALLBACK_DIRS:
        cand = Path(os.path.expanduser(d)) / CLAUDE_BINARY
        if cand.is_file() and os.access(cand, os.X_OK):
            return str(cand)
    return None


class ClaudeCLIClient:
    """`SummaryClient` + `TextClient` over `claude -p --output-format json`."""

    # The model is whatever the user's Claude Code is configured to use; the run
    # sidecar records this label rather than a specific API model id.
    model = "claude-code"

    def __init__(self, *, request_timeout_sec: float = _DEFAULT_TIMEOUT_SEC) -> None:
        self._timeout = request_timeout_sec

    # ----- SummaryClient -----

    def summarize(
        self,
        *,
        system_prompt: str,
        transcript: str,
        model: str,  # ignored; claude_cli uses the user's configured Claude model
        max_tokens: int,  # ignored; claude -p manages its own output length
    ) -> MeetingSummary:
        schema = json.dumps(SUMMARY_TOOL["input_schema"], ensure_ascii=False)
        prompt = (
            system_prompt
            + "\n\nReply with ONLY a single JSON object that validates against "
            "this JSON Schema. No prose, no Markdown fences, just the JSON.\n\n"
            f"```json-schema\n{schema}\n```\n\nMeeting transcript:\n\n"
            + wrap_untrusted(transcript)
        )
        last_err: Exception | None = None
        for attempt in (1, 2):
            text = self._run(prompt if attempt == 1 else prompt + _repair_hint(last_err))
            try:
                return parse_summary(
                    text,
                    error=ClaudeCLIError,
                    message="no schema-valid JSON object in the claude CLI result",
                )
            except (ValidationError, json.JSONDecodeError, ClaudeCLIError) as e:
                last_err = e
                log.warning("claude_cli summarize attempt %d: %s", attempt, e)
        assert last_err is not None
        raise ClaudeCLIError(f"claude_cli did not return a schema-valid summary: {last_err}")

    # ----- TextClient -----

    def complete(self, *, system_prompt: str, user_message: str, max_tokens: int) -> str:
        text = self._run(system_prompt + "\n\n" + user_message).strip()
        if not text:
            raise ClaudeCLIError("claude_cli returned an empty completion")
        return text

    # ----- subprocess -----

    def _run(self, prompt: str) -> str:
        # Fail-closed: a CLI child egresses outside the in-process httpx guard,
        # so refuse to spawn under a zero-egress run even though effective_backend
        # already forced local. Defense in depth (SEC10).
        if egress_guard.is_armed():
            raise ClaudeCLIError(
                "refusing to spawn the claude CLI under a zero-egress (regulated/NDA) run"
            )
        binary = find_claude()
        if binary is None:
            raise ClaudeCLIError(
                "the `claude` CLI is not installed or not on PATH; install Claude Code "
                "or choose a different summarization.backend"
            )
        # No positional prompt -> claude reads it from stdin (avoids ARG_MAX on a
        # long transcript). `--allowed-tools ""` disables tool use; a summary is a
        # pure text turn.
        cmd = [binary, "-p", "--output-format", "json", "--allowed-tools", ""]
        try:
            proc = subprocess.run(
                cmd,
                input=prompt,
                capture_output=True,
                text=True,
                timeout=self._timeout,
                env=egress_guard.child_env(),
            )
        except subprocess.TimeoutExpired as e:
            raise ClaudeCLIError(f"claude CLI timed out after {self._timeout:.0f}s") from e
        except OSError as e:
            raise ClaudeCLIError(f"could not spawn the claude CLI: {e}") from e
        if proc.returncode != 0:
            raise ClaudeCLIError(
                f"claude CLI exited {proc.returncode}: {(proc.stderr or '').strip()[:500]}"
            )
        return _extract_result(proc.stdout)


def _extract_result(stdout: str) -> str:
    """Pull the assistant text out of `claude -p --output-format json` output.

    The response is a single JSON object `{"is_error": bool, "result": str, ...}`.
    An `is_error` result (auth failure, model error) is surfaced as a
    `ClaudeCLIError` carrying the CLI's own message, not treated as a summary.
    """
    try:
        obj = json.loads(stdout)
    except json.JSONDecodeError as e:
        raise ClaudeCLIError(f"claude CLI produced non-JSON output: {stdout[:300]}") from e
    if not isinstance(obj, dict):
        raise ClaudeCLIError(f"claude CLI output was not an object: {stdout[:300]}")
    if obj.get("is_error"):
        raise ClaudeCLIError(f"claude CLI error: {obj.get('result') or obj}")
    result = obj.get("result")
    if not isinstance(result, str) or not result.strip():
        raise ClaudeCLIError("claude CLI returned no result text")
    return result


def _repair_hint(err: Exception | None) -> str:
    return (
        "\n\nYour previous reply did not validate against the schema "
        f"({err}). Reply again with ONLY the corrected JSON object."
    )
