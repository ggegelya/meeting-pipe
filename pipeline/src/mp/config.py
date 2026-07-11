"""Pydantic settings model mirroring config.example.toml.

Loaded once at CLI start. Same TOML lives in the daemon (Swift) and pipeline (Python),
which is fine because both are read-only consumers — config is owned by the user.
"""
from __future__ import annotations

import os
import sys
import tomllib
from pathlib import Path
from typing import Literal

from pydantic import BaseModel, Field


def _expand(p: str) -> Path:
    return Path(os.path.expanduser(p))


CONFIG_PATH = _expand("~/.config/meeting-pipe/config.toml")

# SEC8: API tokens live in the macOS login Keychain, not a plaintext file. The daemon, this pipeline, and
# scripts/install.sh all read/write the same generic-password items through /usr/bin/security. Keep the
# service + managed-key names in sync with KeychainSecrets.swift and install.sh.
KEYCHAIN_SERVICE = "com.meetingpipe.daemon"
MANAGED_SECRET_KEYS = ("ANTHROPIC_API_KEY", "NOTION_TOKEN", "HF_TOKEN", "OPENAI_API_KEY")


class Recording(BaseModel):
    output_dir: Path = Field(default=_expand("~/Documents/Meetings/raw"))
    sample_rate: int = 16000
    auto_consent_apps: list[str] = Field(default_factory=list)
    # `extra="ignore"` — old config files in the wild may still have
    # capture_mode / audio_device / mic_device fields. Tolerate them
    # silently rather than rejecting the whole config.
    model_config = {"extra": "ignore"}


class Detection(BaseModel):
    debounce_start_sec: float = 5.0
    # 5s (down from 10s) since Signal C (meeting-window-closed) gives us a
    # faster confirmation that the call actually ended. Stays in sync with
    # the daemon's Config.swift default and config.example.toml.
    debounce_end_sec: float = 5.0
    manual_hotkey: str = "ctrl+option+m"
    prompt_timeout_sec: float = 30.0


class Transcription(BaseModel):
    """Empty placeholder so legacy `[transcription]` TOML sections still
    load. ASR + diarization run in Swift (FluidAudio); nothing in this
    section steers behaviour anymore. `extra="ignore"` swallows whatever
    fields older configs carry (model, fallback_model, language,
    disable_diarization, min_speakers, max_speakers, etc.)."""

    model_config = {"extra": "ignore"}


