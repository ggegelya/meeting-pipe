"""Pydantic settings model mirroring config.example.toml.

Loaded once at CLI start. Same TOML lives in the daemon (Swift) and pipeline (Python),
which is fine because both are read-only consumers — config is owned by the user.
"""
from __future__ import annotations

import logging
import os
import re
import tomllib
from pathlib import Path
from typing import Any, Literal, get_args

from pydantic import BaseModel, Field, PrivateAttr, StrictBool, ValidationError


def _expand(p: str) -> Path:
    return Path(os.path.expanduser(p))


CONFIG_PATH = _expand("~/.config/meeting-pipe/config.toml")

# STOR6: the library defaults moved out of iCloud's Desktop & Documents scope (and the
# TCC-protected Documents folder). A config that names no path, whose old default already holds
# files, keeps the old one: the daemon's `LibraryDefaultPin` writes it into config.toml at launch,
# and `_pin_legacy_defaults` applies the same rule here so a run before that launch agrees.
DEFAULT_OUTPUT_DIR = "~/Meetings/raw"
DEFAULT_PUBLISHED_DIR = "~/Meetings/published"
LEGACY_OUTPUT_DIR = "~/Documents/Meetings/raw"
LEGACY_PUBLISHED_DIR = "~/Documents/Meetings/published"


def _has_entries(path: Path) -> bool:
    try:
        return any(entry.name != ".DS_Store" for entry in path.iterdir())
    except OSError:
        return False


def _pin_legacy_defaults(raw: dict[str, Any]) -> None:
    """Name the old default in `raw` for each library key the file leaves unset whose old
    default directory holds files (STOR6; mirrors Swift's `LibraryDefaultPin`)."""
    for table, legacy in (("recording", LEGACY_OUTPUT_DIR), ("filesystem", LEGACY_PUBLISHED_DIR)):
        section = raw.get(table)
        if section is None:
            section = {}
        if not isinstance(section, dict) or "output_dir" in section:
            continue
        if _has_entries(_expand(legacy)):
            section["output_dir"] = legacy
            raw[table] = section

# SEC8: API tokens live in the macOS login Keychain, not a plaintext file. The daemon, this pipeline, and
# scripts/install.sh all read/write the same generic-password items through /usr/bin/security. Keep the
# service + managed-key names in sync with KeychainSecrets.swift and install.sh.
KEYCHAIN_SERVICE = "com.meetingpipe.daemon"
MANAGED_SECRET_KEYS = ("ANTHROPIC_API_KEY", "NOTION_TOKEN", "HF_TOKEN", "OPENAI_API_KEY")

# The `summarization.backend` vocabulary, declared once (ARCH5). `Summarization.backend`
# annotates with this alias and `BACKENDS` below derives the runtime set from it, so the
# type and the validation set cannot disagree; they were two hand-maintained lists of the
# same six strings. Per-value semantics are documented on the field itself.
BackendName = Literal[
    "anthropic", "local", "auto", "apple_intelligence", "claude_cli", "openai"
]


# The sink names `publish_router._build_one` builds (PIPE42). `OutputCfg.sinks` is
# typed with it, so a misspelt sink fails `Config.load` before any model call
# instead of raising from the publish fan-out after the summary was paid for.
# `test_config.py` pins it against `_build_one`'s own comparisons.
SinkName = Literal["notion", "obsidian", "filesystem", "lan"]


class ConfigError(ValueError):
    """config.toml parses but says something the pipeline must not guess at (PIPE42).

    Today that is one shape: a top-level section's table nested inside another
    table, which is what `modes.regulated_mode = true` appended to the end of the
    file becomes (TOML binds a dotted key to the last open table). Pydantic would
    drop it without a word and regulated mode would stay off, so the load refuses,
    the same posture as a file that does not parse: no run egresses on a config
    whose regulated switch might be sitting in the wrong table.
    """


