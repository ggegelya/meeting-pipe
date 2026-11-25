"""Unit tests for `mp doctor` log-parsing helpers.

The live HTTP probes (Anthropic / Notion / HuggingFace) aren't exercised
here — those are covered by `mp doctor` against real keys when the user
runs it. What's worth testing is the pure-string TCC log parser, since
that's the surface whose regression would silently regress the
"speaker recognition broken" diagnosis we just landed.
"""
from __future__ import annotations

import json
from datetime import UTC, datetime, timedelta
from pathlib import Path

from mp import storage
from mp.config import Config
from mp.doctor import (
    _report_local_server_identity,
    _scan_recorder_log_for_tcc,
    check_app_index,
    check_last_backup,
    check_library_sync,
    check_local_stack,
    check_storage,
    check_workflow_files,
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


# The model-size estimate moved to `mp.resource_guard` with LOCAL16 (doctor is
# no longer its only reader); its table lives in `test_resource_guard.py`.


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
        'id = "aaaaaaaa-0000-0000-0000-000000000001"\nname = "Client"\nbackend = "local"\n\n[flags]\nnda_mode = false\n', encoding="utf-8"
    )
    cfg = Config.model_validate({
        "summarization": {"backend": "anthropic", "local_model": "mlx-community/Qwen2.5-7B-Instruct-4bit"},
    })
    monkeypatch.setattr("mp.resource_guard.physical_ram_gb", lambda: 64.0)
    monkeypatch.setattr("mp.doctor._free_disk_gb", lambda _p: 500.0)
    monkeypatch.setattr("mp.storage.bytes_on_disk", lambda _p: 0)
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
    monkeypatch.setattr("mp.resource_guard.physical_ram_gb", lambda: 4.0)
    monkeypatch.setattr("mp.doctor._free_disk_gb", lambda _p: 500.0)
    monkeypatch.setattr("mp.storage.bytes_on_disk", lambda _p: 0)
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
    monkeypatch.setattr("mp.resource_guard.physical_ram_gb", lambda: 64.0)
    monkeypatch.setattr("mp.doctor._free_disk_gb", lambda _p: 500.0)
    monkeypatch.setattr("mp.storage.bytes_on_disk", lambda _p: 0)
    check_local_stack(cfg)
    out = capsys.readouterr().out
    assert "comfortably fits" in out


def _doctor_cfg(model: str) -> Config:
    return Config.model_validate({"summarization": {"backend": "local", "local_model": model}})


def test_check_local_stack_is_ok_for_a_pinned_snapshot(capsys, monkeypatch, tmp_path) -> None:
    """SEC27: the question is whether the pinned snapshot is servable, not whether
    some bytes are cached."""
    from mp import local_snapshot

    repo = "mlx-community/Qwen2.5-3B-Instruct-4bit"
    monkeypatch.setattr(Path, "home", classmethod(lambda cls: tmp_path))
    monkeypatch.setattr("mp.resource_guard.physical_ram_gb", lambda: 64.0)
    snap = local_snapshot.hf_cache_dir(repo, tmp_path) / "snapshots" / local_snapshot.PINNED_REVISIONS[repo]
    snap.mkdir(parents=True)
    (snap / "config.json").write_text("{}")
    (snap / "model.safetensors").write_bytes(b"w")
    check_local_stack(_doctor_cfg(repo))
    assert "pinned model snapshot present" in capsys.readouterr().out


def test_check_local_stack_warns_when_the_cache_is_at_another_revision(
    capsys, monkeypatch, tmp_path
) -> None:
    from mp import local_snapshot

    repo = "mlx-community/Qwen2.5-3B-Instruct-4bit"
    monkeypatch.setattr(Path, "home", classmethod(lambda cls: tmp_path))
    monkeypatch.setattr("mp.resource_guard.physical_ram_gb", lambda: 64.0)
    monkeypatch.setattr("mp.storage.bytes_on_disk", lambda _p: 3 * 1024 ** 3)
    snap = local_snapshot.hf_cache_dir(repo, tmp_path) / "snapshots" / ("f" * 40)
    snap.mkdir(parents=True)
    check_local_stack(_doctor_cfg(repo))
    out = capsys.readouterr().out
    assert "not at the pinned revision" in out and f"mp prefetch-model {repo}" in out


