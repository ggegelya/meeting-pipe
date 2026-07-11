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


# CI2: the cross-language contract fixtures. These committed files live next to
# the Swift suite (written + verified there by MetaContractFixtureTests) and are
# asserted here through the real reader, so one checked-in file pins both sides.
# A Swift-side key rename regenerates the fixture and breaks these expectations;
# a Python-side drift breaks because apply_overrides no longer finds the key the
# fixture carries. Each fixture is named `<stem>.meta.json`, so passing its own
# path to apply_overrides resolves the sibling `<stem>.meta.json` back to itself.
_CONTRACT = (
    Path(__file__).resolve().parents[2]
    / "daemon" / "Tests" / "MeetingPipeTests" / "Fixtures" / "meta-contract"
)


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


def test_regulated_mode_from_sidecar_forces_local_and_filesystem(tmp_path: Path) -> None:
    # TECH-DSN6: a meeting recorded under global regulated mode persists
    # `regulated_mode` in the sidecar. A reprocess stays zero-egress (fail-closed)
    # even when the current global config has regulated_mode off (the default).
    cfg = Config()
    assert cfg.modes.regulated_mode is False
    stem = "20260512-080000"
    _write_meta(tmp_path, stem, {
        "regulated_mode": True,
        # Leaked cloud backend/sinks must still be overridden.
        "workflow_backend": "anthropic",
        "workflow_sinks": ["notion"],
    })
    wav = tmp_path / f"{stem}.wav"
    wav.write_bytes(b"")
    result = apply_overrides(cfg, wav)
    assert result.modes.regulated_mode is True
    assert result.summarization.backend == "local"
    assert result.output.sinks == ["filesystem"]
    # Original cfg untouched.
    assert cfg.modes.regulated_mode is False


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


def test_missing_backend_key_preserves_global_default(tmp_path: Path) -> None:
    # The inherit contract (TECH-WF1): when the daemon omits workflow_backend
    # because the workflow inherits the global default, the overlay must leave
    # summarization.backend untouched, so a global apple_intelligence setting
    # stays in effect for the run.
    cfg = Config.model_validate({"summarization": {"backend": "apple_intelligence"}})
    stem = "20260512-inherit"
    _write_meta(tmp_path, stem, {
        "workflow_context_prompt": "no backend pinned",
        # intentionally no workflow_backend key
    })
    wav = tmp_path / f"{stem}.wav"
    wav.write_bytes(b"")
    result = apply_overrides(cfg, wav)
    assert result.summarization.backend == "apple_intelligence"
    assert result.summarization.team_context == "no backend pinned"


def test_apple_intelligence_backend_override_applies(tmp_path: Path) -> None:
    # A workflow that pins apple_intelligence overrides a global anthropic.
    cfg = Config()  # default backend is anthropic
    stem = "20260512-apple"
    _write_meta(tmp_path, stem, {"workflow_backend": "apple_intelligence"})
    wav = tmp_path / f"{stem}.wav"
    wav.write_bytes(b"")
    result = apply_overrides(cfg, wav)
    assert result.summarization.backend == "apple_intelligence"


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


def test_overlay_does_not_carry_action_state(tmp_path: Path) -> None:
    # AI1: action-item resolved state lives in <stem>.summary.json (read by the
    # summary schema on both sides), NOT in the meta.json workflow sidecar. The
    # overlay must not invent or strip it; it only patches config-shaped keys.
    # This pins the contract boundary so a future meta.json key never starts
    # shadowing per-action state.
    cfg = Config()
    stem = "20260512-actionstate"
    _write_meta(tmp_path, stem, {
        "workflow_context_prompt": "ctx",
        # A stray action-shaped key in meta.json must be inert.
        "resolved": True,
        "actions": [{"task": "should be ignored", "resolved": True}],
    })
    summary = tmp_path / f"{stem}.summary.json"
    summary.write_text("{}", encoding="utf-8")
    result = apply_overrides(cfg, summary)
    assert result.summarization.team_context == "ctx"
    assert not hasattr(result, "actions")


def test_contract_fixture_full_workflow_applies_overlay() -> None:
    # The committed golden sidecar -> the keys the reader maps. If Swift renames
    # any of these keys (and regenerates the fixture), this assertion fails.
    cfg = Config()
    result = apply_overrides(cfg, _CONTRACT / "workflow-full.meta.json")
    assert result.summarization.backend == "anthropic"
    assert result.output.sinks == ["notion", "obsidian"]
    assert result.summarization.team_context == "Acme account. Weekly cadence."
    assert result.notion.database_id == "db-acme-123"


def test_contract_fixture_nda_collapses_to_local_filesystem() -> None:
    cfg = Config()
    result = apply_overrides(cfg, _CONTRACT / "workflow-nda.meta.json")
    assert result.modes.workflow_nda_mode is True
    assert result.summarization.backend == "local"
    assert result.output.sinks == ["filesystem"]


def test_contract_fixture_regulated_source_only_forces_zero_egress() -> None:
    cfg = Config()
    assert cfg.modes.regulated_mode is False
    result = apply_overrides(cfg, _CONTRACT / "source-only-regulated.meta.json")
    assert result.modes.regulated_mode is True
    assert result.summarization.backend == "local"
    assert result.output.sinks == ["filesystem"]


def test_contract_fixture_reassigned_into_nda_forces_local_filesystem() -> None:
    # WF8: a cloud-recorded meeting (Chrome source) reassigned to the NDA workflow.
    # The reader must honour the post-hoc NDA block: local backend, filesystem only,
    # and no leftover Notion database from the old cloud workflow.
    cfg = Config()
    result = apply_overrides(cfg, _CONTRACT / "workflow-reassigned-to-nda.meta.json")
    assert result.modes.workflow_nda_mode is True
    assert result.summarization.backend == "local"
    assert result.output.sinks == ["filesystem"]
    assert result.notion.database_id in (None, "")


def test_contract_fixtures_carry_schema_version() -> None:
    for name in (
        "source-only-regulated", "workflow-full", "workflow-nda", "workflow-reassigned-to-nda"
    ):
        data = json.loads((_CONTRACT / f"{name}.meta.json").read_text(encoding="utf-8"))
        assert data["schema_version"] == 1
