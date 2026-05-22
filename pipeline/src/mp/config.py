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
SECRETS_PATH = _expand("~/.config/meeting-pipe/secrets.env")


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
    # transcript leaves the machine. test_regulated_local_zero_egress
    # locks the zero-egress contract in.
    backend: Literal["anthropic", "local", "auto"] = "anthropic"
    # Default to the 3B-4bit (~2 GB) so first-time local users do not pay
    # a 7-8 GB download. Power users opt into a larger model in
    # Preferences -> Pipeline (Recommended = Qwen 14B-4bit, Large = 32B-4bit).
    local_model: str = "mlx-community/Qwen2.5-3B-Instruct-4bit"
    local_endpoint: str = "http://127.0.0.1:8765"


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


class Config(BaseModel):
    recording: Recording = Field(default_factory=Recording)
    detection: Detection = Field(default_factory=Detection)
    transcription: Transcription = Field(default_factory=Transcription)
    summarization: Summarization = Field(default_factory=Summarization)
    notion: NotionCfg = Field(default_factory=NotionCfg)
    obsidian: ObsidianCfg = Field(default_factory=ObsidianCfg)
    filesystem: FilesystemCfg = Field(default_factory=FilesystemCfg)
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


def load_secrets(path: Path = SECRETS_PATH) -> None:
    """Source ~/.config/meeting-pipe/secrets.env into os.environ.

    Daemon does this in Swift; Python does it independently so `mp` works
    when run by hand without the daemon.

    The file is authoritative: an entry here overrides whatever the parent
    shell happened to export. setdefault was the wrong API — if the shell
    has e.g. ANTHROPIC_API_KEY="" exported (Claude Code does this), the
    real value in this file would be ignored and downstream `require_env`
    would fail with a confusing "missing" error even though the file is
    populated correctly.
    """
    if not path.exists():
        return
    for line in path.read_text(encoding="utf-8").splitlines():
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        if "=" not in s:
            continue
        k, v = s.split("=", 1)
        v = v.strip()
        if len(v) >= 2 and v[0] == v[-1] == '"':
            v = v[1:-1]
        os.environ[k.strip()] = v


def require_env(name: str) -> str:
    """Fail fast with an actionable message if a secret is missing."""
    val = os.environ.get(name)
    if not val:
        sys.stderr.write(
            f"ERROR: ${name} is not set. Add it to {SECRETS_PATH} (mode 0600) or export it.\n"
        )
        sys.exit(2)
    return val
