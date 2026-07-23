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

import json
import os
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import httpx

from . import cloudsync, storage, workflows
from .config import CONFIG_PATH, KEYCHAIN_SERVICE, Config, load_secrets
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
    OPENAI_API_BASE,
    OPENAI_KEYS_URL,
    OPENAI_MODELS_PATH,
)


def _ok(msg: str) -> None:
    print(f"[ OK ] {msg}")


def _fail(msg: str) -> None:
    print(f"[FAIL] {msg}")


def _warn(msg: str) -> None:
    print(f"[WARN] {msg}")


def _info(msg: str) -> None:
    print(f"       {msg}")


# ---------- secrets (macOS Keychain) ----------------------------------------

def check_secrets() -> dict[str, bool]:
    """Verify the required API tokens are present in the macOS Keychain (SEC8). Returns
    {name: present-and-non-empty}.

    HF_TOKEN was required when diarization ran on pyannote (HF-gated TOS).
    Diarization now runs in Swift via FluidAudio, whose models live on a
    public HuggingFace mirror that doesn't require auth. HF_TOKEN remains
    optional and is surfaced when present so existing setups don't get a
    confusing missing-secret warning.
    """
    print(f"\n== secrets ==  (macOS Keychain: {KEYCHAIN_SERVICE})")
    required = ("ANTHROPIC_API_KEY", "NOTION_TOKEN")
    optional = ("HF_TOKEN", "OPENAI_API_KEY")
    _optional_reason = {
        "HF_TOKEN": "only used if you opt back into pyannote",
        "OPENAI_API_KEY": "only used when summarization.backend = openai",
    }
    load_secrets()
    presence: dict[str, bool] = {}
    for key in required + optional:
        val = os.environ.get(key, "")
        present = bool(val) and not val.startswith(("YOUR_", "PUT_", "REPLACE_", "<"))
        presence[key] = present
        if present:
            prefix = val[:7] + "…" if len(val) > 8 else "(short)"
            _ok(f"{key} present ({prefix})")
        elif key in required:
            _fail(f"{key} not in Keychain; set it in the daemon's Preferences or re-run scripts/install.sh")
        else:
            _info(f"{key} not set (optional — {_optional_reason.get(key, 'optional')})")
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


# ---------- claude CLI (PROV1) ---------------------------------------------

def check_claude_cli(cfg: Config | None) -> None:
    """Preflight the `claude_cli` backend: binary presence + version, no live
    call (auth rides Claude Code and is verified on first use). A local probe, so
    it is egress-free and runs even under regulated_mode."""
    print("\n== claude CLI (claude_cli backend) ==")
    from .provider_claude_cli import find_claude
    backend = cfg.summarization.backend if cfg else "?"
    binary = find_claude()
    if binary is None:
        if backend == "claude_cli":
            _fail("`claude` not found but summarization.backend = claude_cli; install Claude Code")
        else:
            _info("`claude` not found (only needed when summarization.backend = claude_cli)")
        return
    version: str | None = None
    try:
        out = subprocess.run([binary, "--version"], capture_output=True, text=True, timeout=10)
        if out.returncode == 0:
            version = (out.stdout or out.stderr or "").strip().splitlines()[0] or None
    except (OSError, subprocess.SubprocessError):
        version = None
    _ok(f"`claude` found at {binary}" + (f" ({version})" if version else ""))
    _info("no API key needed; claude_cli uses your Claude Code login, verified on first use")
    if cfg is not None and cfg.modes.regulated_mode and backend == "claude_cli":
        _warn("regulated_mode forces local; claude_cli would be overridden to on-device")


# ---------- OpenAI (PROV1) -------------------------------------------------

def check_openai(present: bool, cfg: Config | None) -> None:
    """Live check for the `openai` backend: an unbilled `GET /models` confirms the
    key. Skipped under regulated_mode by the caller (it egresses)."""
    print("\n== OpenAI API (openai backend) ==")
    backend = cfg.summarization.backend if cfg else "?"
    if not present:
        if backend == "openai":
            _fail("OPENAI_API_KEY missing but summarization.backend = openai — skipping live check")
        else:
            _info("OPENAI_API_KEY not set (only needed when summarization.backend = openai)")
        _info(f"create a key at: {OPENAI_KEYS_URL}")
        return
    api_key = os.environ["OPENAI_API_KEY"]
    try:
        resp = httpx.get(
            f"{OPENAI_API_BASE}{OPENAI_MODELS_PATH}",
            headers={"Authorization": f"Bearer {api_key}"},
            timeout=10.0,
        )
    except httpx.HTTPError as e:
        _fail(f"network error reaching api.openai.com: {e}")
        return
    if resp.status_code == 200:
        _ok("API key valid — model list reachable")
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


