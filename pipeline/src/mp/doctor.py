"""`mp doctor` — preflight check for secrets, config, and external services.

Each check is independent: a failure in one does not abort the rest, so the
user gets the full picture in a single run. Output is plain text with simple
[ OK ] / [FAIL] / [WARN] markers; greppable, readable, no color codes.

Network checks are all bounded: HEAD/GET with a 10s timeout, never any data
write. We do not bill the Anthropic API for tokens — the credential check
uses the messages endpoint with `max_tokens=1` (cheapest possible request,
~$0.000003).
"""
from __future__ import annotations

import os
import sys
from pathlib import Path
from typing import Any

import httpx

from .config import CONFIG_PATH, SECRETS_PATH, Config, load_secrets


def _ok(msg: str) -> None:
    print(f"[ OK ] {msg}")


def _fail(msg: str) -> None:
    print(f"[FAIL] {msg}")


def _warn(msg: str) -> None:
    print(f"[WARN] {msg}")


def _info(msg: str) -> None:
    print(f"       {msg}")


# ---------- secrets file ----------------------------------------------------

def check_secrets_file() -> dict[str, bool]:
    """Verify ~/.config/meeting-pipe/secrets.env exists, has 0600 perms, and
    declares the three keys. Returns {name: present-and-non-empty}."""
    print(f"\n== secrets file ==  ({SECRETS_PATH})")
    if not SECRETS_PATH.exists():
        _fail("secrets.env missing — copy from scripts/install.sh prompt or create manually")
        return {"ANTHROPIC_API_KEY": False, "NOTION_TOKEN": False, "HF_TOKEN": False}

    mode = SECRETS_PATH.stat().st_mode & 0o777
    if mode != 0o600:
        _warn(f"file mode is 0o{mode:o}; recommended 0o600 (run: chmod 600 {SECRETS_PATH})")
    else:
        _ok(f"file exists, mode 0o{mode:o}")

    load_secrets()
    presence: dict[str, bool] = {}
    for key in ("ANTHROPIC_API_KEY", "NOTION_TOKEN", "HF_TOKEN"):
        val = os.environ.get(key, "")
        present = bool(val) and not val.startswith(("YOUR_", "PUT_", "REPLACE_", "<"))
        presence[key] = present
        if present:
            # Show prefix only — never print the secret in full.
            prefix = val[:7] + "…" if len(val) > 8 else "(short)"
            _ok(f"{key} present ({prefix})")
        else:
            _fail(f"{key} is empty or placeholder")
    return presence


# ---------- config ----------------------------------------------------------

def check_config() -> Config | None:
    print(f"\n== config ==  ({CONFIG_PATH})")
    if not CONFIG_PATH.exists():
        _warn("config.toml missing — using all defaults")
        return Config()
    try:
        cfg = Config.load()
    except Exception as e:
        _fail(f"config parse error: {e}")
        return None
    _ok(f"loaded {CONFIG_PATH}")
    _info(f"recording.output_dir = {cfg.recording.output_dir}")
    _info(f"transcription.model = {cfg.transcription.model}, language = {cfg.transcription.language}")
    _info(f"summarization.model = {cfg.summarization.model}")
    _info(f"notion.database_id = {cfg.notion.database_id or '(empty)'}")
    _info(f"modes.regulated_mode = {cfg.modes.regulated_mode}")
    if not cfg.notion.database_id and not cfg.modes.regulated_mode:
        _warn("notion.database_id is empty AND regulated_mode is off — Notion publish will fail")
    return cfg


# ---------- Anthropic ------------------------------------------------------

def check_anthropic(present: bool) -> None:
    print("\n== Anthropic API ==")
    if not present:
        _fail("ANTHROPIC_API_KEY missing — skipping live check")
        _info("get one at: https://console.anthropic.com/settings/keys")
        return
    api_key = os.environ["ANTHROPIC_API_KEY"]
    try:
        # Minimal billable call. We pin to a cheap model so this costs ~nothing.
        resp = httpx.post(
            "https://api.anthropic.com/v1/messages",
            headers={
                "x-api-key": api_key,
                "anthropic-version": "2023-06-01",
                "content-type": "application/json",
            },
            json={
                "model": "claude-haiku-4-5-20251001",
                "max_tokens": 1,
                "messages": [{"role": "user", "content": "ping"}],
            },
            timeout=10.0,
        )
    except httpx.HTTPError as e:
        _fail(f"network error reaching api.anthropic.com: {e}")
        return
    if resp.status_code == 200:
        _ok("API key valid — billable account, model access confirmed")
    elif resp.status_code in (401, 403):
        _fail(f"key rejected: HTTP {resp.status_code} — {resp.text[:200]}")
    elif resp.status_code == 429:
        _warn("key valid but rate-limited right now (HTTP 429)")
    else:
        _warn(f"unexpected status {resp.status_code}: {resp.text[:200]}")