def test_check_local_stack_fails_on_a_snapshot_that_carries_code(
    capsys, monkeypatch, tmp_path
) -> None:
    from mp import local_snapshot

    repo = "mlx-community/Qwen2.5-3B-Instruct-4bit"
    monkeypatch.setattr(Path, "home", classmethod(lambda cls: tmp_path))
    monkeypatch.setattr("mp.resource_guard.physical_ram_gb", lambda: 64.0)
    snap = local_snapshot.hf_cache_dir(repo, tmp_path) / "snapshots" / local_snapshot.PINNED_REVISIONS[repo]
    snap.mkdir(parents=True)
    (snap / "config.json").write_text(json.dumps({"model_file": "x.py"}))
    check_local_stack(_doctor_cfg(repo))
    assert "snapshot refused" in capsys.readouterr().out


def test_identity_probe_fails_loudly_on_a_foreign_listener(capsys, monkeypatch) -> None:
    from mp import local_server

    ident = local_server.ServedIdentity(
        pid=9, model=None, adapter_path=None, source="foreign", command="/usr/bin/socat"
    )
    monkeypatch.setattr("mp.local_server.served_identity", lambda _port, home=None: ident)
    from mp.doctor import check_local_server

    check_local_server(Config.model_validate({"summarization": {"backend": "local"}}))
    out = capsys.readouterr().out
    assert "not the local model server" in out and "socat" in out


# ---------- storage (STOR1) --------------------------------------------------


def _storage_cfg(library: Path) -> Config:
    # The published folder is pinned beside the library: its default is under the REAL home,
    # and since SEC35 doctor looks at it whenever it holds files, which would make these tests
    # depend on the machine that runs them.
    return Config.model_validate({
        "recording": {"output_dir": str(library)},
        "filesystem": {"output_dir": str(library.parent / "published-elsewhere")},
    })


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


def _grow(library: Path, stem: str, size: int) -> None:
    (library / f"{stem}.wav").write_bytes(b"x" * size)
    (library / f"{stem}.summary.json").write_bytes(b"{}")


def test_library_growth_counts_the_window_by_stem_prefix(tmp_path) -> None:
    library = tmp_path / "raw"
    library.mkdir()
    _grow(library, "20261110-090000", 1_000)                  # inside: wav + 2-byte sidecar
    (library / "20261101-090000 Export.wav").write_bytes(b"x" * 500)  # titled stem, inside
    _grow(library, "20260901-090000", 99_000)                 # outside the window
    (library / "notes.txt").write_bytes(b"x" * 77)            # not a stem
    (library / "sub").mkdir()
    (library / "sub" / "20261110-090000.wav").write_bytes(b"x" * 77)  # not top-level
    for suffix in ("mic.wav", "system.wav", "merging.wav"):  # a recording in progress
        (library / f"20261111-090000.{suffix}").write_bytes(b"x" * 77)
    now = datetime(2026, 11, 12, 12, 0, 0)
    assert storage.library_growth(library, now=now) == 1_000 + 2 + 500


def test_doctor_warns_when_the_growth_rate_fills_the_disk_within_30_days(capsys, tmp_path, monkeypatch) -> None:
    library = tmp_path / "raw"
    library.mkdir()
    _grow(library, "20261110-090000", 3_000_000)
    # 3 MB a month is 100 KB a day; 2 MB free lasts about 20 days.
    monkeypatch.setattr("mp.storage.free_bytes", lambda _p: 2_000_000)
    check_storage(_storage_cfg(library), home=tmp_path, now=datetime(2026, 11, 12, 12, 0, 0))
    out = capsys.readouterr().out
    assert "[WARN] library grew 3.0 MB in the last 30 days; at that rate the free space lasts about 19 days" in out


def test_doctor_does_not_warn_when_the_growth_rate_leaves_over_30_days(capsys, tmp_path, monkeypatch) -> None:
    library = tmp_path / "raw"
    library.mkdir()
    _grow(library, "20261110-090000", 3_000_000)
    monkeypatch.setattr("mp.storage.free_bytes", lambda _p: 500 * 1000 ** 3)
    check_storage(_storage_cfg(library), home=tmp_path, now=datetime(2026, 11, 12, 12, 0, 0))
    out = capsys.readouterr().out
    assert "[ OK ] library grew 3.0 MB in the last 30 days; at that rate the free space lasts about" in out
    assert "lasts about" in out and "[WARN] library grew" not in out