# ---------- local summarization stack (LOCAL4) ------------------------------

def _estimate_model_gb(model_id: str) -> float | None:
    """Rough resident-memory / download estimate for a 4-bit MLX chat model,
    parsed from the parameter count in its repo id (`...-7B-...` -> 7B).
    ~0.62 GB per billion params covers 4-bit weights plus runtime overhead and
    matches the measured ~4.3 GB for the 7B. None when the size is unparseable.
    """
    m = re.search(r"(\d+(?:\.\d+)?)\s*[bB]\b", model_id)
    if not m:
        return None
    try:
        params_b = float(m.group(1))
    except ValueError:
        return None
    return round(params_b * 0.62, 1)


def _physical_ram_gb() -> float | None:
    """Total physical RAM in GB. `sysctl hw.memsize` on macOS, os.sysconf fallback."""
    try:
        out = subprocess.run(
            ["/usr/sbin/sysctl", "-n", "hw.memsize"],
            capture_output=True, text=True, timeout=5,
        )
        if out.returncode == 0 and out.stdout.strip().isdigit():
            return round(int(out.stdout.strip()) / (1024 ** 3), 1)
    except (OSError, subprocess.SubprocessError):
        pass
    try:
        return round(os.sysconf("SC_PHYS_PAGES") * os.sysconf("SC_PAGE_SIZE") / (1024 ** 3), 1)
    except (ValueError, OSError):
        return None


def _free_disk_gb(path: Path) -> float | None:
    try:
        return round(shutil.disk_usage(path).free / (1024 ** 3), 1)
    except OSError:
        return None


def check_local_stack(cfg: Config | None, workflows_dir: Path | None = None) -> None:
    """Preflight the on-device summarization stack (LOCAL4): mlx availability,
    the model cache, and RAM/disk headroom against the chosen model. A clear
    refuse-with-explanation here beats a first-run OOM inside mlx_lm.server.

    Runs whenever the on-device stack can be reached: a local / auto global
    backend, regulated_mode, OR any workflow that resolves to local (UX21). A
    workflow-level local / NDA backend under a global anthropic backend still hits
    the stack on its first meeting, so skipping here would hide a missing model
    from exactly the setup that trips over it.
    """
    print("\n== local summarization stack ==")
    if cfg is None:
        _warn("config did not load; skipping local-stack checks")
        return
    backend = cfg.summarization.backend
    local_workflows = workflows.local_backend_workflow_names(workflows_dir)
    stack_reachable = (
        backend in {"local", "auto"} or cfg.modes.regulated_mode or bool(local_workflows)
    )
    if not stack_reachable:
        _info(f"backend = {backend!r}, regulated_mode off, no local workflow; local stack not used (skipping)")
        return
    if backend not in {"local", "auto"} and not cfg.modes.regulated_mode and local_workflows:
        _info(f"global backend = {backend!r}, but a workflow forces local: {', '.join(local_workflows)}")

    # `find_spec` verifies mlx is installed without importing heavy Metal here.
    from importlib.util import find_spec
    if find_spec("mlx_lm") is not None and find_spec("mlx") is not None:
        _ok("mlx / mlx_lm installed")
    else:
        _fail("mlx_lm not installed; the local backend cannot run")
        _info("reinstall the pipeline venv: scripts/install.sh (or cd pipeline && uv sync)")
        _info('non-Apple-Silicon hosts have no MLX; use summarization.backend = "anthropic"')

    model_id = cfg.summarization.local_model
    _info(f"model = {model_id}")
    need_gb = _estimate_model_gb(model_id)

    from .prefetch_model import _bytes_on_disk, hf_cache_dir
    cache_dir = hf_cache_dir(model_id)
    cached_gb = round(_bytes_on_disk(cache_dir) / (1024 ** 3), 1)
    if cached_gb > 0:
        _ok(f"model cache present (~{cached_gb} GB at {cache_dir})")
    else:
        est = f"~{need_gb} GB" if need_gb else "several GB"
        _info(f"model not cached yet; first local run downloads {est} (resumable, prefetched by the daemon)")

    ram_gb = _physical_ram_gb()
    if ram_gb is None:
        _warn("could not determine physical RAM")
    elif need_gb is None:
        _info(f"physical RAM = {ram_gb} GB (model size unknown; cannot judge headroom)")
    elif ram_gb < need_gb:
        _fail(f"physical RAM {ram_gb} GB < the model's ~{need_gb} GB resident; this model will not fit")
        _info("pick a smaller preset in Preferences -> Pipeline (Small 3B / Recommended 7B)")
    elif ram_gb < need_gb + 4:
        _warn(f"physical RAM {ram_gb} GB leaves little headroom over the model's ~{need_gb} GB; OOM risk under load")
        _info("close memory-heavy apps, or pick a smaller preset")
    else:
        _ok(f"physical RAM {ram_gb} GB comfortably fits the model's ~{need_gb} GB")

    if need_gb is not None and cached_gb == 0:
        probe = cache_dir.parent if cache_dir.parent.exists() else Path.home()
        free_gb = _free_disk_gb(probe)
        if free_gb is None:
            _warn("could not determine free disk space")
        elif free_gb < need_gb:
            _fail(f"free disk {free_gb} GB < the ~{need_gb} GB download; free space before switching to local")
        elif free_gb < need_gb * 1.5:
            _warn(f"free disk {free_gb} GB is tight for the ~{need_gb} GB download plus extraction headroom")
        else:
            _ok(f"free disk {free_gb} GB fits the ~{need_gb} GB download")