class Summarization(BaseModel):
    model: str = "claude-sonnet-4-6"
    max_tokens: int = 4000
    team_context: str = ""
    # Output language for the summary. "auto" mirrors the transcript's
    # detected language (Russian transcript → Russian summary, etc.) so
    # non-English meetings stay in their native language for review.
    # Force a specific ISO 639-1 code to override (e.g. "en" to always
    # produce an English summary regardless of transcript language).
    summary_language: str = "auto"
    # Long-meeting guard: if the transcript markdown is longer than this
    # many characters, the orchestrator skips summarize + publish so we
    # don't burn Anthropic tokens on a long meeting. The transcript stays
    # on disk along with a `.READY_FOR_MANUAL.md` paste-into-Claude-Code
    # bundle. 0 disables the guard. 80 000 chars ≈ 20 000 tokens ≈ 1 hour
    # of speech.
    skip_above_chars: int = 80000
    # Backend selection (P2.3):
    #   "anthropic": current behaviour, requires ANTHROPIC_API_KEY.
    #   "local":     never call Anthropic; force the on-device MLX path.
    #   "auto":      try Anthropic first, fall back to local on
    #                network/auth failure.
    # When `modes.regulated_mode = true` the local backend is forced
    # regardless of this setting (summarize._select_backend), so no
    # transcript reaches a cloud provider. test_regulated_local_zero_egress
    # locks the zero-egress contract in. (The LAN sink still writes summaries
    # and transcripts to a mounted share by design; "zero egress" here means
    # no cloud egress, not "nothing leaves this process".)
    #   "apple_intelligence": on-device macOS 26 Foundation Model. The summary
    #                is produced in the Swift daemon, not here; the Python
    #                run-all finalizes the transcript then hands off (the
    #                daemon writes the summary and runs `mp publish`).
    #   "claude_cli": spawn the headless `claude -p` CLI (PROV1). A CLOUD backend
    #                (it egresses through a child process) that needs no API key,
    #                riding the user's existing Claude Code auth. Forced to local
    #                under regulated/NDA like every cloud backend.
    #   "openai":    an OpenAI-compatible chat-completions API over httpx (PROV1),
    #                key in the Keychain (OPENAI_API_KEY). Cloud; clamped by the
    #                egress guard exactly like anthropic.
    backend: Literal[
        "anthropic", "local", "auto", "apple_intelligence", "claude_cli", "openai"
    ] = "anthropic"
    # Default to the 7B-4bit (~4.3 GB resident): the engine-comparison sweet
    # spot (LOCAL6). On par with the 14B on action/decision capture but with
    # named owners, zero failures over the corpus, ~30% lower latency, and
    # memory-safe (the 14B OOM'd and hung the Mac). Preferences -> Pipeline
    # offers Small (3B) / Recommended (7B) / Large (14B).
    local_model: str = "mlx-community/Qwen2.5-7B-Instruct-4bit"
    local_endpoint: str = "http://127.0.0.1:8765"
    # Local-backend timeouts (LOCAL2/AUD-21). The old hardcoded 120s request
    # window fired before a legitimate large-model generation finished and
    # before the schema-retry layer engaged, contradicting the daemon's 20-min
    # watchdog budget. `local_startup_timeout_sec` bounds the mlx_lm.server
    # health-up window; `local_request_timeout_sec` is the BASE per-request read
    # timeout, scaled up by the requested max_tokens at call time (see
    # summarize_local.scaled_request_timeout). The daemon watchdog stays the hard
    # backstop, so generous values here only avoid premature cutoffs.
    local_startup_timeout_sec: float = 120.0
    local_request_timeout_sec: float = 120.0
    # PROV1: model id for the `openai` backend (an OpenAI-compatible
    # chat-completions endpoint). Ignored by every other backend. User-set to
    # whatever their key can reach; the default is a widely-available model.
    openai_model: str = "gpt-4o"
    # Opt-in LLM diarization cleanup (TECH-DIAR1). When true, run-all runs
    # an extra LLM pass after finalize that merges same-speaker labels and
    # reattributes obvious mistakes before summarizing. Off by default: it
    # adds one LLM round-trip per multi-speaker meeting. Honours `backend`
    # and stays on-device under regulated_mode. Run on demand any time via
    # `mp cleanup-diarization <stem>.json`.
    diarize_cleanup: bool = False
    # TECH-FEAT3 speaker enrollment (MVP): the display name to stamp on the
    # user's own speaker at finalization. The "me" speaker is the channel-
    # assigned mic speaker (`speaker_user`) when present, else the dominant
    # speaker by spoken time. Empty = no enrollment (labels stay
    # speaker_user / speaker_other). Set once; reused on every meeting.
    user_label: str = ""


class NotionCfg(BaseModel):
    database_id: str = ""
    default_status: str = "Captured"
    include_full_transcript: bool = True


class ObsidianCfg(BaseModel):
    """Obsidian vault sink (P3.2). Inactive unless `obsidian` is in
    `output.sinks`. The empty default for `vault_path` is so the
    config file can omit the section entirely; doctor warns when the
    sink is enabled with no path set."""
    vault_path: str = ""
    folder: str = "Meetings"
    template_path: str = ""
    attach_audio: bool = True
    attachments_subfolder: str = "_attachments"
    daily_note_backlink: bool = False


class FilesystemCfg(BaseModel):
    """Filesystem sink (P3.3). `output_dir` is the directory three
    files (summary, transcript, actions) are dumped into per meeting.
    Defaults to a sibling of the recordings dir so a fresh install
    "works" without further config when the sink is enabled."""
    output_dir: str = "~/Documents/Meetings/published"


class LanCfg(BaseModel):
    """LAN sink (TECH-FEAT1). Writes the same files as the filesystem sink,
    but to a mounted SMB/NFS share, with a reachability check and atomic writes
    so a half-written file never appears on a share other tools watch.

    `mount_path` is the target directory on the already-mounted share. The
    publisher never creates the mount root itself (that would silently fall back
    to local disk if the share were down). `host` is informational, used only in
    the unreachable error message. On-prem, no cloud metering, so this sink is
    allowed under regulated mode (only the cloud Notion sink is clamped)."""
    mount_path: str = "/Volumes/meetings"
    host: str = ""


class OutputCfg(BaseModel):
    """Multi-sink fan-out (P3.4). `sinks` is the ordered list of
    publisher names to invoke after summarize. Order is execution
    order; one sink failing logs an error but does not block the
    others. Each sink reads its own subsection (notion / obsidian /
    filesystem) for its own knobs.

    Default is `["notion"]` to preserve current single-sink behaviour
    for installs that do not opt into multi-sink config.
    """
    sinks: list[str] = Field(default_factory=lambda: ["notion"])


