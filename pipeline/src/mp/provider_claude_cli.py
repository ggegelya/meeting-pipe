"""`claude_cli` backend: summarize / complete via headless `claude -p` (PROV1).

Spawns the Claude Code CLI non-interactively and parses its `--output-format
json` result. Two motivations: a Claude subscription already pays for Claude
Code, so this summarizes at zero marginal API cost and needs no API key (it rides
the user's existing Claude Code auth). The child therefore gets no managed token
in its environment: a present `ANTHROPIC_API_KEY` would be preferred over that
auth and bill the API instead (SEC20).

Confined to a text turn (SEC20). A bare `claude -p` is a full agent session, and
the prompt is a transcript or a set of meeting excerpts an attacker may have
spoken into, so `_command` turns off everything a text turn does not need: the
built-in tools (`--tools ""`; `--allowed-tools` only pre-approves, it removes
nothing), the owner's MCP servers (an empty strict config), everything
`--safe-mode` disables (the owner's CLAUDE.md, hooks, installed plugins, custom
commands and agents, skills; auth, model selection and the owner's settings
still work), and session persistence, so no transcript is left resumable on
disk. `--bare` would do most of that but reads only `ANTHROPIC_API_KEY`, never
the subscription's OAuth, which is the point of this backend. Every caller (summarize, `mp ask`, `mp digest`
including `--publish`, diarization cleanup) goes through `ClaudeCLIClient._run`,
so one place confines them all.

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
import tempfile
from pathlib import Path

from pydantic import ValidationError

from . import egress_guard, events
from .json_extract import parse_summary
from .prompt_safety import wrap_untrusted
from .schemas import SUMMARY_TOOL, MeetingSummary

log = logging.getLogger("mp.provider_claude_cli")

CLAUDE_BINARY = "claude"
# Where the `claude` binary may live when it is not on a non-login spawn's PATH.
# `~/.local/bin` is the standalone-installer default; the others are common. Searched
# before PATH (SEC17).
# Public since UX107: the Finish setup checklist mirrors this list (reachability-golden.json).
CLAUDE_SEARCH_DIRS = ("~/.local/bin", "~/.claude/local", "/opt/homebrew/bin", "/usr/local/bin")

# `claude -p` starts a full agent session; a summary is one turn but the model
# can be slow, so allow a generous wall-clock. The daemon watchdog is the hard
# backstop, as with the local backend.
_DEFAULT_TIMEOUT_SEC = 300.0


class ClaudeCLIError(RuntimeError):
    """The `claude` CLI was missing, refused, timed out, or returned no usable
    result. Carries a user-actionable message the CLI surfaces verbatim."""


_logged_claude: set[str] = set()


def _note_claude(path: str, how: str) -> str:
    """Log the resolved binary once per process, so a planted `claude` is at least visible (SEC17)."""
    if path not in _logged_claude:
        _logged_claude.add(path)
        log.info("claude CLI resolved to %s (%s)", path, how)
    return path


def find_claude() -> str | None:
    """Resolve the `claude` binary: the fixed install dirs first, then PATH (SEC17).

    PATH is user-writable, so a `claude` planted in an earlier entry would otherwise win over the
    real install. The fixed dirs are not a perfect fence (`~/.local/bin` is user-writable, and
    Homebrew owns `/opt/homebrew/bin` and usually `/usr/local/bin` as the user), but they are where
    Claude Code's installers put it, so a planted copy needs a write to a specific, auditable place
    rather than to anywhere on PATH. A stale copy in one of them now beats a newer one from nvm on
    PATH. PATH stays as the last resort for an install under nvm or a
    custom prefix; the path used is logged once per process either way.
    """
    for d in CLAUDE_SEARCH_DIRS:
        cand = Path(os.path.expanduser(d)) / CLAUDE_BINARY
        if cand.is_file() and os.access(cand, os.X_OK):
            return _note_claude(str(cand), "fixed install dir")
    found = shutil.which(CLAUDE_BINARY)
    if found:
        return _note_claude(found, "PATH")
    return None


class ClaudeCLIClient:
    """`SummaryClient` + `TextClient` over `claude -p --output-format json`."""

    # The model is whatever the user's Claude Code is configured to use; the run
    # sidecar records this label rather than a specific API model id.
    model = "claude-code"
    backend_id = "claude_cli"

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
        try:
            # A fresh empty directory per run, removed afterwards: the child has
            # no project to read and nothing of ours in its cwd. (It used to
            # inherit the pipeline's, which under launchd is `/`.)
            # `ignore_cleanup_errors`: a leftover file must not turn a good
            # reply into "could not spawn the claude CLI".
            with tempfile.TemporaryDirectory(
                prefix="mp-claude-cli-", ignore_cleanup_errors=True
            ) as workdir:
                proc = subprocess.run(
                    _command(binary),
                    input=prompt,
                    capture_output=True,
                    text=True,
                    timeout=self._timeout,
                    env=_child_env(),
                    cwd=workdir,
                )
        except subprocess.TimeoutExpired as e:
            raise ClaudeCLIError(f"claude CLI timed out after {self._timeout:.0f}s") from e
        except OSError as e:
            raise ClaudeCLIError(f"could not spawn the claude CLI: {e}") from e
        if proc.returncode != 0:
            raise ClaudeCLIError(
                f"claude CLI exited {proc.returncode}: {(proc.stderr or '').strip()[:500]}"
            )
        events.note_progress()  # PIPE53
        return _extract_result(proc.stdout)


def _command(binary: str) -> list[str]:
    """The confined argv (SEC20). The prompt rides stdin, so there is no
    positional argument for the variadic flags (`--tools`, `--mcp-config`) to
    swallow; each is followed by another flag, and a test pins that.

    `--safe-mode` is the flag that turns off the owner's own customizations
    (CLAUDE.md, hooks, plugins, agents, MCP) while leaving auth, model selection
    and the user's settings alone. `--setting-sources` is deliberately not used:
    it would also drop `apiKeyHelper`, the model and the `env` block from the
    owner's user settings, which a login that relies on them needs."""
    return [
        binary, "-p", "--output-format", "json",
        "--tools", "",
        "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
        "--safe-mode",
        "--disable-slash-commands",
        "--no-session-persistence",
    ]


def _child_env() -> dict[str, str]:
    """The child's environment: `egress_guard.child_env()` with every managed
    token removed in every mode (SEC20). The backend rides the user's Claude Code
    login, so it needs none, and `ANTHROPIC_API_KEY` in particular would be
    preferred over that login and bill the API."""
    from .config import MANAGED_SECRET_KEYS

    env = egress_guard.child_env()
    for key in MANAGED_SECRET_KEYS:
        env.pop(key, None)
    return env


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
