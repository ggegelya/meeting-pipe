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
import re
import sys
from pathlib import Path

import httpx

from .config import CONFIG_PATH, SECRETS_PATH, Config, load_secrets
from .endpoints import (
    ANTHROPIC_API_BASE,
    ANTHROPIC_API_VERSION,
    ANTHROPIC_CONSOLE_KEYS_URL,
    ANTHROPIC_DOCTOR_PROBE_MODEL,
    ANTHROPIC_MESSAGES_PATH,
    HF_API_WHOAMI,
    HF_TOKENS_URL,
    NOTION_API_BASE,
    NOTION_API_VERSION,
    NOTION_INTEGRATIONS_URL,
)


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
    declares the required keys. Returns {name: present-and-non-empty}.

    HF_TOKEN was required when diarization ran on pyannote (HF-gated TOS).
    Diarization now runs in Swift via FluidAudio, whose models live on a
    public HuggingFace mirror that doesn't require auth. HF_TOKEN remains
    optional and is surfaced when present so existing setups don't get a
    confusing missing-secret warning.
    """
    print(f"\n== secrets file ==  ({SECRETS_PATH})")
    required = ("ANTHROPIC_API_KEY", "NOTION_TOKEN")
    optional = ("HF_TOKEN",)
    all_keys = required + optional
    if not SECRETS_PATH.exists():
        _fail("secrets.env missing — copy from scripts/install.sh prompt or create manually")
        return {k: False for k in all_keys}

    mode = SECRETS_PATH.stat().st_mode & 0o777
    if mode != 0o600:
        _warn(f"file mode is 0o{mode:o}; recommended 0o600 (run: chmod 600 {SECRETS_PATH})")
    else:
        _ok(f"file exists, mode 0o{mode:o}")

    load_secrets()
    presence: dict[str, bool] = {}
    for key in all_keys:
        val = os.environ.get(key, "")
        present = bool(val) and not val.startswith(("YOUR_", "PUT_", "REPLACE_", "<"))
        presence[key] = present
        if present:
            prefix = val[:7] + "…" if len(val) > 8 else "(short)"
            _ok(f"{key} present ({prefix})")
        elif key in required:
            _fail(f"{key} is empty or placeholder")
        else:
            _info(f"{key} not set (optional — only used if you opt back into pyannote)")
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
    _info(f"output.sinks = {cfg.output.sinks}")
    _info(f"summarization.model = {cfg.summarization.model}")
    _info(f"summarization.backend = {cfg.summarization.backend}")
    if cfg.summarization.backend in {"local", "auto"}:
        _info(f"summarization.local_model = {cfg.summarization.local_model}")
        _info(f"summarization.local_endpoint = {cfg.summarization.local_endpoint}")
    _info(f"notion.database_id = {cfg.notion.database_id or '(empty)'}")
    _info(f"modes.regulated_mode = {cfg.modes.regulated_mode}")
    if not cfg.notion.database_id and not cfg.modes.regulated_mode:
        _warn("notion.database_id is empty AND regulated_mode is off — Notion publish will fail")
    if cfg.modes.regulated_mode and cfg.summarization.backend != "local":
        _info(
            f"regulated_mode=true overrides summarization.backend "
            f"({cfg.summarization.backend}); the local backend is forced for zero egress"
        )
    return cfg


# ---------- Anthropic ------------------------------------------------------

def check_anthropic(present: bool) -> None:
    print("\n== Anthropic API ==")
    if not present:
        _fail("ANTHROPIC_API_KEY missing — skipping live check")
        _info(f"get one at: {ANTHROPIC_CONSOLE_KEYS_URL}")
        return
    api_key = os.environ["ANTHROPIC_API_KEY"]
    try:
        # Minimal billable call. We pin to a cheap model so this costs ~nothing.
        resp = httpx.post(
            f"{ANTHROPIC_API_BASE}{ANTHROPIC_MESSAGES_PATH}",
            headers={
                "x-api-key": api_key,
                "anthropic-version": ANTHROPIC_API_VERSION,
                "content-type": "application/json",
            },
            json={
                "model": ANTHROPIC_DOCTOR_PROBE_MODEL,
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
        _info(f"create an integration at: {NOTION_INTEGRATIONS_URL}")
        return
    token = os.environ["NOTION_TOKEN"]
    headers = {
        "Authorization": f"Bearer {token}",
        "Notion-Version": NOTION_API_VERSION,
    }
    try:
        me = httpx.get(f"{NOTION_API_BASE}/users/me", headers=headers, timeout=10.0)
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
        db = httpx.get(f"{NOTION_API_BASE}/databases/{db_id}", headers=headers, timeout=10.0)
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


# ---------- ML runtimes ----------------------------------------------------

def check_ml_runtimes() -> None:
    """ASR + diarization run in Swift (FluidAudio); the Python pipeline
    only summarizes and publishes. Nothing to probe here beyond the
    Apple Silicon presence check that surfaces in other doctor sections.
    """
    print("\n== ML runtimes ==")
    _info("ASR + diarization handled by the Swift daemon (FluidAudio).")
    _info("Python pipeline runs summarize + publish only; no MLX deps here.")


def check_huggingface(present: bool) -> None:
    """Optional HF_TOKEN check. Kept for users who deliberately opt back
    into a pyannote-based diarization workflow. The default pipeline no
    longer touches Hugging Face.
    """
    print("\n== HuggingFace (optional — only used if you opt back into pyannote) ==")
    if not present:
        _info("HF_TOKEN not set; the default FluidAudio pipeline does not need it")
        _info(f"create a Read token at {HF_TOKENS_URL} only if you re-enable pyannote")
        return
    token = os.environ["HF_TOKEN"]
    try:
        whoami = httpx.get(
            HF_API_WHOAMI,
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


# ---------- Screen Recording TCC -------------------------------------------

# Regex matching the daemon's recorder.log line format when SCStream init
# fails because Screen Recording permission was declined or never granted.
# The recorder writes either of these phrasings depending on which TCC
# probe failed first (prewarm vs. start). Both indicate the same root
# cause from the user's perspective.
_TCC_DENIAL_RE = re.compile(
    r"(SCStream start failed|SCShareableContent prewarm failed):"
    r".*declined TCCs",
    re.IGNORECASE,
)

# Regex matching a successful SCStream start. Used to confirm that any prior
# denial was resolved on a more recent run — newest-line-wins.
_TCC_OK_RE = re.compile(r"SCStream start", re.IGNORECASE)

_RECORDER_LOG = Path(os.path.expanduser("~/Library/Logs/MeetingPipe/recorder.log"))


def _scan_recorder_log_for_tcc(log_path: Path = _RECORDER_LOG) -> str | None:
    """Return the most recent TCC-related line from recorder.log.

    Walks lines newest-first and stops at the first match. Returns None when
    the log doesn't exist (daemon never ran) or contains no TCC lines.
    Visible for unit testing.
    """
    if not log_path.exists():
        return None
    try:
        text = log_path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    for line in reversed(text.splitlines()):
        if _TCC_DENIAL_RE.search(line) or _TCC_OK_RE.search(line):
            return line
    return None


def check_screen_recording() -> None:
    """Best-effort TCC check: parse the daemon's recorder.log for the most
    recent SCStream outcome.

    We don't call into ScreenCaptureKit directly because doctor.py is pure
    Python — adding a Swift helper just for this is more code than the
    failure mode warrants. Reading the daemon's own log is reliable
    (recorder.log writes a one-liner on every recording start) and points
    the user at the exact remediation when permission is missing.
    """
    print("\n== Screen Recording (system audio capture) ==")
    line = _scan_recorder_log_for_tcc()
    if line is None:
        _warn("recorder.log absent or has no SCStream events yet — cannot verify")
        _info(f"expected at {_RECORDER_LOG}")
        _info("run a quick test recording (⌃⌥M) and re-run mp doctor")
        return
    if _TCC_DENIAL_RE.search(line):
        _fail("Screen Recording permission was DECLINED for MeetingPipe")
        _info("recordings will be MIC-ONLY — other participants' voices won't be captured,")
        _info("which means diarization will only ever see one speaker.")
        _info("Fix: System Settings ▸ Privacy & Security ▸ Screen Recording → enable MeetingPipe,")
        _info("     then: launchctl kickstart -k gui/$(id -u)/com.meetingpipe.daemon")
        _info(f"latest recorder.log line: {line.strip()}")
        return
    _ok("most recent SCStream start did not log a TCC denial")


# ---------- entry point ----------------------------------------------------

def main(argv: list[str]) -> int:
    if argv and argv[0] in {"-h", "--help"}:
        print("usage: mp doctor")
        print("Validates secrets, config, and live access to Anthropic / Notion / HuggingFace.")
        return 0

    print("mp doctor — preflight check\n")
    presence = check_secrets_file()
    cfg = check_config()
    check_ml_runtimes()
    check_anthropic(presence["ANTHROPIC_API_KEY"])
    check_notion(presence["NOTION_TOKEN"], cfg)
    check_huggingface(presence["HF_TOKEN"])
    check_screen_recording()

    print("\nDone. Re-run after fixing each [FAIL] above.")
    # Exit 0 even on partial failures — this is a diagnostic tool, not a gate.
    # Caller can grep for "[FAIL]" if they want to fail a CI step on it.
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main(sys.argv[1:]))
