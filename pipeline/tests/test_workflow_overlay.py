"""Pipeline-side workflow overlay (TECH-B4).

The daemon writes per-meeting overrides into `<stem>.meta.json`. The
overlay reads that sidecar and returns a cfg with `team_context`,
`backend`, `sinks`, and `notion.database_id` already patched for the
single run. The rest of the pipeline never has to know workflows exist.
"""
from __future__ import annotations

import json
from pathlib import Path

from mp.config import Config
from mp.workflow import apply_overrides


def _write_meta(dir: Path, stem: str, data: dict) -> None:
    (dir / f"{stem}.meta.json").write_text(json.dumps(data), encoding="utf-8")


def test_no_sidecar_returns_unchanged_cfg(tmp_path: Path) -> None:
    cfg = Config()
    wav = tmp_path / "20260512-101530.wav"
    wav.write_bytes(b"")
    result = apply_overrides(cfg, wav)
    # Same value semantics. We don't require identity because
    # `apply_overrides` deep-copies on the side of caution.
    assert result.summarization.team_context == cfg.summarization.team_context
    assert result.summarization.backend == cfg.summarization.backend
    assert result.output.sinks == cfg.output.sinks


def test_overlay_applies_context_backend_sinks_db(tmp_path: Path) -> None:
    cfg = Config()
    stem = "20260512-101530"
    _write_meta(tmp_path, stem, {
        "workflow_id": "abc",
        "workflow_name": "Client",
        "workflow_context_prompt": "Confidential client meeting.",
        "workflow_backend": "local",
        "workflow_sinks": ["filesystem", "obsidian"],
        "workflow_notion_database_id": "newdb999",
    })
    wav = tmp_path / f"{stem}.wav"
    wav.write_bytes(b"")
    result = apply_overrides(cfg, wav)
    assert result.summarization.team_context == "Confidential client meeting."
    assert result.summarization.backend == "local"
    assert result.output.sinks == ["filesystem", "obsidian"]
    assert result.notion.database_id == "newdb999"
    # Original unchanged.
    assert cfg.summarization.team_context == ""


def test_nda_mode_forces_local_and_filesystem(tmp_path: Path) -> None:
    cfg = Config()
    stem = "20260512-090000"
    _write_meta(tmp_path, stem, {
        "workflow_nda_mode": True,
        # Inconsistent backend+sinks on purpose — NDA must override even
        # if the daemon-supplied workflow leaked anthropic / notion.
        "workflow_backend": "anthropic",
        "workflow_sinks": ["notion"],
    })
    wav = tmp_path / f"{stem}.wav"
    wav.write_bytes(b"")
    result = apply_overrides(cfg, wav)
    assert result.summarization.backend == "local"
    assert result.output.sinks == ["filesystem"]


def test_overlay_works_for_summary_and_transcript_paths(tmp_path: Path) -> None:
    cfg = Config()
    stem = "20260512-101530"
    _write_meta(tmp_path, stem, {"workflow_context_prompt": "Test seasoning"})
    summary = tmp_path / f"{stem}.summary.json"
    summary.write_text("{}", encoding="utf-8")
    transcript = tmp_path / f"{stem}.md"
    transcript.write_text("# x", encoding="utf-8")
    # Both must hit the same sidecar via the stem-before-first-dot rule.
    assert apply_overrides(cfg, summary).summarization.team_context == "Test seasoning"
    assert apply_overrides(cfg, transcript).summarization.team_context == "Test seasoning"


def test_malformed_sidecar_yields_unchanged_cfg(tmp_path: Path) -> None:
    cfg = Config()
    stem = "20260512-broken"
    (tmp_path / f"{stem}.meta.json").write_text("{not json", encoding="utf-8")
    wav = tmp_path / f"{stem}.wav"
    wav.write_bytes(b"")
    result = apply_overrides(cfg, wav)
    assert result.summarization.team_context == cfg.summarization.team_context


def test_unknown_backend_value_is_ignored(tmp_path: Path) -> None:
    cfg = Config()
    stem = "20260512-bad"
    _write_meta(tmp_path, stem, {"workflow_backend": "nonsense"})
    wav = tmp_path / f"{stem}.wav"
    wav.write_bytes(b"")
    result = apply_overrides(cfg, wav)
    assert result.summarization.backend == cfg.summarization.backend


def test_empty_sinks_list_is_ignored(tmp_path: Path) -> None:
    # A workflow that ended up with no sinks (UI bug, hand-edited TOML)
    # must not silently strip publishing. Fall back to the global default.
    cfg = Config()
    stem = "20260512-emptysinks"
    _write_meta(tmp_path, stem, {"workflow_sinks": []})
    wav = tmp_path / f"{stem}.wav"
    wav.write_bytes(b"")
    result = apply_overrides(cfg, wav)
    assert result.output.sinks == cfg.output.sinks