def test_doctor_has_no_projection_without_recent_meetings(capsys, tmp_path, monkeypatch) -> None:
    library = tmp_path / "raw"
    library.mkdir()
    _grow(library, "20250101-090000", 3_000_000)
    monkeypatch.setattr("mp.storage.free_bytes", lambda _p: 1_000)
    check_storage(_storage_cfg(library), home=tmp_path, now=datetime(2026, 11, 12, 12, 0, 0))
    out = capsys.readouterr().out
    assert "no meetings in the last 30 days" in out


def test_days_of_free_space_has_no_answer_without_growth_or_free_space() -> None:
    assert storage.days_of_free_space(0, 100) is None
    assert storage.days_of_free_space(30, None) is None
    assert storage.days_of_free_space(30, 0) is None
    assert storage.days_of_free_space(30, 90) == 90


def test_check_storage_tolerates_a_library_that_does_not_exist_yet(capsys, tmp_path) -> None:
    check_storage(_storage_cfg(tmp_path / "never" / "recorded"), home=tmp_path)
    out = capsys.readouterr().out
    assert "does not exist yet" in out


def test_check_storage_warns_on_a_library_it_cannot_list(capsys, tmp_path, monkeypatch) -> None:
    # STOR11: rglob yields nothing for a folder it cannot list, so this printed `[ok] library 0 B`.
    library = tmp_path / "raw"
    library.mkdir()
    (library / "20260101-120000.wav").write_bytes(b"x" * 1000)
    monkeypatch.setattr("mp.storage.free_bytes", lambda _p: 500 * 1000 ** 3)
    library.chmod(0)
    try:
        check_storage(_storage_cfg(library), home=tmp_path)
    finally:
        library.chmod(0o700)
    out = capsys.readouterr().out
    assert "[WARN] library" in out and "cannot be listed" in out
    assert "library 0 B" not in out
    assert "[ OK ] library" not in out


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
        'id = "aaaaaaaa-0000-0000-0000-000000000002"\nname = "Client X"\n\n[flags]\nnda_mode = true\n', encoding="utf-8"
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
        "filesystem": {"output_dir": str(tmp_path / "published-elsewhere")},
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
    now = datetime(2026, 7, 10, tzinfo=UTC)
    _stamp_backup(tmp_path, now - timedelta(days=3))
    check_last_backup(home=tmp_path, now=now)
    out = capsys.readouterr().out
    assert "last backup 3 days ago" in out
    assert "/backups/x.tar.gz" in out


def test_check_last_backup_says_today_and_flags_a_no_audio_backup(capsys, tmp_path) -> None:
    now = datetime(2026, 7, 10, 12, tzinfo=UTC)
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
        "filesystem": {"output_dir": str(tmp_path / "published-elsewhere")},
        "modes": {"regulated_mode": True},
    })
    monkeypatch.setattr("mp.doctor.check_secrets", lambda needed=None: dict.fromkeys(
        ["ANTHROPIC_API_KEY", "NOTION_TOKEN", "HF_TOKEN", "OPENAI_API_KEY"], False
    ))
    monkeypatch.setattr("mp.doctor.check_config", lambda: cfg)
    monkeypatch.setattr("mp.doctor.check_ml_runtimes", lambda: None)
    monkeypatch.setattr("mp.doctor.check_local_stack", lambda _cfg: None)
    monkeypatch.setattr("mp.doctor.check_screen_recording", lambda: None)
    monkeypatch.setattr("mp.doctor.check_storage", lambda _cfg, home=None: check_library_sync(
        cfg, home=tmp_path, workflows_dir=tmp_path / "none"
    ))
    assert doctor_main([]) == 0


# ----- LOCAL11: served-vs-configured identity -----


def _local_cfg(model: str = "some/model", adapter: str = "") -> Config:
    return Config.model_validate({
        "summarization": {
            "backend": "local",
            "local_model": model,
            "local_adapter_path": adapter,
            "local_endpoint": "http://127.0.0.1:8765",
        },
    })


def _fake_served(monkeypatch, identity) -> None:
    monkeypatch.setattr("mp.local_server.served_identity", lambda _port, home=None: identity)


def _identity(model: str | None, adapter: str | None = None):
    from mp import local_server
    return local_server.ServedIdentity(pid=4242, model=model, adapter_path=adapter, source="argv")


def test_identity_probe_is_quiet_when_nothing_is_listening(capsys, monkeypatch) -> None:
    _fake_served(monkeypatch, None)
    _report_local_server_identity(_local_cfg(), None)
    out = capsys.readouterr().out
    assert "[WARN]" not in out
    assert "nothing is serving on port 8765" in out


