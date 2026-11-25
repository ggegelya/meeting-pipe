"""The pipeline entry contract (SEC13).

Every `mp` subcommand that can reach a sink, an engine, or a token has to do the
same three things before it does anything else, in this order:

  1. resolve the per-meeting workflow overlay onto the global config, because
     that is what sets `workflow_nda_mode`;
  2. arm the egress guard on the *resolved* config, so a per-meeting NDA
     workflow clamps the process before any client is constructed;
  3. load the Keychain secrets, which `egress_guard` then declines to do under
     a zero-egress run.

Getting the order wrong is silent: arming before the overlay misses the NDA
flag, loading secrets before arming leaves the tokens in the environment for the
`mlx_lm.server` child to inherit. The triple was copy-pasted at eleven entry
points before this module existed; the twelfth would have been the one that
forgot. Call `prepare()` instead.
"""
from __future__ import annotations

import logging
import sys
from pathlib import Path

from .config import Config, load_secrets
from .egress_guard import arm_for_config
from .workflow import apply_overrides

#: The one stderr format every subcommand logs in (HYG16). The daemon copies a child's
#: stderr into `pipeline.log` and reads the level off the leading fields
#: (`PipelineLauncher.stderrLogLevel`), so a change here is a change there.
LOG_FORMAT = "%(asctime)s %(levelname)s %(name)s: %(message)s"


def configure_logging() -> None:
    """Root logging for one subcommand: INFO, to stderr, in `LOG_FORMAT`.

    Stderr explicitly, so a command whose stdout is a protocol (`mp prefetch-model`'s
    JSONL, `mp mcp-serve`'s stdio) never has a log line land in it. A no-op when the
    root logger already has handlers, as `logging.basicConfig` always is.
    `orchestrate._configure_logging` stays separate: it adds the `pipeline.log` file
    handler `run-all` owns (T9)."""
    logging.basicConfig(level=logging.INFO, stream=sys.stderr, format=LOG_FORMAT)


def prepare(
    cfg: Config | None = None,
    anchor: Path | None = None,
    *,
    secrets: bool = True,
) -> Config:
    """Resolve the config for one pipeline run and clamp the process to it.

    `cfg` is the caller's already-loaded config when it has one (tests, and the
    orchestrator handing its config down to `summarize`), otherwise the global
    TOML is read. `anchor` is any file belonging to the meeting (`<stem>.wav`,
    `<stem>.md`, `<stem>.summary.json`, ...); the overlay derives the stem from
    it. Commands with no meeting in scope (`mp ask`, `mp digest`, `mp backup`)
    pass none and get the global config, still clamped.

    `secrets=False` for the local-only commands (`mp backup`, `mp restore`) that
    never touch a token, so they do not spawn three `security` reads to fill an
    environment they will not use.

    Returns the resolved config. Never mutates the caller's.
    """
    cfg = cfg or Config.load()
    if anchor is not None:
        cfg = apply_overrides(cfg, anchor)
    arm_for_config(cfg)
    if secrets:
        load_secrets()
    return cfg
