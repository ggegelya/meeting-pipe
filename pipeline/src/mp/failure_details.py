"""Optional, process-scoped failure result. Diagnostics stay in stderr/logs."""
from __future__ import annotations

import json
import os
import re
from pathlib import Path

import anthropic
import httpcore
import httpx

from .config import ConfigError, MissingSecretError
from .storage import atomic_write_text

OPERATIONS = {"summary", "ask", "digest", "publish", "transcribe", "processing", "rename_voice",
              "storage", "integrations", "model"}
PROVIDERS = {"anthropic", "openai", "notion", "local", "filesystem", "obsidian", "lan", "claude_cli"}


_TIMEOUTS = (anthropic.APITimeoutError, httpx.TimeoutException, httpcore.TimeoutException, TimeoutError)
_CONNECTIONS = (anthropic.APIConnectionError, httpx.ConnectError, httpcore.ConnectError, ConnectionError)


def _chain(error: BaseException) -> list[BaseException]:
    """The explicit `__cause__` chain, outermost first, cycle-guarded."""
    links: list[BaseException] = []
    seen: set[int] = set()
    cur: BaseException | None = error
    while cur is not None and id(cur) not in seen:
        seen.add(id(cur))
        links.append(cur)
        cur = cur.__cause__
    return links


def _names_a_rejected_model(status: object, code: str | None, message: str, provider: str | None) -> bool:
    """PIPE28: a cloud API that answered "no" about the *model id* (a retired or mistyped id is a
    404, a model the account may not use a 403), as opposed to a 404/403 about anything else. The
    message has to name a model, so a Notion 404 or an Anthropic 403 about the key stays what it
    was. Provider-scoped: only the two cloud engines take a configurable model id."""
    if provider not in {"anthropic", "openai"} or "model" not in message:
        return False
    if status == 404:
        return code in {"not_found_error", "model_not_found"}
    return status == 403


def _has_type_name(links: list[BaseException], name: str) -> bool:
    return any(type(link).__name__ == name for link in links)


def describe(error: BaseException, *, operation: str, provider: str | None = None) -> dict:
    # Follow explicit wrapping only; a stale implicit context can describe a recovered failure.
    # PIPE44: classify on the first link, outermost first, that matches a known class. The old
    # walk judged only the root, which for an Anthropic timeout is httpcore.ReadTimeout (the SDK
    # wraps httpx.ReadTimeout wraps httpcore.ReadTimeout), a class no check named, so the one
    # field timeout was filed as cause unknown.
    links = _chain(error)

    def first(kind: type | tuple[type, ...]) -> BaseException | None:
        return next((link for link in links if isinstance(link, kind)), None)

    # The status-bearing fields come from the first link that carries a response or a status, so a
    # wrapped APIStatusError keeps its HTTP status and request id; a chain with none reads the root,
    # as before.
    carrier = next(
        (link for link in links
         if isinstance(getattr(link, "response", None), httpx.Response)
         or getattr(link, "status_code", None) is not None),
        links[-1],
    )
    response = getattr(carrier, "response", None)
    status = getattr(carrier, "status_code", None)
    body = getattr(carrier, "body", None)
    request_id = getattr(carrier, "request_id", None)
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
    if first(anthropic.APIError) is not None:
        provider = "anthropic"
    native = body.get("error", body) if isinstance(body, dict) else {}
    code = native.get("code") or native.get("type") if isinstance(native, dict) else None
    if not isinstance(code, str):
        code = None
    message = str(carrier).lower()
    if isinstance(native, dict) and isinstance(native.get("message"), str):
        message += " " + native["message"].lower()
    cause = "unknown"
    if isinstance(secret := first(MissingSecretError), MissingSecretError):
        cause = "missing_key"
        provider = {"ANTHROPIC_API_KEY": "anthropic", "OPENAI_API_KEY": "openai",
                    "NOTION_TOKEN": "notion"}.get(secret.name)
    elif first(ConfigError) is not None:
        # UX94: config.toml does not parse, or says something the load refuses (PIPE42). A retry
        # fails the same way until the file is fixed, so the remedy is the file.
        cause = "config"
    elif provider == "anthropic" and status == 400 and "your credit balance is too low" in message:
        cause = "credits"
    elif code in {"insufficient_quota", "billing_hard_limit_reached", "credit_balance_too_low"}:
        cause = "quota"
    elif status == 401:
        cause = "expired_key" if "key has expired" in message or "token has expired" in message else "rejected_key"
    elif _names_a_rejected_model(status, code, message, provider):
        cause = "model_rejected"
    elif first(_TIMEOUTS) is not None:
        cause = "timeout"
    elif first(_CONNECTIONS) is not None:
        cause = "connection"
    elif status == 429:
        cause = "rate_limit"
    elif isinstance(status, int) and 500 <= status <= 599:
        cause = "service_unavailable"
    elif "not enough memory" in message:
        cause = "memory"
        provider = "local"
    elif "not in the local huggingface cache" in message or _has_type_name(links, "EmbedderUnavailableError"):
        cause = "model_missing"
        provider = "local"
    elif _has_type_name(links, "OverlayUnreadable"):
        # STOR9: a present speaker-label, correction or marker sidecar that will not read. Retrying
        # without fixing the file refuses again; the remedy is the file, so the cause is its own.
        cause = "overlay_unreadable"
    elif _has_type_name(links, "SyncedTargetError"):
        # SEC18: a zero-egress run's file sink sits inside a sync folder. Retrying cannot help until the
        # publish folder is changed in Integrations, so it is its own cause with that remedy.
        cause = "synced_target"
    elif operation == "publish":
        cause = "publish"
    remedy = {"credits": "billing", "quota": "billing", "missing_key": "integrations",
              "rejected_key": "integrations", "expired_key": "integrations", "synced_target": "integrations",
              "memory": "model",
              "model_missing": "model", "model_rejected": "model", "config": "config"}.get(cause, "retry")
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
