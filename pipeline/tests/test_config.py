"""Tests for config secrets handling (TECH-SEC1)."""
from __future__ import annotations

import os
from pathlib import Path

from mp.config import _secrets_too_open


def test_secrets_too_open_flags_group_or_other_readable(tmp_path: Path) -> None:
    p = tmp_path / "secrets.env"
    p.write_text("NOTION_TOKEN=x\n", encoding="utf-8")
    os.chmod(p, 0o644)
    assert _secrets_too_open(p) is True
    os.chmod(p, 0o640)  # group-read only is still too open
    assert _secrets_too_open(p) is True


def test_secrets_0600_is_not_too_open(tmp_path: Path) -> None:
    p = tmp_path / "secrets.env"
    p.write_text("NOTION_TOKEN=x\n", encoding="utf-8")
    os.chmod(p, 0o600)
    assert _secrets_too_open(p) is False


def test_secrets_missing_file_is_not_flagged(tmp_path: Path) -> None:
    assert _secrets_too_open(tmp_path / "nope.env") is False
