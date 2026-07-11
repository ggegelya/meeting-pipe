"""`openai` backend: summarize / complete over an OpenAI-compatible API (PROV1).

Talks to the chat-completions endpoint with raw `httpx` rather than the `openai`
SDK, deliberately: the process-wide egress guard patches httpx's transports, so
routing through httpx means a regulated/NDA run clamps this provider exactly like
the Anthropic path, with no SDK-specific plumbing. The key lives in the macOS
Keychain as `OPENAI_API_KEY` (the SEC8 pattern), and `effective_backend` forces
local under zero_egress, so this cloud provider is never even constructed there.

One class satisfies both seam shapes (`SummaryClient.summarize` +
`TextClient.complete`), the LocalSummaryClient precedent, so a provider is one
module. Structured output uses the API's JSON mode plus a schema directive, with
the same balanced-object recovery the local path uses for messy output.
"""
from __future__ import annotations

import json
import logging
from typing import Any

import httpx
from pydantic import ValidationError

from .endpoints import OPENAI_API_BASE, OPENAI_CHAT_PATH
from .json_extract import largest_balanced_json_object
from .prompt_safety import wrap_untrusted
from .schemas import SUMMARY_TOOL, MeetingSummary

log = logging.getLogger("mp.provider_openai")

# Bound a stalled connection instead of hanging the run, matching summarize's
# posture: a tight connect, a generous read for a legitimate generation.
_TIMEOUT = httpx.Timeout(120.0, connect=10.0)


class OpenAIError(RuntimeError):
    """The OpenAI-compatible backend could not produce a completion."""


class OpenAIClient:
    """`SummaryClient` + `TextClient` over an OpenAI-compatible chat API."""

    def __init__(self, *, api_key: str, model: str, api_base: str = OPENAI_API_BASE) -> None:
        self._api_key = api_key
        self.model = model
        self._api_base = api_base.rstrip("/")

    # ----- SummaryClient -----

    def summarize(
        self,
        *,
        system_prompt: str,
        transcript: str,
        model: str,  # ignored; the provider is pinned to its configured model
        max_tokens: int,
    ) -> MeetingSummary:
        schema = json.dumps(SUMMARY_TOOL["input_schema"], ensure_ascii=False)
        system_content = (
            system_prompt
            + "\n\nYour reply MUST be a single JSON object that validates against "
            "this JSON Schema. Output the JSON object and nothing else: no prose, "
            "no Markdown fences.\n\n"
            f"```json-schema\n{schema}\n```"
        )
        user_content = (
            "Summarize this meeting. Reply with ONLY the JSON object described "
            "in the system message.\n\n" + wrap_untrusted(transcript)
        )
        messages = [
            {"role": "system", "content": system_content},
            {"role": "user", "content": user_content},
        ]
        last_err: Exception | None = None
        for attempt in (1, 2):
            text = self._chat(messages, max_tokens=max_tokens, json_mode=True)
            try:
                return _parse_summary(text)
            except (ValidationError, json.JSONDecodeError, OpenAIError) as e:
                last_err = e
                log.warning("openai summarize attempt %d: %s", attempt, e)
                messages = messages + [
                    {"role": "assistant", "content": text},
                    {
                        "role": "user",
                        "content": (
                            "That did not validate against the schema "
                            f"({e}). Reply again with ONLY the corrected JSON object."
                        ),
                    },
                ]
        assert last_err is not None
        raise OpenAIError(f"openai did not return a schema-valid summary: {last_err}")

    # ----- TextClient -----

    def complete(self, *, system_prompt: str, user_message: str, max_tokens: int) -> str:
        text = self._chat(
            [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_message},
            ],
            max_tokens=max_tokens,
            json_mode=False,
        ).strip()
        if not text:
            raise OpenAIError("openai returned an empty completion")
        return text

    # ----- HTTP -----

    def _chat(
        self, messages: list[dict[str, str]], *, max_tokens: int, json_mode: bool
    ) -> str:
        payload: dict[str, Any] = {
            "model": self.model,
            "messages": messages,
            "max_tokens": max_tokens,
            "temperature": 0.2,
        }
        if json_mode:
            # JSON mode guarantees syntactically valid JSON; the schema still
            # rides in the prompt since plain json_object does not enforce shape.
            payload["response_format"] = {"type": "json_object"}
        try:
            with httpx.Client(timeout=_TIMEOUT) as client:
                r = client.post(
                    f"{self._api_base}{OPENAI_CHAT_PATH}",
                    headers={
                        "Authorization": f"Bearer {self._api_key}",
                        "Content-Type": "application/json",
                    },
                    json=payload,
                )
        except httpx.HTTPError as e:
            raise OpenAIError(f"openai backend HTTP error: {e}") from e
        if r.status_code != 200:
            raise OpenAIError(f"openai backend returned {r.status_code}: {r.text[:500]}")
        try:
            content = r.json()["choices"][0]["message"]["content"]
        except (KeyError, IndexError, TypeError) as e:
            raise OpenAIError(f"unexpected openai response shape: {r.text[:500]}") from e
        return content or ""


def _parse_summary(text: str) -> MeetingSummary:
    """Validate the model's text into a `MeetingSummary`, recovering the JSON
    object from any surrounding prose with the shared balanced-object scan."""
    for candidate in (text.strip(), largest_balanced_json_object(text)):
        if not candidate:
            continue
        try:
            return MeetingSummary.model_validate(json.loads(candidate))
        except (json.JSONDecodeError, ValidationError):
            continue
    raise OpenAIError("no schema-valid JSON object in the openai response")