class Modes(BaseModel):
    regulated_mode: bool = False
    # Resolved per-meeting flag, set by the workflow overlay (mp.workflow) from
    # the sidecar's `workflow_nda_mode`. Not read from the global TOML; it rides
    # on the resolved Config so the egress guard (mp.egress_guard) can arm once
    # at entry on `regulated_mode or workflow_nda_mode`. (TECH-SEC3)
    workflow_nda_mode: bool = False


class Config(BaseModel):
    recording: Recording = Field(default_factory=Recording)
    detection: Detection = Field(default_factory=Detection)
    transcription: Transcription = Field(default_factory=Transcription)
    summarization: Summarization = Field(default_factory=Summarization)
    notion: NotionCfg = Field(default_factory=NotionCfg)
    obsidian: ObsidianCfg = Field(default_factory=ObsidianCfg)
    filesystem: FilesystemCfg = Field(default_factory=FilesystemCfg)
    lan: LanCfg = Field(default_factory=LanCfg)
    output: OutputCfg = Field(default_factory=OutputCfg)
    modes: Modes = Field(default_factory=Modes)

    @classmethod
    def load(cls, path: Path | None = None) -> "Config":
        path = path or CONFIG_PATH
        if not path.exists():
            return cls()
        with path.open("rb") as f:
            raw = tomllib.load(f)
        # Normalize tilde in output_dir if user wrote one.
        rec = raw.get("recording", {})
        if isinstance(rec.get("output_dir"), str):
            rec["output_dir"] = str(_expand(rec["output_dir"]))
        return cls(**raw)


def zero_egress(cfg: Config) -> bool:
    """True when this run may not reach a cloud service (SEC13).

    The two ways that happens are the global `regulated_mode` and the
    per-meeting `workflow_nda_mode` the workflow overlay resolves. Every clamp
    in the codebase keys off exactly this predicate: `effective_backend` pins
    the on-device summarizer, `effective_sinks` drops the Notion sink,
    `egress_guard.arm_for_config` blocks non-loopback HTTP and scrubs the cloud
    tokens, `workflow.apply_overrides` re-applies both fail-closed, and
    `publish_notion.publish` short-circuits before instantiating a publisher.
    They used to each carry their own copy of the `regulated or nda` boolean;
    this is the single owner (TECH-ARCH1).

    Note the LAN sink is deliberately *not* clamped: it writes to a mounted
    on-prem share by design. "Zero egress" is a no-cloud-egress promise.
    """
    return cfg.modes.regulated_mode or cfg.modes.workflow_nda_mode


def effective_backend(cfg: Config) -> str:
    """The summarization backend after the regulated/NDA force-local rule.

    Under `zero_egress` the on-device path is pinned regardless of the
    configured backend, so no transcript reaches a cloud provider. This is the
    single chokepoint (TECH-ARCH1) that replaces the copies of the same
    `if regulated and backend != local` block in summarize._select_backend,
    orchestrate, and diarize_cleanup._select_cleanup_backend. Callers keep
    their own apple_intelligence / auto handling on top of the value returned
    here.
    """
    backend = cfg.summarization.backend
    # Every non-local backend is a cloud backend, including the CLI providers
    # (PROV1): `claude_cli` egresses through a child process outside the
    # in-process httpx guard, so the fail-closed decision has to live here at the
    # policy layer, not in the transport patch. Forcing local for anything but
    # `local` under zero_egress covers them all, so a regulated/NDA run never
    # selects (and so never spawns) a cloud provider.
    if zero_egress(cfg) and backend != "local":
        return "local"
    return backend


# The valid `summarization.backend` values; mirror of the Literal on
# `Summarization.backend`. Kept as a set so the one-shot override (PIPE6) can
# validate a CLI value without re-deriving it from the Literal type.
BACKENDS: frozenset[str] = frozenset(
    {"anthropic", "local", "auto", "apple_intelligence", "claude_cli", "openai"}
)

# Backends that reach the cloud by spawning a child process rather than an
# in-process httpx call (PROV1). They sit OUTSIDE the egress guard's transport
# patch, so `effective_backend` classes them as cloud (forced local under
# zero_egress, above) and each such provider also refuses to spawn while the
# guard is armed, as defense in depth (the SEC10 posture).
CLI_BACKENDS: frozenset[str] = frozenset({"claude_cli"})


def with_backend_override(cfg: Config, backend: str) -> Config:
    """Return a copy of ``cfg`` with a one-shot summarization backend override
    (PIPE6): the Library's "Re-summarize with..." and `mp summarize --backend`.

    Request-scoped, so the caller uses the returned config for this run only and
    never persists it (rewriting the workflow's backend stays WF8's job). Apply it
    to the *config field*, after the workflow overlay, not to ``effective_backend``'s
    result: the regulated/NDA clamp then still bites, so a `--backend anthropic`
    on a regulated meeting is still forced to local and cannot widen egress.
    """
    if backend not in BACKENDS:
        raise ValueError(
            f"unknown backend {backend!r}; choose one of {', '.join(sorted(BACKENDS))}"
        )
    return cfg.model_copy(
        update={"summarization": cfg.summarization.model_copy(update={"backend": backend})}
    )


