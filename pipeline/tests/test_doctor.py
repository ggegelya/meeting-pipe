"""Unit tests for `mp doctor` log-parsing helpers.

The live HTTP probes (Anthropic / Notion / HuggingFace) aren't exercised
here — those are covered by `mp doctor` against real keys when the user
runs it. What's worth testing is the pure-string TCC log parser, since
that's the surface whose regression would silently regress the
"speaker recognition broken" diagnosis we just landed.
"""
from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from mp import storage
from mp.config import Config
from mp.doctor import (
    _estimate_model_gb,
    _scan_recorder_log_for_tcc,
    check_last_backup,
    check_library_sync,
    check_local_stack,
    check_storage,
)
from mp.doctor import main as doctor_main


def _write_log(tmp_path: Path, lines: list[str]) -> Path:
    p = tmp_path / "recorder.log"
    p.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return p


def test_returns_none_when_log_missing(tmp_path: Path) -> None:
    assert _scan_recorder_log_for_tcc(tmp_path / "absent.log") is None


def test_returns_none_when_log_has_no_scstream_lines(tmp_path: Path) -> None:
    p = _write_log(tmp_path, [
        "[2026-04-30T13:30:50.650Z] start: final=meet.wav mic=meet.mic.wav",
        "[2026-04-30T13:30:54.027Z] engine started",
    ])
    assert _scan_recorder_log_for_tcc(p) is None


def test_detects_prewarm_denial(tmp_path: Path) -> None:
    line = (
        "[2026-04-30T12:41:05.150Z] WARN: SCShareableContent prewarm failed: "
        "The user declined TCCs for application, window, display capture"
    )
    p = _write_log(tmp_path, [line])
    out = _scan_recorder_log_for_tcc(p)
    assert out is not None
    assert "declined TCCs" in out


def test_detects_stream_start_denial(tmp_path: Path) -> None:
    line = (
        "[2026-04-30T13:30:54.146Z] WARN: SCStream start failed: "
        "The user declined TCCs for application, window, display capture — recording mic-only"
    )
    p = _write_log(tmp_path, [line])
    out = _scan_recorder_log_for_tcc(p)
    assert out is not None
    assert "SCStream start failed" in out


def test_returns_most_recent_when_status_changed(tmp_path: Path) -> None:
    """When the user fixed permission between runs, the newest line wins."""
    p = _write_log(tmp_path, [
        "[2026-04-30T12:41:05.150Z] WARN: SCShareableContent prewarm failed: declined TCCs",
        "[2026-04-30T13:00:00.000Z] some unrelated line",
        "[2026-04-30T14:00:00.000Z] SCStream start ok",
    ])
    out = _scan_recorder_log_for_tcc(p)
    assert out is not None
    # Newest first — the OK line is what surfaces.
    assert "SCStream start ok" in out
    assert "declined TCCs" not in out


def test_handles_unreadable_log_gracefully(tmp_path: Path, monkeypatch) -> None:
    p = tmp_path / "recorder.log"
    p.write_text("placeholder", encoding="utf-8")

    def raise_oserror(*args, **kwargs):
        raise OSError("simulated read failure")

    monkeypatch.setattr(Path, "read_text", raise_oserror)
    assert _scan_recorder_log_for_tcc(p) is None


# ---------- local-stack preflight (LOCAL4) ----------------------------------


@pytest.mark.parametrize("model_id,expected", [
    ("mlx-community/Qwen2.5-3B-Instruct-4bit", 1.9),
    ("mlx-community/Qwen2.5-7B-Instruct-4bit", 4.3),
    ("mlx-community/Qwen2.5-14B-Instruct-4bit", 8.7),
    ("mlx-community/Qwen2.5-32B-Instruct-4bit", 19.8),
    ("mlx-community/gemma-2-9b-it-4bit", 5.6),
])
def test_estimate_model_gb_parses_param_count(model_id: str, expected: float) -> None:
    assert _estimate_model_gb(model_id) == expected