def test_identity_probe_confirms_a_matching_server(capsys, monkeypatch) -> None:
    _fake_served(monkeypatch, _identity("some/model"))
    _report_local_server_identity(_local_cfg(), None)
    out = capsys.readouterr().out
    assert "[WARN]" not in out
    assert "serves the configured some/model" in out


def test_identity_probe_names_a_stale_model(capsys, monkeypatch) -> None:
    """The acceptance case: the user flipped `local_model` and a warm server kept
    answering with the old weights. Doctor has to say so by name."""
    _fake_served(monkeypatch, _identity("stale/model"))
    _report_local_server_identity(_local_cfg(model="fresh/model"), None)
    out = capsys.readouterr().out
    assert "[WARN]" in out
    assert "serves stale/model" in out
    assert "config asks for fresh/model" in out


def test_identity_probe_names_a_missing_adapter(capsys, monkeypatch) -> None:
    """Same model, no adapter: without this, a LOCAL9 A/B cannot tell "the adapter
    did not help" from "the adapter never served"."""
    _fake_served(monkeypatch, _identity("some/model", adapter=None))
    _report_local_server_identity(_local_cfg(adapter="/adapters/lora"), None)
    out = capsys.readouterr().out
    assert "[WARN]" in out
    assert "/adapters/lora" in out


def test_identity_probe_is_silent_without_config(capsys, monkeypatch) -> None:
    _fake_served(monkeypatch, _identity("some/model"))
    _report_local_server_identity(None, None)
    assert capsys.readouterr().out == ""


# ---------- DIST3: the Spotlight index check --------------------------------
#
# The four states are deliberately four, not two. "Spotlight answered and does
# not know it" and "Spotlight could not be asked" are different facts, and
# collapsing the second into the first is how a void check gets reported as a
# real one, so each has its own test.


class _Proc:
    def __init__(self, stdout: str = "", returncode: int = 0) -> None:
        self.stdout = stdout
        self.returncode = returncode


def _bundle(tmp_path: Path, monkeypatch) -> Path:
    """An existing MeetingPipe.app under a fake home, so the check gets past
    its "nothing to index" branch."""
    app = tmp_path / "Applications" / "MeetingPipe.app"
    app.mkdir(parents=True)
    monkeypatch.setattr("mp.doctor._APP_BUNDLE", app)
    return app


def _fake_mdfind(monkeypatch, proc: _Proc | None, *, present: bool = True) -> None:
    monkeypatch.setattr("mp.doctor.os.access", lambda path, mode: present and path == "/usr/bin/mdfind")
    if proc is not None:
        monkeypatch.setattr("mp.doctor.subprocess.run", lambda *a, **k: proc)


def test_app_index_ok_when_spotlight_knows_the_bundle(tmp_path, monkeypatch, capsys) -> None:
    app = _bundle(tmp_path, monkeypatch)
    _fake_mdfind(monkeypatch, _Proc(stdout=f"{app}\n"))
    check_app_index()
    out = capsys.readouterr().out
    assert "[ OK ]" in out
    assert "[FAIL]" not in out


def test_app_index_fails_when_spotlight_answers_and_does_not_know_it(
    tmp_path, monkeypatch, capsys
) -> None:
    """The DIST3 bug itself: the bundle is on disk and Spotlight does not have
    it, so the app cannot be launched by name."""
    _bundle(tmp_path, monkeypatch)
    _fake_mdfind(monkeypatch, _Proc(stdout=""))
    check_app_index()
    out = capsys.readouterr().out
    assert "[FAIL]" in out
    assert "mdimport" in out
    # The remediation must stop short of repairing the volume index, which DIST3
    # puts out of scope as the owner's machine-level decision.
    assert "mdutil -s /" in out
    assert "mdutil -E" not in out


def test_app_index_reports_unknown_rather_than_missing_when_mdfind_is_absent(
    tmp_path, monkeypatch, capsys
) -> None:
    _bundle(tmp_path, monkeypatch)
    _fake_mdfind(monkeypatch, None, present=False)
    check_app_index()
    out = capsys.readouterr().out
    assert "[WARN]" in out
    assert "[FAIL]" not in out
    assert "not the same as 'not indexed'" in out


def test_app_index_reports_unknown_when_mdfind_exits_non_zero(
    tmp_path, monkeypatch, capsys
) -> None:
    _bundle(tmp_path, monkeypatch)
    _fake_mdfind(monkeypatch, _Proc(stdout="", returncode=1))
    check_app_index()
    out = capsys.readouterr().out
    assert "[WARN]" in out
    assert "[FAIL]" not in out