class ConfigUnreadableError(ConfigError):
    """config.toml does not parse, or parses into a value the model refuses (UX94).

    One typed error for both, so `failure_details.describe` can give it its own cause (`config`)
    and the daemon can say which line or key to fix, instead of an unknown failure whose Retry
    fails the same way until the file is fixed. The message names the position or the dotted key,
    never a value: a value can be a path, a database id or a workflow name the owner chose.
    """

    def __init__(self, path: Path, *, line: int | None = None, column: int | None = None,
                 key: str | None = None) -> None:
        self.path = path
        self.line = line
        self.column = column
        self.key = key
        if key is not None:
            message = f"config.toml has an invalid `{key}` setting."
        elif line is not None:
            where = f"at line {line}" + (f", column {column}" if column is not None else "")
            message = f"config.toml does not parse {where}."
        else:
            message = "config.toml does not parse."
        super().__init__(message)


_TOML_POSITION = re.compile(r"\(at line (\d+), column (\d+)\)")


def _toml_position(error: tomllib.TOMLDecodeError) -> tuple[int | None, int | None]:
    """The line and column of a TOML syntax error. Python 3.11 keeps them only in the message
    (`Invalid value (at line 2, column 1)`); later versions also carry `lineno` / `colno`."""
    line, column = getattr(error, "lineno", None), getattr(error, "colno", None)
    if isinstance(line, int):
        return line, column if isinstance(column, int) else None
    match = _TOML_POSITION.search(str(error))
    return (int(match.group(1)), int(match.group(2))) if match else (None, None)


class Recording(BaseModel):
    output_dir: Path = Field(default=_expand(DEFAULT_OUTPUT_DIR))
    # `extra="ignore"` — old config files in the wild may still have
    # capture_mode / audio_device / mic_device / sample_rate fields (the last
    # deleted by HYG2: capture is a deliberate 16 kHz constant). Tolerate them
    # silently rather than rejecting the whole config. It also swallows the
    # daemon-only `auto_consent_apps`, which ARCH9 dropped from this model
    # because no Python code read it.
    model_config = {"extra": "ignore"}


class Detection(BaseModel):
    """Empty placeholder so `[detection]` TOML sections still load. Every key in
    it is daemon-only (hotkeys, debounces, the prompt timeout) and read by
    `ConfigStore.swift`; ARCH9 dropped the three this model used to carry
    (`debounce_end_sec`, `manual_hotkey`, `prompt_timeout_sec`) because no
    Python code read them, and a second description of a schema nobody here
    consumes is only another place for a default to drift."""

    model_config = {"extra": "ignore"}


class Transcription(BaseModel):
    """Empty placeholder so `[transcription]` TOML sections still load. ASR +
    diarization run in Swift (FluidAudio), so nothing in this section steers
    the pipeline. Two keys in it are live but Swift-owned and read only there
    (`diarization_clustering_threshold`, and `language` since HYG2 wired it);
    `extra="ignore"` swallows those along with whatever legacy fields older
    configs carry (model, fallback_model, disable_diarization, min_speakers,
    max_speakers, etc.)."""

    model_config = {"extra": "ignore"}


class ExtraSectionSpec(BaseModel):
    """WF7: one workflow-defined extra summary section. `name` titles the section
    in the output; `instruction` tells the model what to put there. Populated per
    meeting by `workflow.apply_overrides` from `<stem>.meta.json`, not typically
    hand-set in config.toml."""
    name: str = ""
    instruction: str = ""

    model_config = {"extra": "ignore"}