def test_estimate_model_gb_ignores_the_quant_suffix() -> None:
    # "4bit" must not be read as a 4B parameter count.
    assert _estimate_model_gb("mlx-community/some-instruct-4bit") is None


def test_check_local_stack_skips_for_cloud_backend(capsys, tmp_path) -> None:
    cfg = Config.model_validate({"summarization": {"backend": "anthropic"}})
    check_local_stack(cfg, workflows_dir=tmp_path / "none")
    assert "local stack not used" in capsys.readouterr().out


def test_check_local_stack_runs_when_a_workflow_forces_local(capsys, tmp_path, monkeypatch) -> None:
    # UX21: a global anthropic backend must not skip the stack when a workflow
    # pins local (or is NDA) - that workflow's first meeting still hits it.
    workflows_dir = tmp_path / "workflows"
    workflows_dir.mkdir()
    (workflows_dir / "client.toml").write_text(
        'name = "Client"\nbackend = "local"\n\n[flags]\nnda_mode = false\n', encoding="utf-8"
    )
    cfg = Config.model_validate({
        "summarization": {"backend": "anthropic", "local_model": "mlx-community/Qwen2.5-7B-Instruct-4bit"},
    })
    monkeypatch.setattr("mp.doctor._physical_ram_gb", lambda: 64.0)
    monkeypatch.setattr("mp.doctor._free_disk_gb", lambda _p: 500.0)
    monkeypatch.setattr("mp.prefetch_model._bytes_on_disk", lambda _p: 0)
    check_local_stack(cfg, workflows_dir=workflows_dir)
    out = capsys.readouterr().out
    assert "local stack not used" not in out
    assert "a workflow forces local: Client" in out


def test_check_local_stack_fails_when_ram_below_model(capsys, monkeypatch) -> None:
    cfg = Config.model_validate({
        "summarization": {
            "backend": "local",
            "local_model": "mlx-community/Qwen2.5-14B-Instruct-4bit",
        },
    })
    monkeypatch.setattr("mp.doctor._physical_ram_gb", lambda: 4.0)
    monkeypatch.setattr("mp.doctor._free_disk_gb", lambda _p: 500.0)
    monkeypatch.setattr("mp.prefetch_model._bytes_on_disk", lambda _p: 0)
    check_local_stack(cfg)
    out = capsys.readouterr().out
    assert "will not fit" in out
    assert "fits the ~21.0 GB download" not in out  # 14B is ~8.7 GB, not 21


def test_check_local_stack_ok_when_ram_and_disk_ample(capsys, monkeypatch) -> None:
    cfg = Config.model_validate({
        "summarization": {
            "backend": "local",
            "local_model": "mlx-community/Qwen2.5-7B-Instruct-4bit",
        },
    })
    monkeypatch.setattr("mp.doctor._physical_ram_gb", lambda: 64.0)
    monkeypatch.setattr("mp.doctor._free_disk_gb", lambda _p: 500.0)
    monkeypatch.setattr("mp.prefetch_model._bytes_on_disk", lambda _p: 0)
    check_local_stack(cfg)
    out = capsys.readouterr().out
    assert "comfortably fits" in out


# ---------- storage (STOR1) --------------------------------------------------


def _storage_cfg(library: Path) -> Config:
    return Config.model_validate({"recording": {"output_dir": str(library)}})


def test_check_storage_reports_the_library_size(capsys, tmp_path, monkeypatch) -> None:
    library = tmp_path / "Meetings" / "raw"
    library.mkdir(parents=True)
    (library / "20260101-120000.wav").write_bytes(b"x" * 1_500_000)
    monkeypatch.setattr("mp.storage.free_bytes", lambda _p: 500 * 1000 ** 3)

    check_storage(_storage_cfg(library), home=tmp_path)
    out = capsys.readouterr().out
    assert "[ OK ] library 1.5 MB" in out
    assert "[ OK ] free disk 500.0 GB" in out


