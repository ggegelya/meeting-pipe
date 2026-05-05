"""Pydantic settings model mirroring config.example.toml.

Loaded once at CLI start. Same TOML lives in the daemon (Swift) and pipeline (Python),
which is fine because both are read-only consumers — config is owned by the user.
"""
from __future__ import annotations

import os
import sys
import tomllib
from pathlib import Path

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
    # MLX-converted Whisper repo on Hugging Face. Defaults to the turbo
    # variant — best speed/quality tradeoff on Apple Silicon, ~5-10× faster
    # than faster-whisper-CPU at near-equal WER. Pre-converted alternates:
    #   mlx-community/whisper-large-v3-mlx
    #   mlx-community/whisper-medium
    # On non-Apple-Silicon hosts the pipeline falls back to faster-whisper
    # using `fallback_model` below.
    model: str = "mlx-community/whisper-large-v3-turbo"
    fallback_model: str = "large-v3"
    language: str = "auto"
    min_speakers: int = 1
    max_speakers: int = 8
    disable_diarization: bool = False
    # Diarization runs offline on sherpa-onnx (CoreML on Apple Silicon).
    # Roughly 0.05-0.3× realtime — multi-hour recordings finish in
    # minutes rather than the multi-hour pyannote-CPU runs we used to see.
    # Keep a generous safety guard: 0 disables it.
    max_diarization_minutes: int = 240
    # sherpa-onnx FastClustering merge threshold (cosine distance).
    # Higher = merge more aggressively = fewer speakers.
    # 0.7-0.85 is a reasonable range for English/EU-language meetings.
    # Tune up if you see one person split across N speaker labels;
    # tune down if multiple participants get collapsed into one.
    diarize_cluster_threshold: float = 0.85
    # StreamDiarizer (online clustering) threshold. Different scale than
    # the offline FastClustering threshold — this one is direct cosine
    # distance against a running centroid table, evaluated per chunk
    # boundary. 0.6-0.75 produces speaker counts comparable to offline.
    stream_diarize_threshold: float = 0.7


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


class NotionCfg(BaseModel):
    database_id: str = ""
    default_status: str = "Captured"
    include_full_transcript: bool = True


class Modes(BaseModel):
    regulated_mode: bool = False


class Config(BaseModel):
    recording: Recording = Field(default_factory=Recording)
    detection: Detection = Field(default_factory=Detection)
    transcription: Transcription = Field(default_factory=Transcription)
    summarization: Summarization = Field(default_factory=Summarization)
    notion: NotionCfg = Field(default_factory=NotionCfg)
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