def check_local_server(cfg: Config | None = None, home: Path | None = None) -> None:
    """Report on the local model server: orphans (LOCAL10) and identity (LOCAL11).

    Two independent questions about the same process, so both run: an orphan can
    be serving the right model, and the right owner can be serving the wrong one.
    """
    print("\n== local model server ==")
    _report_local_server_orphan(home)
    _report_local_server_identity(cfg, home)


def _report_local_server_orphan(home: Path | None) -> None:
    """An `mlx_lm.server` that outlived the `mp` that spawned it (LOCAL10).

    The server detaches into its own session so a signal aimed at `mp`'s process
    group misses it; when the daemon's watchdog SIGKILLs a wedged `run-all`, the
    parent's idle timer dies with it and a multi-GB server is left resident. The
    daemon reaps one at launch, so a report here means either the daemon has not
    restarted since, or the orphan appeared in this session.
    """
    from . import local_server

    marker = local_server.read_marker(home)
    if marker is None:
        _ok("no detached mlx_lm.server is registered")
        return

    orphan = local_server.orphaned_server(home)
    if orphan is None:
        pid = marker.get("pid")
        _ok(f"mlx_lm.server (pid {pid}) is owned by a live `mp` process")
        return

    pid = orphan.get("pid")
    model = orphan.get("model", "unknown")
    spawned = orphan.get("spawned_at")
    age = ""
    if isinstance(spawned, (int, float)):
        hours = max(0.0, (time.time() - spawned) / 3600.0)
        age = f", up {hours:.1f}h" if hours >= 1 else f", up {hours * 60:.0f}m"
    _warn(f"orphaned mlx_lm.server: pid {pid}, model {model}{age}")
    _info("its `mp` process was killed (usually the pipeline watchdog) and it holds several GB of RAM")
    _info("restart MeetingPipe to reap it, or: kill " + str(pid))


def _report_local_server_identity(cfg: Config | None, home: Path | None) -> None:
    """Does the listening server serve what config asks for (LOCAL11)?

    The case worth catching is a *warm* server: `LocalSummaryClient` reuses one on
    a bare HTTP 200, and the daemon's launch-time preloader keeps one resident for
    the whole session, so flipping `local_model` or `local_adapter_path` used to
    leave the old weights answering every run with nothing on screen to say so.
    A mismatch here is also the precondition for trusting a LOCAL9 adapter A/B:
    without it, "the adapter did not help" and "the adapter never served" look
    identical.

    Silent when nothing is listening (the common case: no local backend in use).
    """
    from . import local_server
    from .config import parse_local_endpoint

    if cfg is None:
        return
    try:
        _, port = parse_local_endpoint(cfg.summarization.local_endpoint)
    except ValueError as e:
        _warn(f"summarization.local_endpoint is unusable: {e}")
        return

    identity = local_server.served_identity(port, home)
    if identity is None:
        _info(f"nothing is serving on port {port}; the next local run starts its own server")
        return

    want_model = cfg.summarization.local_model
    want_adapter = cfg.summarization.local_adapter_path or ""
    if identity.matches(model=want_model, adapter_path=want_adapter):
        _ok(f"server on port {port} serves the configured {identity.describe()}")
        return

    want = want_model + (f" + adapter {want_adapter}" if want_adapter else "")
    _warn(f"server on port {port} serves {identity.describe()}, but config asks for {want}")
    _info("summaries produced now are attributed to the served model, not the configured one")
    _info("a `mp`-spawned server is replaced automatically on the next run; "
          f"for the daemon's warm server, quit and reopen MeetingPipe (or: kill {identity.pid})")


