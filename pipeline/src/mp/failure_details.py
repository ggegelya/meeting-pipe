"""Optional, process-scoped failure result. Diagnostics stay in stderr/logs."""
from __future__ import annotations

import json
import os
import re
from pathlib import Path

import anthropic
import httpx

from .config import MissingSecretError
from .storage import atomic_write_text

OPERATIONS = {"summary", "ask", "digest", "publish", "transcribe", "processing", "rename_voice",
              "storage", "integrations", "model"}
PROVIDERS = {"anthropic", "openai", "notion", "local", "filesystem", "obsidian", "lan", "claude_cli"}


def describe(error: BaseException, *, operation: str, provider: str | None = None) -> dict:
    # Follow explicit wrapping only; a stale implicit context can describe a recovered failure.
    seen: set[int] = set()
    while error.__cause__ is not None and id(error) not in seen:
        seen.add(id(error))
        error = error.__cause__
    response = getattr(error, "response", None)
    status = getattr(error, "status_code", None)
    body = getattr(error, "body", None)
    request_id = getattr(error, "request_id", None)
    if isinstance(response, httpx.Response):
        status = response.status_code
        request_id = request_id or response.headers.get("request-id") or response.headers.get("x-request-id")
        try:
            body = body or response.json()
        except (ValueError, UnicodeError):
            pass
        try:
            host = response.request.url.host
        except RuntimeError:
            host = ""
        provider = provider or {"api.anthropic.com": "anthropic", "api.openai.com": "openai",
                                "api.notion.com": "notion"}.get(host)
    if isinstance(error, anthropic.APIError):
        provider = "anthropic"
    native = body.get("error", body) if isinstance(body, dict) else {}
    code = native.get("code") or native.get("type") if isinstance(native, dict) else None
    if not isinstance(code, str):
        code = None
    message = str(error).lower()
    if isinstance(native, dict) and isinstance(native.get("message"), str):
        message += " " + native["message"].lower()
    cause = "unknown"
    if isinstance(error, MissingSecretError):
        cause = "missing_key"
        provider = {"ANTHROPIC_API_KEY": "anthropic", "OPENAI_API_KEY": "openai",
                    "NOTION_TOKEN": "notion"}.get(error.name)
    elif provider == "anthropic" and status == 400 and "your credit balance is too low" in message:
        cause = "credits"
    elif code in {"insufficient_quota", "billing_hard_limit_reached", "credit_balance_too_low"}:
        cause = "quota"
    elif status == 401:
        cause = "expired_key" if "key has expired" in message or "token has expired" in message else "rejected_key"
    elif isinstance(error, (anthropic.APITimeoutError, httpx.TimeoutException, TimeoutError)):
        cause = "timeout"
    elif isinstance(error, (anthropic.APIConnectionError, httpx.ConnectError, ConnectionError)):
        cause = "connection"
    elif status == 429:
        cause = "rate_limit"
    elif isinstance(status, int) and 500 <= status <= 599:
        cause = "service_unavailable"
    elif "not enough memory" in message:
        cause = "memory"
        provider = "local"
    elif "not in the local huggingface cache" in message or type(error).__name__ == "EmbedderUnavailableError":
        cause = "model_missing"
        provider = "local"
    elif operation == "publish":
        cause = "publish"
    remedy = {"credits": "billing", "quota": "billing", "missing_key": "integrations",
              "rejected_key": "integrations", "expired_key": "integrations", "memory": "model",
              "model_missing": "model"}.get(cause, "retry")
    result: dict = {"schema_version": 1, "cause": cause,
                    "operation": operation if operation in OPERATIONS else "processing", "remedy": remedy}
    if provider in PROVIDERS:
        result["provider"] = provider
    if isinstance(status, int) and not isinstance(status, bool) and 100 <= status <= 599:
        result["http_status"] = status
    if isinstance(request_id, str) and re.fullmatch(r"req_[A-Za-z0-9]{8,96}|[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}", request_id):
        result["request_id"] = request_id
    return result


def emit_failure(error: BaseException, *, operation: str, provider: str | None = None) -> dict:
    payload = describe(error, operation=operation, provider=provider)
    if path := os.environ.get("MP_FAILURE_PATH"):
        try:
            if not Path(path).exists():
                atomic_write_text(Path(path), json.dumps(payload, sort_keys=True) + "\n")
        except OSError:
            # Optional metadata must never replace the original exception or exit status.
            pass
    return payload