def test_app_index_reports_unknown_when_mdfind_raises(tmp_path, monkeypatch, capsys) -> None:
    _bundle(tmp_path, monkeypatch)
    monkeypatch.setattr("mp.doctor.os.access", lambda path, mode: True)

    def _boom(*_a, **_k):
        raise OSError("mdfind exploded")

    monkeypatch.setattr("mp.doctor.subprocess.run", _boom)
    check_app_index()
    out = capsys.readouterr().out
    assert "[WARN]" in out
    assert "[FAIL]" not in out


def test_app_index_skips_when_no_bundle_is_installed(tmp_path, monkeypatch, capsys) -> None:
    """Running from a build tree is normal and is not a failure."""
    monkeypatch.setattr("mp.doctor._APP_BUNDLE", tmp_path / "Applications" / "MeetingPipe.app")
    check_app_index()
    out = capsys.readouterr().out
    assert "nothing to index" in out
    assert "[FAIL]" not in out


def test_app_index_names_other_indexed_copies_when_ours_is_missing(
    tmp_path, monkeypatch, capsys
) -> None:
    """A stale copy elsewhere is the likeliest reason a search 'works' while the
    installed one is unfindable, so the check names what Spotlight does hold."""
    _bundle(tmp_path, monkeypatch)
    _fake_mdfind(monkeypatch, _Proc(stdout="/Applications/MeetingPipe.app\n"))
    check_app_index()
    out = capsys.readouterr().out
    assert "[FAIL]" in out
    assert "/Applications/MeetingPipe.app" in out


# ---------- SEC35: the other roots (published folder, backups, vault, LAN) -------------------


def _local_library(tmp_path: Path) -> Path:
    library = tmp_path / "Meetings" / "raw"
    library.mkdir(parents=True, exist_ok=True)
    return library


def _synced_published(tmp_path: Path) -> Path:
    published = tmp_path / "Library" / "CloudStorage" / "OneDrive-Contoso" / "published"
    published.mkdir(parents=True)
    return published


def _sec35_cfg(tmp_path: Path, published: Path | None = None, **extra) -> Config:
    return Config.model_validate({
        "recording": {"output_dir": str(_local_library(tmp_path))},
        "filesystem": {"output_dir": str(published or tmp_path / "published-local")},
        **extra,
    })


def _sink_workflow(tmp_path: Path, sink: str) -> Path:
    directory = tmp_path / "workflows"
    directory.mkdir(exist_ok=True)
    (directory / f"{sink}.toml").write_text(
        f'id = "aaaaaaaa-0000-0000-0000-{abs(hash(sink)) % 10**12:012d}"\nname = "uses {sink}"\n\n[[sinks]]\ntype = "{sink}"\n', encoding="utf-8")
    return directory


def test_an_nda_workflow_makes_a_synced_published_folder_a_fail_under_default_sinks(capsys, tmp_path) -> None:
    # The audit's reproduction: default sinks, a local library, the published folder in a synced
    # tree. apply_overrides forces every NDA meeting onto that folder, so it has to be checked.
    cfg = _sec35_cfg(tmp_path, _synced_published(tmp_path))
    check_library_sync(cfg, home=tmp_path, workflows_dir=_nda_workflows(tmp_path))
    out = capsys.readouterr().out
    assert "[FAIL] published summaries is synced to OneDrive" in out


def test_regulated_mode_makes_a_synced_published_folder_a_fail(capsys, tmp_path) -> None:
    cfg = _sec35_cfg(tmp_path, _synced_published(tmp_path), modes={"regulated_mode": True})
    check_library_sync(cfg, home=tmp_path, workflows_dir=tmp_path / "none")
    assert "[FAIL] published summaries is synced to OneDrive" in capsys.readouterr().out


def test_a_workflow_with_a_filesystem_sink_makes_the_published_folder_a_warn(capsys, tmp_path) -> None:
    cfg = _sec35_cfg(tmp_path, _synced_published(tmp_path))
    check_library_sync(cfg, home=tmp_path, workflows_dir=_sink_workflow(tmp_path, "filesystem"))
    out = capsys.readouterr().out
    assert "[WARN] published summaries is synced to OneDrive" in out
    assert "[FAIL]" not in out