class Summarization(BaseModel):
    model: str = "claude-sonnet-5-5"
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
    backend: BackendName = "anthropic"
    # UX63. Pin `mp digest`'s narration to the on-device engine whatever
    # `backend` above says, without moving anything else off it.
    #
    # The digest is the one command that runs unattended on a schedule and reads
    # the WHOLE library: a launchd job every Monday sends a slice of every
    # workflow's open actions and decisions to the narrating engine, with no UI
    # in front of it. That is a different bargain from a meeting summary you
    # watched happen, which is why it gets its own knob rather than inheriting
    # one. Off by default, so the shipped behaviour is unchanged and the cloud
    # narrative (which is better) stays the default.
    #
    # Only ever narrows: it forces local and never selects a cloud engine, so it
    # composes with the regulated / NDA clamp instead of fighting it. The facts
    # the narration is built from are gathered on-device either way; this is
    # about the sentence that wraps them.
    digest_local_only: bool = False
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
    # LOCAL16: free-RAM floor, as a percentage of physical RAM, under which an
    # on-device run aborts with a named error instead of letting the Mac swap.
    # Sampled between requests on the local summarize path and between batches on
    # the `mp ask` embed path (mp.resource_guard). 10% is LOCAL13's bench figure,
    # measured against this Mac reading ~18% free while idle. 0 disables the
    # watchdog (the tier refusal at spawn time is separate and stays on).
    local_memory_floor_pct: float = 10.0
    # LOCAL9: path to a locally-trained LoRA adapter (`mp train-adapter`). Empty
    # (the default) serves the base model; set it to opt a fine-tuned adapter into
    # the local backend. Never applied unless explicitly set, and fully on-device,
    # so a regulated/NDA run can use it too.
    local_adapter_path: str = ""
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
    # assigned mic speaker (`speaker_user`) when present, else the speaker
    # identified on the mic channel, else the self-voiceprint match; nobody when
    # no signal finds the user, since they may simply not have spoken. Empty =
    # the identified user is labelled `speaker_user` (UX83), rendered "You", never
    # the diarizer's raw cluster id. Set once; reused on every meeting.
    user_label: str = ""
    # WF7: workflow-defined extra summary sections, overlaid per meeting by
    # `workflow.apply_overrides` from the meta sidecar. Empty for a workflow that
    # defines none (the common case), so the summary shape is unchanged.
    extra_sections: list[ExtraSectionSpec] = Field(default_factory=list)


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
    output_dir: str = DEFAULT_PUBLISHED_DIR


class LanCfg(BaseModel):
    """LAN sink (TECH-FEAT1). Writes the same files as the filesystem sink,
    but to a mounted SMB/NFS share, with a reachability check and atomic writes
    so a half-written file never appears on a share other tools watch.

    `mount_path` is the target directory on the already-mounted share. The
    publisher never creates the mount root itself (that would silently fall back
    to local disk if the share were down). `host` is informational, used only in
    the unreachable error message. Zero egress leaves only the filesystem sink
    (SEC18), so this sink does not publish under regulated mode or an NDA
    workflow."""
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
    sinks: list[SinkName] = Field(default_factory=lambda: ["notion"])


class Modes(BaseModel):
    # Strict (PIPE42): `"true"`, `"false"`, `1` and `0` refuse to load rather than
    # being coerced. Lax mode read `"false"` as False here while the Swift store,
    # which reads only a TOML boolean, fails closed and reads the same file as
    # regulated; a refusal is fail-closed on both sides.
    regulated_mode: StrictBool = False
    # Resolved per-meeting flag, set by the workflow overlay (mp.workflow) from
    # the sidecar's `workflow_nda_mode`. Not read from the global TOML; it rides
    # on the resolved Config so the egress guard (mp.egress_guard) can arm once
    # at entry on `regulated_mode or workflow_nda_mode`. (TECH-SEC3)
    workflow_nda_mode: bool = False