def test_check_storage_warns_on_a_nearly_full_disk(capsys, tmp_path, monkeypatch) -> None:
    library = tmp_path / "raw"
    library.mkdir()
    monkeypatch.setattr("mp.storage.free_bytes", lambda _p: 2 * 1000 ** 3)

    check_storage(_storage_cfg(library), home=tmp_path)
    out = capsys.readouterr().out
    assert "[WARN] free disk 2.0 GB" in out
    assert "audio retention policy" in out


def test_check_storage_tolerates_a_library_that_does_not_exist_yet(capsys, tmp_path) -> None:
    check_storage(_storage_cfg(tmp_path / "never" / "recorded"), home=tmp_path)
    out = capsys.readouterr().out
    assert "does not exist yet" in out


def test_check_storage_without_config_warns_and_returns(capsys) -> None:
    check_storage(None)
    assert "[WARN] config did not load" in capsys.readouterr().out


# ---------- cloud-sync egress check (SEC12) ----------------------------------


def _synced_library(tmp_path: Path) -> Path:
    """A library inside a fake `~/Library/CloudStorage/Dropbox-Personal`."""
    library = tmp_path / "Library" / "CloudStorage" / "Dropbox-Personal" / "Meetings" / "raw"
    library.mkdir(parents=True)
    return library


def _nda_workflows(tmp_path: Path) -> Path:
    directory = tmp_path / "workflows"
    directory.mkdir()
    (directory / "secret.toml").write_text(
        'name = "Client X"\n\n[flags]\nnda_mode = true\n', encoding="utf-8"
    )
    return directory


def test_check_library_sync_is_ok_for_a_local_library(capsys, tmp_path) -> None:
    library = tmp_path / "Meetings" / "raw"
    library.mkdir(parents=True)
    check_library_sync(_storage_cfg(library), home=tmp_path, workflows_dir=tmp_path / "none")
    assert "[ OK ] no meeting data is inside a cloud-sync folder" in capsys.readouterr().out


def test_check_library_sync_warns_when_synced_and_nothing_promises_zero_egress(
    capsys, tmp_path
) -> None:
    check_library_sync(
        _storage_cfg(_synced_library(tmp_path)), home=tmp_path, workflows_dir=tmp_path / "none"
    )
    out = capsys.readouterr().out
    assert "[WARN] library is synced to Dropbox" in out
    assert "[FAIL]" not in out


def test_check_library_sync_fails_under_regulated_mode(capsys, tmp_path) -> None:
    cfg = Config.model_validate({
        "recording": {"output_dir": str(_synced_library(tmp_path))},
        "modes": {"regulated_mode": True},
    })
    check_library_sync(cfg, home=tmp_path, workflows_dir=tmp_path / "none")
    out = capsys.readouterr().out
    assert "[FAIL] library is synced to Dropbox" in out
    assert "regulated_mode is ON" in out


def test_check_library_sync_fails_when_any_nda_workflow_exists(capsys, tmp_path) -> None:
    check_library_sync(
        _storage_cfg(_synced_library(tmp_path)),
        home=tmp_path,
        workflows_dir=_nda_workflows(tmp_path),
    )
    out = capsys.readouterr().out
    assert "[FAIL] library is synced to Dropbox" in out
    assert "NDA workflows: Client X" in out


def test_check_library_sync_flags_the_published_sink_separately(capsys, tmp_path) -> None:
    # The daemon's assisted move relocates the recordings and digests, not the
    # filesystem sink. A summary left inside iCloud has to still be visible.
    local_library = tmp_path / "Meetings" / "raw"
    local_library.mkdir(parents=True)
    published = tmp_path / "Library" / "CloudStorage" / "OneDrive-Contoso" / "published"
    published.mkdir(parents=True)
    cfg = Config.model_validate({
        "recording": {"output_dir": str(local_library)},
        "output": {"sinks": ["filesystem"]},
        "filesystem": {"output_dir": str(published)},
    })
    check_library_sync(cfg, home=tmp_path, workflows_dir=tmp_path / "none")
    out = capsys.readouterr().out
    assert "[WARN] published summaries is synced to OneDrive" in out


