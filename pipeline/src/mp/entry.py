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

from pathlib import Path

from .config import Config, load_secrets
from .egress_guard import arm_for_config
from .workflow import apply_overrides


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