class MCPCfg(BaseModel):
    """`mp mcp-serve`, the read-only MCP stdio server (AUTO3).

    Off by default, and the default is the point: the server hands an agentic
    client the choice of what to pull out of the library, which is the one place
    in this codebase where meeting-pipe is not the party deciding what may
    leave. Opting in is a deliberate act, reversible from Preferences ▸
    Integrations, and `mcp_serve.main` refuses to start while this is false, so
    the switch is a real kill switch rather than a label.
    """
    enabled: bool = False


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
    mcp: MCPCfg = Field(default_factory=MCPCfg)

    # Keys `load` found in a Python-owned section and no model declares (PIPE42),
    # as `(section, key)`, `section` being `top_level` for a key outside any table.
    _unknown_keys: list[tuple[str, str]] = PrivateAttr(default_factory=list)

    @property
    def unknown_keys(self) -> list[tuple[str, str]]:
        return list(self._unknown_keys)

    @classmethod
    def load(cls, path: Path | None = None) -> "Config":
        path = path or CONFIG_PATH
        if not path.exists():
            empty: dict[str, Any] = {}
            _pin_legacy_defaults(empty)
            if isinstance(empty.get("recording", {}).get("output_dir"), str):
                empty["recording"]["output_dir"] = str(_expand(empty["recording"]["output_dir"]))
            return cls(**empty)
        with path.open("rb") as f:
            try:
                raw = tomllib.load(f)
            except tomllib.TOMLDecodeError as e:
                line, column = _toml_position(e)
                # `from None`: the decoder's own text is position-only today, but nothing promises it.
                raise ConfigUnreadableError(path, line=line, column=column) from None
        if "regulated_mode" in raw:
            # The switch above every table: nothing reads it there, and a warning
            # alone would leave the run unregulated (PIPE42).
            raise ConfigError(
                "config.toml has `regulated_mode` above every table, where nothing reads it. "
                "Move it under a [modes] header."
            )
        misplaced = _misplaced_section(raw, frozenset(cls.model_fields))
        if misplaced is not None:
            section = misplaced.rsplit(".", 1)[1]
            raise ConfigError(
                f"config.toml has a `{misplaced}` table, but `{section}` is a top-level section. "
                f"This usually comes from a dotted key added at the end of the file, which lands "
                f"under whichever table is open last. Move it under its own [{section}] header."
            )
        unknown = find_unknown_keys(raw)
        _report_unknown(unknown)
        _pin_legacy_defaults(raw)
        # Normalize tilde in output_dir if user wrote one.
        rec = raw.get("recording", {})
        if isinstance(rec.get("output_dir"), str):
            rec["output_dir"] = str(_expand(rec["output_dir"]))
        try:
            cfg = cls(**raw)
        except ValidationError as e:
            # The dotted location of the first refusal, never its input: pydantic's own text quotes
            # the value, so it is dropped (`from None`) rather than chained into the traceback.
            first = e.errors()[0] if e.errors() else {}
            key = ".".join(str(part) for part in first.get("loc", ())) or None
            raise ConfigUnreadableError(path, key=key) from None
        cfg._unknown_keys = unknown
        return cfg


def _misplaced_section(node: Any, sections: frozenset[str], path: tuple[str, ...] = ()) -> str | None:
    """The dotted path of the first table below the top level whose name is a
    top-level section name, walking tables and arrays of tables; None if none."""
    if isinstance(node, list):
        for item in node:
            found = _misplaced_section(item, sections, path)
            if found is not None:
                return found
        return None
    if not isinstance(node, dict):
        return None
    for key, value in node.items():
        here = (*path, key)
        if path and key in sections and isinstance(value, dict):
            return ".".join(here)
        found = _misplaced_section(value, sections, here)
        if found is not None:
            return found
    return None


# The sections whose every key this pipeline models, so an undeclared key there is
# almost certainly a typo that would otherwise be dropped in favour of the default
# (PIPE42). `recording`, `detection` and `transcription` are not here: their
# models tolerate legacy and Swift-owned keys on purpose (ARCH9, ADR 0007).
_STRICT_SECTIONS: dict[str, type[BaseModel]] = {
    "modes": Modes,
    "summarization": Summarization,
    "output": OutputCfg,
    "notion": NotionCfg,
    "obsidian": ObsidianCfg,
    "filesystem": FilesystemCfg,
    "lan": LanCfg,
    "mcp": MCPCfg,
}