def extract_backend_flag(argv: list[str]) -> tuple[list[str], str | None]:
    """Pull a one-shot ``--backend <value>`` / ``--backend=<value>`` out of
    ``argv`` (PIPE6), returning the remaining args and the validated override (or
    None). Raises ``ValueError`` on a missing or unknown value so the CLI can turn
    it into a usage error. Shared by `mp summarize` and `mp run-all`."""
    out: list[str] = []
    override: str | None = None
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--backend":
            if i + 1 >= len(argv):
                raise ValueError("--backend requires a value")
            override, i = argv[i + 1], i + 2
            continue
        if a.startswith("--backend="):
            override, i = a.split("=", 1)[1], i + 1
            continue
        out.append(a)
        i += 1
    if override is not None and override not in BACKENDS:
        raise ValueError(
            f"unknown backend {override!r}; choose one of {', '.join(sorted(BACKENDS))}"
        )
    return out, override


def effective_sinks(cfg: Config) -> list[str]:
    """The output sinks after the regulated/NDA egress clamp.

    Notion is the one publisher that transmits to a cloud service, so under
    `zero_egress` it is dropped here, the single chokepoint (TECH-ARCH1) that
    build_publishers routes through. This folds in the TECH-SEC2 clamp that
    previously lived inline in publish_router._build_one. Local-only sinks
    (obsidian, filesystem) and the on-prem LAN sink are preserved in their
    configured order.
    """
    if zero_egress(cfg):
        return [s for s in cfg.output.sinks if s != "notion"]
    return list(cfg.output.sinks)


def parse_local_endpoint(endpoint: str) -> tuple[str, int]:
    """Split `summarization.local_endpoint` into (host, port).

    "http://127.0.0.1:8765" -> ("127.0.0.1", 8765). Defaults match
    LocalSummaryClient's defaults so a partially-malformed value degrades to
    "the right answer most of the time". Every caller that builds a
    LocalSummaryClient from config goes through here (summarize, engine,
    diarize_cleanup, summarize_local).
    """
    default_host, default_port = "127.0.0.1", 8765
    s = endpoint.strip()
    for prefix in ("http://", "https://"):
        if s.startswith(prefix):
            s = s[len(prefix):]
            break
    if "/" in s:
        s = s.split("/", 1)[0]
    if ":" in s:
        host, port_s = s.rsplit(":", 1)
        try:
            return (host or default_host, int(port_s))
        except ValueError:
            return (host or default_host, default_port)
    return (s or default_host, default_port)


def _keychain_get(account: str, service: str = KEYCHAIN_SERVICE) -> str | None:
    """Read a token from the macOS login Keychain via /usr/bin/security. None if absent/unreadable."""
    import subprocess
    try:
        out = subprocess.run(
            ["/usr/bin/security", "find-generic-password", "-s", service, "-a", account, "-w"],
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0:
        return None
    val = out.stdout.strip()
    return val or None


def load_secrets(reader=_keychain_get) -> None:
    """Populate os.environ with the managed API tokens from the macOS Keychain (SEC8).

    Daemon does this in Swift and injects the tokens into the subprocess env; Python fills any that are
    still missing or empty (a hand-run `mp` without the daemon, or a shell that exported an empty string,
    which Claude Code does) from the Keychain, treating "" as absent so the real value wins.

    SEC13: a zero-egress run refills nothing. Refilling used to undo the daemon's SEC5 strip, collapsing
    defense-in-depth to the single httpx layer and handing the cloud tokens to the mlx_lm.server child.
    Every entry point arms the guard before calling this (see `mp.entry.prepare`), so the ordering holds;
    `egress_guard.arm` has already scrubbed anything the daemon did pass in.
    """
    from . import egress_guard
    if egress_guard.is_armed():
        return
    for key in MANAGED_SECRET_KEYS:
        if os.environ.get(key):
            continue
        val = reader(key)
        if val:
            os.environ[key] = val


def require_env(name: str) -> str:
    """Fail fast with an actionable message if a secret is missing."""
    val = os.environ.get(name)
    if not val:
        sys.stderr.write(
            f"ERROR: ${name} is not set. Set it in the daemon's Preferences, re-run scripts/install.sh, "
            f"or add it to the Keychain:\n"
            f"  security add-generic-password -U -s {KEYCHAIN_SERVICE} -a {name} -w <value>\n"
        )
        sys.exit(2)
    return val