def test_an_empty_or_absent_published_folder_adds_nothing_without_a_reason(capsys, tmp_path) -> None:
    published = _synced_published(tmp_path)        # exists, empty, no condition holds
    check_library_sync(_sec35_cfg(tmp_path, published), home=tmp_path, workflows_dir=tmp_path / "none")
    assert "[ OK ] no meeting data is inside a cloud-sync folder" in capsys.readouterr().out
    absent = tmp_path / "Library" / "CloudStorage" / "OneDrive-Contoso" / "never-made"
    check_library_sync(_sec35_cfg(tmp_path, absent), home=tmp_path, workflows_dir=tmp_path / "none")
    assert "[ OK ] no meeting data is inside a cloud-sync folder" in capsys.readouterr().out


def test_a_non_empty_published_folder_adds_the_root_even_with_no_condition(capsys, tmp_path) -> None:
    # The SEC25 fail-closed path and every earlier run leave files here with nothing in config
    # saying so.
    published = _synced_published(tmp_path)
    (published / "20261001-100000.summary.md").write_text("x")
    check_library_sync(_sec35_cfg(tmp_path, published), home=tmp_path, workflows_dir=tmp_path / "none")
    assert "[WARN] published summaries is synced to OneDrive" in capsys.readouterr().out


def _stamp_archive(tmp_path: Path, archive: str) -> None:
    marker = storage.backup_marker(tmp_path)
    marker.parent.mkdir(parents=True, exist_ok=True)
    marker.write_text(json.dumps({"at": datetime.now(UTC).isoformat(), "archive": archive}))


def test_a_backup_archive_in_a_synced_folder_is_a_backups_line(capsys, tmp_path) -> None:
    dest = tmp_path / "Library" / "CloudStorage" / "Dropbox-Personal" / "backups"
    dest.mkdir(parents=True)
    _stamp_archive(tmp_path, str(dest / "meeting-pipe-backup-20261101.tar.gz"))
    cfg = _sec35_cfg(tmp_path)
    check_library_sync(cfg, home=tmp_path, workflows_dir=tmp_path / "none")
    assert "[WARN] backups is synced to Dropbox" in capsys.readouterr().out
    check_library_sync(cfg, home=tmp_path, workflows_dir=_nda_workflows(tmp_path))
    assert "[FAIL] backups is synced to Dropbox" in capsys.readouterr().out


def test_a_backup_agent_destination_in_a_synced_folder_is_a_backups_line(capsys, tmp_path) -> None:
    import plistlib

    dest = tmp_path / "Library" / "CloudStorage" / "Dropbox-Personal" / "backups"
    dest.mkdir(parents=True)
    agents = tmp_path / "Library" / "LaunchAgents"
    agents.mkdir(parents=True)
    with (agents / "com.meetingpipe.backup.plist").open("wb") as f:
        plistlib.dump({"Label": "com.meetingpipe.backup",
                       "ProgramArguments": ["/x/mp", "backup", str(dest)]}, f)
    check_library_sync(_sec35_cfg(tmp_path), home=tmp_path, workflows_dir=tmp_path / "none")
    assert "[WARN] backups is synced to Dropbox" in capsys.readouterr().out


def test_no_backup_marker_and_no_agent_adds_nothing_and_a_relative_archive_is_skipped(capsys, tmp_path) -> None:
    cfg = _sec35_cfg(tmp_path)
    check_library_sync(cfg, home=tmp_path, workflows_dir=tmp_path / "none")
    assert "[ OK ] no meeting data is inside a cloud-sync folder" in capsys.readouterr().out
    _stamp_archive(tmp_path, "relative/x.tar.gz")   # a hand-typed CLI run: skipped, not guessed
    check_library_sync(cfg, home=tmp_path, workflows_dir=tmp_path / "none")
    assert "[ OK ] no meeting data is inside a cloud-sync folder" in capsys.readouterr().out


def test_a_synced_obsidian_vault_is_a_warn_with_obsidian_in_the_sinks(capsys, tmp_path) -> None:
    vault = tmp_path / "Library" / "CloudStorage" / "Dropbox-Personal" / "Vault"
    vault.mkdir(parents=True)
    cfg = _sec35_cfg(tmp_path, output={"sinks": ["obsidian"]}, obsidian={"vault_path": str(vault)})
    check_library_sync(cfg, home=tmp_path, workflows_dir=_nda_workflows(tmp_path))
    out = capsys.readouterr().out
    assert "[WARN] Obsidian vault is synced to Dropbox" in out   # an NDA workflow does not make it a FAIL
    assert "[FAIL] Obsidian vault" not in out
    # With no obsidian sink anywhere it is not a root at all.
    quiet = _sec35_cfg(tmp_path, obsidian={"vault_path": str(vault)})
    check_library_sync(quiet, home=tmp_path, workflows_dir=tmp_path / "none")
    assert "Obsidian vault" not in capsys.readouterr().out