TOP_LEVEL = "top_level"

_WARNED_UNKNOWN: set[tuple[str, str]] = set()
"""Unknown keys already reported in this process: a run loads the config more than once."""


def find_unknown_keys(raw: dict[str, Any]) -> list[tuple[str, str]]:
    """`(section, key)` for every key in `raw` that no model declares, in the top
    level and the Python-owned sections."""
    out = [(TOP_LEVEL, key) for key in raw if key not in Config.model_fields]
    for section, model in _STRICT_SECTIONS.items():
        table = raw.get(section)
        if isinstance(table, dict):
            out.extend((section, key) for key in table if key not in model.model_fields)
    return out


def _report_unknown(unknown: list[tuple[str, str]]) -> None:
    fresh = [item for item in unknown if item not in _WARNED_UNKNOWN]
    if not fresh:
        return
    _WARNED_UNKNOWN.update(fresh)
    names = ", ".join(key if section == TOP_LEVEL else f"{section}.{key}" for section, key in fresh)
    logging.getLogger(__name__).warning(
        "config.toml has keys nothing reads, so their defaults apply (check the spelling): %s", names
    )
    from . import events

    for section, key in fresh:
        try:
            events.emit("pipeline", "config_unknown_key", section=section, key=key)
        except OSError:
            # An unwritable log is no reason to fail the config load; the warning stands.
            break


