"""Tests for the shared pipeline entry contract (SEC13).

`entry.prepare` exists so no subcommand hand-rolls the overlay/arm/secrets
triple, and so the *order* is enforced in one place. Both properties are load
bearing and both are silent when broken, so they are pinned here rather than
left to the eleven call sites.
"""
from __future__ import annotations

import json
from pathlib import Path

import pytest

from mp import egress_guard, entry
from mp.config import Config


def _meeting(tmp_path: Path, **meta) -> Path:
    """A meeting anchor (`<stem>.wav`) beside a `<stem>.meta.json` sidecar."""
    wav = tmp_path / "20260710-101500.wav"
    wav.write_bytes(b"")
    if meta:
        (tmp_path / "20260710-101500.meta.json").write_text(json.dumps(meta), encoding="utf-8")
    return wav


def test_prepare_applies_the_workflow_overlay_before_arming(tmp_path: Path) -> None:
    """The NDA flag only exists after the overlay, so arming first would miss it
    for every per-meeting NDA workflow."""
    wav = _meeting(tmp_path, workflow_nda_mode=True)
    cfg = entry.prepare(Config(), wav)
    assert cfg.modes.workflow_nda_mode is True
    assert egress_guard.is_armed()


def _spy_on_secrets(monkeypatch: pytest.MonkeyPatch) -> list[bool]:
    """Record whether the guard was already armed each time secrets were loaded."""
    armed_at_call: list[bool] = []
    monkeypatch.setattr(
        "mp.entry.load_secrets",
        lambda *a, **k: armed_at_call.append(egress_guard.is_armed()),
    )
    return armed_at_call


def test_prepare_arms_before_loading_secrets(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """Secrets loaded before the arm would sit in `os.environ` for the
    `mlx_lm.server` child to inherit. `load_secrets` declines once armed, so this
    ordering is what makes that decline reachable at all."""
    armed_at_call = _spy_on_secrets(monkeypatch)
    entry.prepare(Config(), _meeting(tmp_path, workflow_nda_mode=True))
    assert armed_at_call == [True]


def test_prepare_loads_secrets_on_an_unrestricted_run(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    armed_at_call = _spy_on_secrets(monkeypatch)
    entry.prepare(Config(), _meeting(tmp_path))
    assert not egress_guard.is_armed()
    assert armed_at_call == [False]


def test_prepare_without_secrets_skips_the_keychain(monkeypatch: pytest.MonkeyPatch) -> None:
    """`mp backup` / `mp restore` name the Keychain items, they never read them."""
    monkeypatch.setattr(Config, "load", classmethod(lambda cls, path=None: Config()))
    armed_at_call = _spy_on_secrets(monkeypatch)
    entry.prepare(secrets=False)
    assert armed_at_call == []


def test_prepare_without_an_anchor_skips_the_overlay(monkeypatch: pytest.MonkeyPatch) -> None:
    """Library-wide commands (`mp ask`, `mp digest`) have no meeting to overlay,
    but still get the global config and the clamp that goes with it."""
    monkeypatch.setattr(
        Config, "load",
        classmethod(lambda cls, path=None: Config.model_validate({"modes": {"regulated_mode": True}})),
    )
    _spy_on_secrets(monkeypatch)
    cfg = entry.prepare()
    assert cfg.modes.regulated_mode is True
    assert egress_guard.is_armed()


def test_prepare_does_not_mutate_the_callers_config(tmp_path: Path) -> None:
    original = Config()
    entry.prepare(original, _meeting(tmp_path, workflow_nda_mode=True))
    assert original.modes.workflow_nda_mode is False