def check_storage(cfg: Config | None, home: Path | None = None) -> None:
    """Report what meeting-pipe is holding on disk (STOR1).

    Stereo WAV runs about 0.7 GB per recorded hour, so the library is the
    product's largest liability and the number nobody had a way to see. The two
    caches below it are rebuildable and safe to delete; the kept originals are
    reaped on a 30-day window by the daemon.

    `home` is injectable so tests can scan a `tmp_path` tree instead of the real
    HuggingFace cache.
    """
    print("\n== storage ==")
    if cfg is None:
        _warn("config did not load; skipping storage checks")
        return

    library = cfg.recording.output_dir
    _info(f"library = {library}")
    if not library.exists():
        _info("library does not exist yet; nothing recorded so far")
    library_bytes = storage.bytes_on_disk(library)
    digests_bytes = storage.bytes_on_disk(storage.digests_dir(library))
    _ok(f"library {storage.human_bytes(library_bytes)} (digests {storage.human_bytes(digests_bytes)})")

    originals_bytes = storage.bytes_on_disk(storage.originals_dir(home))
    if originals_bytes:
        _info(f"kept originals {storage.human_bytes(originals_bytes)} (reaped after 30 days)")

    caches = [
        ("waveform peaks", storage.bytes_on_disk(storage.waveform_cache_dir(home))),
        ("model cache", storage.bytes_on_disk(storage.hf_hub_root(home))),
    ]
    for label, size in caches:
        if size:
            _info(f"{label} {storage.human_bytes(size)} (rebuildable)")

    free = storage.free_bytes(library)
    if free is None:
        _warn("could not determine free disk space")
    else:
        # Roughly 14 hours of recording. Below that, an unattended day of meetings
        # can plausibly fill the disk before anyone looks at doctor again.
        low_water = 10 * 1000 ** 3
        if free < low_water:
            _warn(f"free disk {storage.human_bytes(free)}; set an audio retention policy on a workflow, or free space")
        else:
            _ok(f"free disk {storage.human_bytes(free)}")

    check_last_backup(home=home)
    check_library_sync(cfg, home=home)


def check_last_backup(home: Path | None = None, now: datetime | None = None) -> None:
    """How long since `mp backup` last ran (STOR2).

    Informational, never a failure: the owner may well be relying on Time Machine.
    A missing marker means no `mp backup` has run on this Mac, which is worth
    saying once rather than nagging about.
    """
    marker = storage.backup_marker(home)
    try:
        data = json.loads(marker.read_text(encoding="utf-8"))
        taken = datetime.fromisoformat(data["at"])
    except (OSError, ValueError, KeyError):
        _info("no `mp backup` has run on this Mac (see the README backup runbook)")
        return

    now = now or datetime.now(timezone.utc)
    if taken.tzinfo is None:
        taken = taken.replace(tzinfo=timezone.utc)
    days = (now - taken).days
    when = "today" if days == 0 else f"{days} day{'s' if days != 1 else ''} ago"
    suffix = "" if data.get("audio_included", True) else ", without recordings"
    _info(f"last backup {when}{suffix}: {data.get('archive', marker)}")