def zero_egress(cfg: Config) -> bool:
    """True when this run may not reach a cloud service (SEC13).

    The two ways that happens are the global `regulated_mode` and the
    per-meeting `workflow_nda_mode` the workflow overlay resolves. Every clamp
    in the codebase keys off exactly this predicate: `effective_backend` pins
    the on-device summarizer, `effective_sinks` leaves only the filesystem sink,
    `egress_guard.arm_for_config` blocks non-loopback HTTP and scrubs the cloud
    tokens, `workflow.apply_overrides` re-applies both fail-closed, and
    `publish_notion.publish` short-circuits before instantiating a publisher.
    They used to each carry their own copy of the `regulated or nda` boolean;
    this is the single owner (TECH-ARCH1).

    The LAN sink is clamped with the rest (SEC18): `apply_overrides` always
    collapsed it, so a regulated meeting never reached the share in practice, and
    the two paths now say the same thing.
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


# The valid `summarization.backend` values, as a set the one-shot override (PIPE6)
# can validate a CLI value against. Derived from `BackendName` rather than restated,
# so adding a backend to the Literal cannot leave the override rejecting it (ARCH5).
BACKENDS: frozenset[str] = frozenset(get_args(BackendName))

# Backends that reach the cloud by spawning a child process rather than an
# in-process httpx call (PROV1). They sit OUTSIDE the egress guard's transport
# patch, so `effective_backend` classes them as cloud (forced local under
# zero_egress, above) and each such provider also refuses to spawn while the
# guard is armed, as defense in depth (the SEC10 posture).
CLI_BACKENDS: frozenset[str] = frozenset({"claude_cli"})

# Decoding temperature every backend samples at, structured summary and free-form
# alike. Not a config key: it is a property of what this product does with a
# summary, not a user preference. 0.2 because output here is *compared*, run
# against run, by the corrections A/B, `mp dogfood` scoring, and FEAT10's evidence
# verifier; at a provider's own default those comparisons measure the sampler
# rather than the change under test. The local path picked 0.2 first (a hotter
# sample kept wrapping the JSON object in prose) and openai matched it; PIPE12
# brought the two Anthropic paths, `summarize.AnthropicSummaryClient.summarize`
# and `engine.AnthropicTextClient.complete`, onto the same value, which had been
# running at the API default of 1.0 and so made the default backend the least
# repeatable one.
SAMPLING_TEMPERATURE: float = 0.2

# Anthropic models that still take the request PIPE12 shaped: a pinned temperature
# and, on the structured calls, a forced `tool_choice`. That is Sonnet 4.6 / Opus
# 4.6 / Haiku 4.5 and everything older. Every model from Opus 4.7 on returns a 400
# for a non-default temperature, and Sonnet 5.5 / Opus 5.5 / Fable 5.1 also for a
# forced tool_choice, so before this a bare `summarization.model` bump failed every
# summary. An id this does not match (a newer model, or one it has never heard of)
# gets the current shape: a future model is far likelier to follow the 5.x line
# than to accept a temperature again.
_ANTHROPIC_SAMPLING_MODEL = re.compile(
    r"^claude-(?:3(?:-5|-7)?-|(?:opus|sonnet|haiku)-4(?:-[0-6])?(?:-\d{8})?$)"
)

# Thinking counts toward `max_tokens`, so a model that thinks gets this on top of
# `summarization.max_tokens`, which stays the budget for the reply itself. Effort
# is `low`, the documented starting point for summarization and extraction, which
# skips thinking on most simple requests.
ANTHROPIC_THINKING_HEADROOM_TOKENS = 8000


def anthropic_sampling(
    model: str,
    max_tokens: int,
    *,
    temperature: float | None = None,
    tool_name: str | None = None,
) -> dict[str, Any]:
    """The model-dependent part of an Anthropic messages request.

    On a model that takes it, the shape every call site sent before: `temperature`
    when the caller pins one (PIPE12) and the tool forced by name. On a current
    model the temperature is dropped (the API rejects it, so PIPE12's repeatability
    is not available there), the tool is steered with `auto` (each prompt already
    says to call it exactly once, and each caller already copes with a reply that
    has no tool_use block), and adaptive thinking runs at low effort.

    T10: the full request each call site builds from this is pinned by
    `tests/test_anthropic_request_goldens.py`, which says what we send, not that the
    API accepts it. Before changing this function, the default model, or the
    `anthropic` lock entry, run the opt-in live test as well:
    `MP_LIVE_ANTHROPIC=1 uv run --extra dev pytest -m live -q` (needs ANTHROPIC_API_KEY).
    """
    if _ANTHROPIC_SAMPLING_MODEL.match(model):
        legacy: dict[str, Any] = {"max_tokens": max_tokens}
        if temperature is not None:
            legacy["temperature"] = temperature
        if tool_name is not None:
            legacy["tool_choice"] = {"type": "tool", "name": tool_name}
        return legacy
    current: dict[str, Any] = {
        "max_tokens": max_tokens + ANTHROPIC_THINKING_HEADROOM_TOKENS,
        "thinking": {"type": "adaptive"},
        "output_config": {"effort": "low"},
    }
    if tool_name is not None:
        current["tool_choice"] = {"type": "auto"}
    return current


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


#: PIPE25: why a caller ran `local` in place of the engine the meeting asked for, as
#: `--fallback-from <backend>:<cause>` tells `mp summarize`. Closed, so a typo is a
#: usage error rather than a provenance line nobody can render.
SUBSTITUTION_CAUSES = frozenset({"unsupported_language"})

_LANGUAGE_CODE = re.compile(r"^[a-z]{2,3}(-[A-Za-z0-9]{2,8})?$")


def extract_fallback_flags(argv: list[str]) -> tuple[list[str], dict[str, str]]:
    """Pull PIPE25's ``--fallback-from <backend>:<cause>`` and ``--fallback-language
    <code>`` out of ``argv``, returning the remaining args and the validated
    ``fallback_from`` / ``fallback_cause`` / ``fallback_language`` keys for
    `<stem>.run.json` (empty when the flags are absent).

    The daemon passes them when it re-runs an Apple Intelligence meeting on `local`
    because the system model refused the language, so the run sidecar says why the
    meeting was not summarized on the engine its workflow names (the OBS2 rule:
    a substitution is never laundered into what reads as a deliberate choice).
    Raises ``ValueError`` on a missing or invalid value, like `extract_backend_flag`.
    """
    out: list[str] = []
    raw: dict[str, str] = {}
    i = 0
    while i < len(argv):
        a = argv[i]
        matched = False
        for flag in ("--fallback-from", "--fallback-language"):
            if a == flag:
                if i + 1 >= len(argv):
                    raise ValueError(f"{flag} requires a value")
                raw[flag], i, matched = argv[i + 1], i + 2, True
                break
            if a.startswith(flag + "="):
                raw[flag], i, matched = a.split("=", 1)[1], i + 1, True
                break
        if not matched:
            out.append(a)
            i += 1
    keys: dict[str, str] = {}
    if "--fallback-from" in raw:
        backend, _, cause = raw["--fallback-from"].partition(":")
        if backend not in BACKENDS or cause not in SUBSTITUTION_CAUSES:
            raise ValueError(
                f"--fallback-from takes <backend>:<cause>, with cause one of "
                f"{', '.join(sorted(SUBSTITUTION_CAUSES))}"
            )
        keys["fallback_from"], keys["fallback_cause"] = backend, cause
    if "--fallback-language" in raw:
        if "fallback_from" not in keys:
            raise ValueError("--fallback-language needs --fallback-from")
        language = raw["--fallback-language"]
        if not _LANGUAGE_CODE.match(language):
            raise ValueError("--fallback-language takes a language code such as uk")
        keys["fallback_language"] = language
    return out, keys


def effective_sinks(cfg: Config) -> list[SinkName]:
    """The output sinks after the regulated/NDA egress clamp.

    Under `zero_egress` the one sink left is the filesystem sink (SEC18), whatever
    the configuration holds. This is the single owner of that rule (TECH-ARCH1):
    `build_publishers` routes through it, and `workflow.apply_overrides` calls it
    rather than carrying its own copy, so the no-sidecar path and the sidecar path
    every recorded meeting takes can no longer disagree. They used to: this kept
    Obsidian and the on-prem LAN share while the overlay collapsed both to the
    filesystem folder. Swift mirrors the rule as `RegulatedMode.effectiveSinks`,
    pinned against this one by `sink-rule-golden.json`.

    Owner question, open (SEC18 spec items 1 and 7): should a local Obsidian vault
    or the LAN share survive zero egress? Both are local writes, and both can be
    synced; the gate in `publish_router.build_publishers` already refuses a synced
    target. Until the owner says, the rule is the one the sidecar path enforced.
    """
    if zero_egress(cfg):
        return ["filesystem"]
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


KEYCHAIN_ITEM_NOT_FOUND = 44
"""`security`'s exit status for `errSecItemNotFound`, the only status that means "no such token"."""