def test_a_synced_obsidian_vault_is_a_fail_under_regulated_mode_until_sec18_item_1(capsys, tmp_path) -> None:
    # The sidecar-less path under global regulated_mode still reaches the vault, so while
    # SEC18 item 1 has not landed this pins FAIL; once it has, this becomes WARN-only.
    vault = tmp_path / "Library" / "CloudStorage" / "Dropbox-Personal" / "Vault"
    vault.mkdir(parents=True)
    cfg = _sec35_cfg(
        tmp_path, output={"sinks": ["obsidian"]}, obsidian={"vault_path": str(vault)},
        modes={"regulated_mode": True})
    check_library_sync(cfg, home=tmp_path, workflows_dir=tmp_path / "none")
    assert "[FAIL] Obsidian vault is synced to Dropbox" in capsys.readouterr().out


def test_a_synced_lan_mount_named_by_a_workflow_is_a_warn(capsys, tmp_path) -> None:
    mount = tmp_path / "Library" / "CloudStorage" / "Dropbox-Personal" / "share"
    mount.mkdir(parents=True)
    cfg = _sec35_cfg(tmp_path, lan={"mount_path": str(mount)})
    check_library_sync(cfg, home=tmp_path, workflows_dir=_sink_workflow(tmp_path, "lan"))
    assert "[WARN] LAN share is synced to Dropbox" in capsys.readouterr().out


# --- SEC21 item 7: a workflow file the daemon refuses ------------------------

def _broken_workflows(tmp_path: Path) -> Path:
    directory = tmp_path / "workflows"
    directory.mkdir(exist_ok=True)
    (directory / "stringly.toml").write_text(
        'id = "aaaaaaaa-0000-0000-0000-000000000009"\nname = "S"\n[flags]\nnda_mode = "true"\n',
        encoding="utf-8",
    )
    return directory


def test_check_workflow_files_fails_once_per_broken_file(capsys, tmp_path) -> None:
    check_workflow_files(_broken_workflows(tmp_path))
    out = capsys.readouterr().out
    assert "[FAIL] workflow file stringly.toml did not load" in out


def test_check_workflow_files_is_silent_with_none_broken(capsys, tmp_path) -> None:
    check_workflow_files(tmp_path / "none")
    assert capsys.readouterr().out == ""


def test_a_broken_workflow_file_makes_a_synced_library_a_fail(capsys, tmp_path) -> None:
    check_library_sync(
        _storage_cfg(_synced_library(tmp_path)), home=tmp_path, workflows_dir=_broken_workflows(tmp_path)
    )
    out = capsys.readouterr().out
    assert "[FAIL] library is synced to Dropbox" in out
    assert "may be an NDA workflow" in out


def test_mdfind_is_called_by_its_absolute_system_path(tmp_path, monkeypatch) -> None:
    # SEC17: a `mdfind` planted on a user-writable PATH must not be the one that answers.
    from mp.doctor import _mdfind_app_bundles

    seen: list[list[str]] = []

    def run(cmd, **kwargs):
        seen.append(cmd)
        return _Proc(stdout="")

    monkeypatch.setattr("mp.doctor.os.access", lambda path, mode: True)
    monkeypatch.setattr("mp.doctor.subprocess.run", run)
    assert _mdfind_app_bundles() == []
    assert seen[0][0] == "/usr/bin/mdfind"


# ---------- config validation (PIPE42) ---------------------------------------


def _doctor_config(monkeypatch, tmp_path: Path, text: str):
    from mp import config as config_mod
    from mp import doctor

    path = tmp_path / "config.toml"
    path.write_text(text, encoding="utf-8")
    monkeypatch.setattr(doctor, "CONFIG_PATH", path)
    monkeypatch.setattr(config_mod, "_WARNED_UNKNOWN", set())
    monkeypatch.setenv("MEETINGPIPE_LOGS_DIR", str(tmp_path / "logs"))
    return doctor.check_config()


def test_doctor_fails_a_misplaced_section(capsys, monkeypatch, tmp_path: Path) -> None:
    cfg = _doctor_config(monkeypatch, tmp_path, '[transcription]\nlanguage = "auto"\nmodes.regulated_mode = true\n')
    out = capsys.readouterr().out
    assert cfg is None
    assert "[FAIL]" in out and "transcription.modes" in out