def _synced_roots(cfg: Config, home: Path | None) -> list[tuple[str, cloudsync.SyncProvider]]:
    """Every on-disk root meeting-pipe writes to that a sync client owns.

    Not just the recordings dir: `digests/` and the filesystem sink's `published/`
    hold generated summaries, and the daemon's assisted move deliberately relocates
    only the recordings and digests. Deduped by sync root, since the three are
    usually siblings inside one synced tree and saying so three times is noise.
    """
    library = cfg.recording.output_dir
    roots: list[tuple[str, Path]] = [
        ("library", library),
        ("digests", storage.digests_dir(library)),
    ]
    if "filesystem" in cfg.output.sinks:
        # `filesystem.output_dir` is a raw string with a possible `~`;
        # `detect_sync_provider` expands it.
        roots.append(("published summaries", Path(cfg.filesystem.output_dir)))

    found: list[tuple[str, cloudsync.SyncProvider]] = []
    seen: set[Path] = set()
    for label, path in roots:
        provider = cloudsync.detect_sync_provider(path, home=home)
        if provider is None or provider.root in seen:
            continue
        seen.add(provider.root)
        found.append((label, provider))
    return found


def check_library_sync(
    cfg: Config,
    home: Path | None = None,
    workflows_dir: Path | None = None,
) -> None:
    """Is the library silently uploading to a cloud provider? (SEC12)

    An OS-level hole in the zero-egress promise: `egress_guard` clamps this
    process, but it cannot stop iCloud from syncing the WAV that was just written.
    The default `~/Documents/Meetings/` sits inside iCloud's Desktop & Documents
    scope, so this is the common case, not the exotic one.

    A synced root is a WARN. A synced root under `regulated_mode`, or on a Mac with
    any NDA workflow, is a FAIL: those modes exist precisely to promise that
    nothing leaves the machine.

    `main()` still returns 0. Doctor is a diagnostic, not a gate, and this one
    exception is not worth breaking every caller that relies on that contract.
    Grep for `[FAIL]`.
    """
    synced = _synced_roots(cfg, home)
    if not synced:
        _ok("no meeting data is inside a cloud-sync folder")
        return

    nda_workflows = workflows.nda_workflow_names(workflows_dir)
    zero_egress_promised = cfg.modes.regulated_mode or bool(nda_workflows)

    for label, provider in synced:
        if zero_egress_promised:
            _fail(f"{label} is synced to {provider.name}, and this Mac promises zero egress")
        else:
            _warn(f"{label} is synced to {provider.name}; this data leaves your Mac")
        _info(provider.evidence)

    if zero_egress_promised:
        if cfg.modes.regulated_mode:
            _info("regulated_mode is ON")
        if nda_workflows:
            _info(f"NDA workflows: {', '.join(nda_workflows)}")
        _info("summarization stays on-device, but the recording is uploaded after it is written")

    _info("fix: Preferences > Storage > Move library..., and pick a folder outside the synced tree")
    if any(p.name == "iCloud Drive" for _, p in synced):
        _info("     or turn off System Settings > [your name] > iCloud > Desktop & Documents Folders")


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
        print("Validates secrets, config, storage, the claude_cli binary, and live access to Anthropic / OpenAI / Notion / HuggingFace.")
        return 0

    print("mp doctor — preflight check\n")
    presence = check_secrets()
    cfg = check_config()
    check_ml_runtimes()
    check_local_stack(cfg)
    check_local_server()
    check_storage(cfg)
    # claude_cli is a local binary probe (no egress), so it runs regardless of
    # regulated_mode; the live cloud probes below are the ones that must not fire
    # under zero-egress.
    check_claude_cli(cfg)
    # SEC11: under regulated_mode the pipeline is zero-egress, so doctor must not
    # reach any cloud API either. Skip the live Anthropic / OpenAI / Notion /
    # HuggingFace probes and say why, instead of silently pinging out.
    if cfg is not None and cfg.modes.regulated_mode:
        print("\n== cloud services ==")
        _info("regulated_mode is ON; skipping the live Anthropic / OpenAI / Notion / HuggingFace probes")
        _info("doctor stays zero-egress under regulated mode: no transcript or token leaves this Mac")
    else:
        check_anthropic(presence["ANTHROPIC_API_KEY"])
        check_openai(presence["OPENAI_API_KEY"], cfg)
        check_notion(presence["NOTION_TOKEN"], cfg)
        check_huggingface(presence["HF_TOKEN"])
    check_screen_recording()

    print("\nDone. Re-run after fixing each [FAIL] above.")
    # Exit 0 even on partial failures — this is a diagnostic tool, not a gate.
    # Caller can grep for "[FAIL]" if they want to fail a CI step on it.
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main(sys.argv[1:]))