def _keychain_get(account: str, service: str = KEYCHAIN_SERVICE) -> str | None:
    """Read a token from the macOS login Keychain via /usr/bin/security.

    None means there is no such token (status 44, or an empty value). Any other outcome (a locked
    keychain, a denied ACL, `security` not runnable, a timeout) raises `KeychainUnreadableError`
    instead of reading as absent (SEC23).
    """
    import logging
    import subprocess
    try:
        out = subprocess.run(
            ["/usr/bin/security", "find-generic-password", "-s", service, "-a", account, "-w"],
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError) as error:
        logging.getLogger(__name__).warning("keychain read of %s failed to run: %s", account, type(error).__name__)
        raise KeychainUnreadableError(account, -1, type(error).__name__) from error
    if out.returncode == KEYCHAIN_ITEM_NOT_FOUND:
        return None
    if out.returncode != 0:
        logging.getLogger(__name__).warning(
            "keychain read of %s failed with security status %s", account, out.returncode
        )
        raise KeychainUnreadableError(account, out.returncode, (out.stderr or "").strip()[:200])
    val = out.stdout.strip()
    return val or None


_ABSENT_SECRETS: set[str] = set()
"""Managed tokens the Keychain has no item for, remembered for the life of the process (CONC8, F208): a
run reaches `entry.prepare` more than once, and each pass used to spawn a `security` per absent key."""