# ---------- Notion ---------------------------------------------------------

def check_notion(present: bool, cfg: Config | None) -> None:
    print("\n== Notion API ==")
    if not present:
        _fail("NOTION_TOKEN missing — skipping live check")
        _info("create an integration at: https://www.notion.so/profile/integrations")
        return
    token = os.environ["NOTION_TOKEN"]
    headers = {
        "Authorization": f"Bearer {token}",
        "Notion-Version": "2022-06-28",
    }
    try:
        me = httpx.get("https://api.notion.com/v1/users/me", headers=headers, timeout=10.0)
    except httpx.HTTPError as e:
        _fail(f"network error reaching api.notion.com: {e}")
        return
    if me.status_code != 200:
        _fail(f"token rejected: HTTP {me.status_code} — {me.text[:200]}")
        return
    name = (me.json().get("bot", {}) or {}).get("workspace_name") or me.json().get("name") or "(unnamed)"
    _ok(f"token valid — integration: {name}")

    if not cfg or not cfg.notion.database_id:
        _warn("skipping database check — notion.database_id is empty in config.toml")
        return
    db_id = cfg.notion.database_id
    try:
        db = httpx.get(f"https://api.notion.com/v1/databases/{db_id}", headers=headers, timeout=10.0)
    except httpx.HTTPError as e:
        _fail(f"network error fetching database: {e}")
        return
    if db.status_code == 200:
        title_blocks = db.json().get("title", [])
        title = "".join(b.get("plain_text", "") for b in title_blocks) or "(untitled)"
        _ok(f"database reachable — title: {title!r}")
    elif db.status_code == 404:
        _fail(f"database {db_id} not found OR integration not connected to it")
        _info("open the database in Notion → '…' menu → Connections → add your integration")
    else:
        _fail(f"database fetch failed: HTTP {db.status_code} — {db.text[:200]}")


# ---------- HuggingFace ----------------------------------------------------

def check_huggingface(present: bool) -> None:
    print("\n== HuggingFace (pyannote model gate) ==")
    if not present:
        _warn("HF_TOKEN missing — diarization will fail at first model download")
        _info("create a Read token at: https://huggingface.co/settings/tokens")
        return
    token = os.environ["HF_TOKEN"]
    try:
        whoami = httpx.get(
            "https://huggingface.co/api/whoami-v2",
            headers={"Authorization": f"Bearer {token}"},
            timeout=10.0,
        )
    except httpx.HTTPError as e:
        _fail(f"network error reaching huggingface.co: {e}")
        return
    if whoami.status_code != 200:
        _fail(f"token rejected: HTTP {whoami.status_code} — {whoami.text[:200]}")
        return
    _ok(f"token valid — user: {whoami.json().get('name', '(unknown)')}")

    # Probe gated repos. /api/models/{repo} returns 401 if TOS not accepted,
    # 200 if accepted (or repo public). The diarization pipeline pulls both.
    for repo in ("pyannote/speaker-diarization-3.1", "pyannote/segmentation-3.0"):
        try:
            r = httpx.get(
                f"https://huggingface.co/api/models/{repo}",
                headers={"Authorization": f"Bearer {token}"},
                timeout=10.0,
            )
        except httpx.HTTPError as e:
            _fail(f"{repo}: network error: {e}")
            continue
        if r.status_code == 200:
            _ok(f"{repo}: TOS accepted, downloadable")
        elif r.status_code in (401, 403):
            _fail(f"{repo}: TOS NOT accepted (HTTP {r.status_code})")
            _info(f"open https://huggingface.co/{repo} in a browser, click Agree")
        else:
            _warn(f"{repo}: unexpected status {r.status_code}")


# ---------- entry point ----------------------------------------------------

def main(argv: list[str]) -> int:
    if argv and argv[0] in {"-h", "--help"}:
        print("usage: mp doctor")
        print("Validates secrets, config, and live access to Anthropic / Notion / HuggingFace.")
        return 0

    print("mp doctor — preflight check\n")
    presence = check_secrets_file()
    cfg = check_config()
    check_anthropic(presence["ANTHROPIC_API_KEY"])
    check_notion(presence["NOTION_TOKEN"], cfg)
    check_huggingface(presence["HF_TOKEN"])

    print("\nDone. Re-run after fixing each [FAIL] above.")
    # Exit 0 even on partial failures — this is a diagnostic tool, not a gate.
    # Caller can grep for "[FAIL]" if they want to fail a CI step on it.
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main(sys.argv[1:]))