def test_check_library_sync_deduplicates_roots_in_one_synced_tree(capsys, tmp_path) -> None:
    # library + digests are siblings; saying it twice is noise.
    root = tmp_path / "Library" / "CloudStorage" / "Dropbox-Personal" / "Meetings"
    (root / "raw").mkdir(parents=True)
    (root / "digests").mkdir()
    check_library_sync(_storage_cfg(root / "raw"), home=tmp_path, workflows_dir=tmp_path / "none")
    out = capsys.readouterr().out
    assert out.count("synced to Dropbox") == 1


# ---------- last-backup age (STOR2) ------------------------------------------


def _stamp_backup(home: Path, at: datetime, *, audio: bool = True) -> None:
    marker = storage.backup_marker(home)
    marker.parent.mkdir(parents=True, exist_ok=True)
    marker.write_text(json.dumps({
        "at": at.isoformat(), "archive": "/backups/x.tar.gz", "audio_included": audio,
    }))


def test_check_last_backup_reports_the_age(capsys, tmp_path) -> None:
    now = datetime(2026, 7, 10, tzinfo=timezone.utc)
    _stamp_backup(tmp_path, now - timedelta(days=3))
    check_last_backup(home=tmp_path, now=now)
    out = capsys.readouterr().out
    assert "last backup 3 days ago" in out
    assert "/backups/x.tar.gz" in out


def test_check_last_backup_says_today_and_flags_a_no_audio_backup(capsys, tmp_path) -> None:
    now = datetime(2026, 7, 10, 12, tzinfo=timezone.utc)
    _stamp_backup(tmp_path, now - timedelta(hours=2), audio=False)
    check_last_backup(home=tmp_path, now=now)
    out = capsys.readouterr().out
    assert "last backup today, without recordings" in out


def test_check_last_backup_without_a_marker_points_at_the_runbook(capsys, tmp_path) -> None:
    check_last_backup(home=tmp_path)
    assert "no `mp backup` has run on this Mac" in capsys.readouterr().out


def test_check_last_backup_tolerates_a_corrupt_marker(capsys, tmp_path) -> None:
    marker = storage.backup_marker(tmp_path)
    marker.parent.mkdir(parents=True, exist_ok=True)
    marker.write_text("not json")
    check_last_backup(home=tmp_path)
    assert "no `mp backup` has run" in capsys.readouterr().out


def test_doctor_main_still_exits_zero_on_a_hard_fail(monkeypatch, tmp_path) -> None:
    # Doctor is a diagnostic, not a gate. SEC12's FAIL is a marker, not an exit
    # code; callers grep for "[FAIL]". Breaking that would break every existing
    # invocation on a half-configured Mac.
    cfg = Config.model_validate({
        "recording": {"output_dir": str(_synced_library(tmp_path))},
        "modes": {"regulated_mode": True},
    })
    monkeypatch.setattr("mp.doctor.check_secrets", lambda: dict.fromkeys(
        ["ANTHROPIC_API_KEY", "NOTION_TOKEN", "HF_TOKEN"], False
    ))
    monkeypatch.setattr("mp.doctor.check_config", lambda: cfg)
    monkeypatch.setattr("mp.doctor.check_ml_runtimes", lambda: None)
    monkeypatch.setattr("mp.doctor.check_local_stack", lambda _cfg: None)
    monkeypatch.setattr("mp.doctor.check_screen_recording", lambda: None)
    monkeypatch.setattr("mp.doctor.check_storage", lambda _cfg, home=None: check_library_sync(
        cfg, home=tmp_path, workflows_dir=tmp_path / "none"
    ))
    assert doctor_main([]) == 0