_UNREADABLE_SECRETS: dict[str, "KeychainUnreadableError"] = {}
"""Managed tokens the last `load_secrets` could not read, by name (SEC23)."""


def load_secrets(reader=_keychain_get) -> None:
    """Populate os.environ with the managed API tokens from the macOS Keychain (SEC8).

    The daemon hands a spawn the tokens its SEC5 policy keeps (SEC23: its own env carries none); Python
    fills any that are still missing or empty (a hand-run `mp` without the daemon, or a shell that exported an empty string,
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
            _UNREADABLE_SECRETS.pop(key, None)
            continue
        if key in _ABSENT_SECRETS:
            continue
        try:
            val = reader(key)
        except KeychainUnreadableError as error:
            # SEC23: not raised here, because a run that never needs this token (a local summary, no
            # sinks) must not fail on a locked keychain. `require_env` raises it for the token a stage
            # actually asks for, so the message says "could not be read", not "not set".
            _UNREADABLE_SECRETS[key] = error
            continue
        _UNREADABLE_SECRETS.pop(key, None)
        if val:
            os.environ[key] = val
            _ABSENT_SECRETS.discard(key)
        else:
            _ABSENT_SECRETS.add(key)


class MissingSecretError(Exception):
    """A managed secret this stage needs is absent from the environment (PIPE16).

    An ordinary `Exception`, and that is the entire point. `require_env` used to
    call `sys.exit(2)` from library code, and `SystemExit` derives from
    `BaseException`, so it passed straight through both of `orchestrate`'s
    `except Exception` handlers: no `run_failed` event, no exit-3 mapping, no
    `<stem>.publish.json`. The daemon then saw exit 2 over a meeting whose
    summary was already on disk, mapped it to the generic pipeline stage, and
    `MeetingStore` settled the durable row on **"Ready"** for a meeting that
    published nowhere.

    Fail-fast is preserved where it was actually meant, at the CLI boundary:
    `mp.__main__.main` catches this once, beside the `KeyboardInterrupt` handler
    and for the same reason, and returns 2.
    """

    def __init__(self, name: str) -> None:
        self.name = name
        super().__init__(
            f"${name} is not set. Set it in the daemon's Preferences, re-run scripts/install.sh, "
            f"or add it to the Keychain:\n"
            f"  security add-generic-password -U -s {KEYCHAIN_SERVICE} -a {name} -w <value>"
        )


class KeychainUnreadableError(MissingSecretError):
    """A token could not be read from the Keychain, which is not the same as it being unset (SEC23).

    A locked login keychain, a denied ACL and a `security` that never ran all used to read as "absent",
    so the user was told to set a key that may already be set and the advice could not fix it. This
    subclasses `MissingSecretError` so every PIPE16 handler treats it the same way, and carries the
    status so the log can tell the two apart.
    """

    def __init__(self, name: str, status: int, detail: str = "") -> None:
        self.name = name
        self.status = status
        self.detail = detail
        Exception.__init__(
            self,
            f"${name} could not be read from the macOS Keychain (security status {status}"
            f"{': ' + detail if detail else ''}). The token may be set; the login keychain is "
            f"probably locked. Unlock it (`security unlock-keychain`) or open Keychain Access once, "
            f"then run this again."
        )


def require_env(name: str) -> str:
    """Fail fast with an actionable message if a secret is missing.

    Raises `MissingSecretError` rather than exiting, so a caller that owns a
    recovery (the publish fan-out records the sink as failed and runs the rest)
    can take it, and so the handlers a run is already wrapped in can see it. The
    CLI boundary still turns it into exit 2.
    """
    val = os.environ.get(name)
    if not val:
        # SEC23: a token the Keychain would not give up is "could not be read", not "not set".
        raise _UNREADABLE_SECRETS.get(name) or MissingSecretError(name)
    return val