def test_doctor_fails_a_misspelt_sink(capsys, monkeypatch, tmp_path: Path) -> None:
    cfg = _doctor_config(monkeypatch, tmp_path, '[output]\nsinks = ["obsidan"]\n')
    out = capsys.readouterr().out
    assert cfg is None
    # UX94: the load names the dotted key, never the value (a value can be a path or an id).
    assert "[FAIL]" in out and "output.sinks" in out


def test_doctor_warns_on_each_unknown_key(capsys, monkeypatch, tmp_path: Path) -> None:
    cfg = _doctor_config(
        monkeypatch, tmp_path, 'sinks = ["obsidian"]\n\n[summarization]\nbackedn = "local"\n'
    )
    out = capsys.readouterr().out
    assert cfg is not None
    assert "[WARN] unknown config key summarization.backedn" in out
    assert "[WARN] unknown config key sinks" in out


# ---------- the last backup's destination (STOR8) ----------------------------


def test_doctor_warns_when_the_last_backup_went_to_an_unencrypted_volume(capsys, tmp_path: Path) -> None:
    from mp.doctor import check_last_backup

    marker = storage.backup_marker(tmp_path)
    marker.parent.mkdir(parents=True, exist_ok=True)
    now = datetime(2026, 11, 17, tzinfo=UTC)
    cases = (({"destination_encrypted": False}, "is not encrypted"),
             ({"destination_encrypted": True}, None),
             ({"destination_encrypted": None}, "could not tell"),
             ({}, None))   # a marker from before STOR8 says nothing
    for extra, warning in cases:
        marker.write_text(json.dumps({"at": now.isoformat(), "archive": "/Volumes/USB/b.tar.gz", **extra}))
        check_last_backup(home=tmp_path, now=now)
        out = capsys.readouterr().out
        assert ("[WARN]" in out) is (warning is not None), (extra, out)
        if warning:
            assert warning in out


# ---------- STOR10: a scheduled backup that failed or fell behind ------------------


def _install_backup_agent(home: Path, *, weekly: bool = False) -> None:
    import plistlib

    plist = home / "Library" / "LaunchAgents" / "com.meetingpipe.backup.plist"
    plist.parent.mkdir(parents=True, exist_ok=True)
    interval = {"Hour": 2, "Minute": 0, **({"Weekday": 1} if weekly else {})}
    plist.write_bytes(plistlib.dumps({"Label": "com.meetingpipe.backup", "StartCalendarInterval": interval}))


def _stamp_attempt(home: Path, at: datetime, outcome: str, reason: str | None = None) -> None:
    from mp import run_attempt

    run_attempt.record(run_attempt.BACKUP, outcome=outcome, reason=reason, run_trigger="scheduled", home=home, now=at)


def test_check_last_backup_warns_when_the_newest_scheduled_attempt_failed(capsys, tmp_path) -> None:
    now = datetime(2026, 7, 10, 12, tzinfo=UTC)
    _install_backup_agent(tmp_path)
    _stamp_backup(tmp_path, now - timedelta(days=1))
    _stamp_attempt(tmp_path, now - timedelta(hours=3), "failed", "/Volumes/Drive is not mounted")
    check_last_backup(home=tmp_path, now=now)
    out = capsys.readouterr().out
    assert "WARN" in out
    assert "last automatic backup failed today: /Volumes/Drive is not mounted" in out


def test_check_last_backup_warns_when_the_schedule_is_overdue(capsys, tmp_path) -> None:
    now = datetime(2026, 7, 10, tzinfo=UTC)
    _install_backup_agent(tmp_path, weekly=True)
    _stamp_backup(tmp_path, now - timedelta(days=15))
    check_last_backup(home=tmp_path, now=now)
    assert "has not succeeded in 15 days (it runs weekly)" in capsys.readouterr().out


def test_check_last_backup_stays_informational_without_a_schedule(capsys, tmp_path) -> None:
    now = datetime(2026, 7, 10, tzinfo=UTC)
    _stamp_backup(tmp_path, now - timedelta(days=40))
    _stamp_attempt(tmp_path, now - timedelta(days=1), "failed", "boom")
    check_last_backup(home=tmp_path, now=now)
    out = capsys.readouterr().out
    assert "WARN" not in out
    assert "last backup 40 days ago" in out
