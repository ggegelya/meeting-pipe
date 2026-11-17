"""`mp backup` / `mp restore` round-trip over a fake `$HOME` (STOR2).

The acceptance criterion is the round-trip: a backup restored into a scratch home
yields a working library, workflows, roster, and corrections state, and the
manifest names every Keychain item without exporting one.
"""
from __future__ import annotations

import errno
import io
import json
import os
import stat
import tarfile
from collections import namedtuple
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from mp import storage
from mp import backup as backup_mod
from mp.backup import MANIFEST_NAME, BackupError, check_destination, create_backup
from mp.config import KEYCHAIN_SERVICE, MANAGED_SECRET_KEYS, Config
from mp.restore import (
    PLAN_SAMPLE_LIMIT,
    RestoreError,
    plan_restore,
    read_manifest,
    restore_archive,
)


def _make_home(tmp_path: Path, name: str = "home") -> Path:
    home = tmp_path / name
    home.mkdir()
    return home


def _cfg(home: Path) -> Config:
    return Config.model_validate({"recording": {"output_dir": str(home / "Meetings" / "raw")}})


def _populate(home: Path) -> None:
    """Everything a real install accumulates, including things that must NOT be archived."""
    library = home / "Meetings" / "raw"
    library.mkdir(parents=True)
    (library / "20260101-120000.wav").write_bytes(b"RIFF" + b"\0" * 500)
    (library / "20260101-120000.summary.json").write_text('{"title": "Weekly sync"}')
    (library / "20260101-120000.md").write_text("# transcript")

    digests = home / "Meetings" / "digests"
    digests.mkdir()
    (digests / "digest-20260105.summary.md").write_text("# week")

    config = storage.config_dir(home)
    (config / "workflows").mkdir(parents=True)
    (config / "config.toml").write_text('[recording]\noutput_dir = "~/Meetings/raw"\n')
    (config / "workflows" / "abc.toml").write_text('name = "Client X"\n')
    (config / "roster.json").write_text('{"people": []}')
    (config / "voiceprint.json").write_text('{"meetings": 3}')
    (config / "glossary.toml").write_text('[terms]\n')
    # Must never be archived:
    (config / "secrets.env").write_text("ANTHROPIC_API_KEY=sk-live-do-not-export")

    corrections = storage.corrections_dir(home)
    corrections.mkdir(parents=True)
    (corrections / "20260101-120000.json").write_text('{"verdict": "edited"}')

    # ADR 0016: sensitive, backup-excluded.
    originals = storage.originals_dir(home)
    originals.mkdir(parents=True)
    (originals / "20260101-120000.wav").write_bytes(b"unredacted")

    # Rebuildable, and not worth a gigabyte in the tarball.
    published = home / "Meetings" / "published"
    published.mkdir()
    (published / "summary.md").write_text("# published")
    waveforms = storage.waveform_cache_dir(home)
    waveforms.mkdir(parents=True)
    (waveforms / "20260101-120000.peaks").write_bytes(b"MPW1")


_Usage = namedtuple("_Usage", "total used free")


# The real STOR8 probe, kept for its own tests; conftest's `_known_encryption`
# stubs it for the rest of the suite.
_REAL_ENCRYPTION_PROBE = backup_mod.destination_encrypted


@pytest.fixture(autouse=True)
def _plenty_of_room(monkeypatch: pytest.MonkeyPatch) -> None:
    """Every destination here shares the library's volume, so the STOR12 check
    would hold each one to the 4.6 GB recording reserve against the real disk.
    The free-space tests below override this with the number they mean."""
    monkeypatch.setattr(backup_mod.shutil, "disk_usage", lambda _p: _Usage(10**15, 0, 10**15))


def _members(archive: Path) -> set[str]:
    with tarfile.open(archive, "r:gz") as tar:
        return {member.name for member in tar.getmembers() if member.isfile()}


# ---------- what goes in, and what stays out ---------------------------------


def test_backup_archives_the_four_non_rebuildable_roots(tmp_path: Path) -> None:
    home = _make_home(tmp_path)
    _populate(home)
    archive = create_backup(_cfg(home), tmp_path / "out", home=home)

    members = _members(archive)
    assert "library/20260101-120000.wav" in members
    assert "library/20260101-120000.summary.json" in members
    assert "digests/digest-20260105.summary.md" in members
    assert "config/config.toml" in members
    assert "config/workflows/abc.toml" in members
    assert "config/roster.json" in members
    assert "config/voiceprint.json" in members
    assert "corrections/20260101-120000.json" in members


def test_backup_never_archives_the_kept_originals(tmp_path: Path) -> None:
    # ADR 0016 makes these 0600 and Time-Machine-excluded because they are the
    # most sensitive thing on disk. A tarball the owner copies to a NAS would
    # defeat exactly that.
    home = _make_home(tmp_path)
    _populate(home)
    archive = create_backup(_cfg(home), tmp_path / "out", home=home)
    assert not any("originals" in name for name in _members(archive))
    with tarfile.open(archive, "r:gz") as tar:
        assert b"unredacted" not in b"".join(
            tar.extractfile(m).read() for m in tar.getmembers() if m.isfile()
        )


def test_backup_never_archives_legacy_plaintext_secrets(tmp_path: Path) -> None:
    home = _make_home(tmp_path)
    _populate(home)
    archive = create_backup(_cfg(home), tmp_path / "out", home=home)
    assert "config/secrets.env" not in _members(archive)
    with tarfile.open(archive, "r:gz") as tar:
        blob = b"".join(tar.extractfile(m).read() for m in tar.getmembers() if m.isfile())
    assert b"sk-live-do-not-export" not in blob


def test_backup_skips_rebuildable_roots(tmp_path: Path) -> None:
    home = _make_home(tmp_path)
    _populate(home)
    members = _members(create_backup(_cfg(home), tmp_path / "out", home=home))
    assert not any("published" in name for name in members)
    assert not any("peaks" in name for name in members)


def test_no_audio_skips_recordings_but_keeps_sidecars(tmp_path: Path) -> None:
    home = _make_home(tmp_path)
    _populate(home)
    (home / "Meetings" / "raw" / "20260102-120000.flac").write_bytes(b"fLaC")
    archive = create_backup(_cfg(home), tmp_path / "out", home=home, include_audio=False)

    members = _members(archive)
    assert "library/20260101-120000.wav" not in members
    assert "library/20260102-120000.flac" not in members
    assert "library/20260101-120000.summary.json" in members
    assert read_manifest(archive)["audio_included"] is False


# ---------- the manifest -----------------------------------------------------


def test_manifest_names_every_keychain_item_and_exports_no_value(tmp_path: Path) -> None:
    home = _make_home(tmp_path)
    _populate(home)
    manifest = read_manifest(create_backup(_cfg(home), tmp_path / "out", home=home))

    keychain = manifest["keychain"]
    assert keychain["service"] == KEYCHAIN_SERVICE
    assert keychain["accounts"] == list(MANAGED_SECRET_KEYS)
    assert "security add-generic-password" in keychain["note"]
    # Names only. There is deliberately nowhere in this shape for a secret to sit:
    # `accounts` is a flat list of item names, not a mapping to values.
    assert set(keychain) == {"service", "accounts", "note"}
    assert all(isinstance(account, str) for account in keychain["accounts"])


def test_manifest_records_counts_and_the_exclusions(tmp_path: Path) -> None:
    home = _make_home(tmp_path)
    _populate(home)
    manifest = read_manifest(create_backup(_cfg(home), tmp_path / "out", home=home))

    roots = {root["name"]: root for root in manifest["roots"]}
    assert roots["library"]["files"] == 3
    assert roots["corrections"]["files"] == 1
    assert roots["library"]["bytes"] > 0
    assert any("originals" in item["path"] for item in manifest["excluded"])


def test_a_missing_root_is_recorded_as_zero_files_not_dropped(tmp_path: Path) -> None:
    # "you had no digests" has to be distinguishable from "the backup forgot digests".
    home = _make_home(tmp_path)
    (home / "Meetings" / "raw").mkdir(parents=True)
    manifest = read_manifest(create_backup(_cfg(home), tmp_path / "out", home=home))
    roots = {root["name"]: root for root in manifest["roots"]}
    assert roots["digests"]["files"] == 0


def test_backup_stamps_the_marker_doctor_reads(tmp_path: Path) -> None:
    home = _make_home(tmp_path)
    _populate(home)
    archive = create_backup(_cfg(home), tmp_path / "out", home=home)

    marker = json.loads(storage.backup_marker(home).read_text())
    assert marker["archive"] == str(archive)
    assert marker["audio_included"] is True
    datetime.fromisoformat(marker["at"])


# ---------- the unmounted-drive guard (STOR4) --------------------------------


def test_an_unmounted_volume_destination_is_refused(tmp_path: Path) -> None:
    """A scheduled backup to an unplugged drive must fail, not silently fill the
    boot disk under the empty mount point."""
    volumes = tmp_path / "Volumes"
    volumes.mkdir()
    destination = volumes / "BackupDrive" / "meeting-pipe"

    with pytest.raises(BackupError, match="not mounted"):
        check_destination(destination, volumes_root=volumes)
    assert not destination.exists()


def test_a_mounted_volume_destination_is_allowed(tmp_path: Path) -> None:
    volumes = tmp_path / "Volumes"
    (volumes / "BackupDrive").mkdir(parents=True)

    # The subfolder does not exist yet; the mount point does, so mkdir is safe.
    check_destination(volumes / "BackupDrive" / "meeting-pipe", volumes_root=volumes)


def test_a_destination_outside_volumes_is_never_refused(tmp_path: Path) -> None:
    check_destination(tmp_path / "nowhere" / "deep", volumes_root=tmp_path / "Volumes")


def test_a_refused_destination_leaves_no_marker(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The failure mode this guards is a *fresh-looking* marker for a backup that
    landed on the wrong disk, so the refusal has to happen before the stamp."""
    home = _make_home(tmp_path)
    _populate(home)
    volumes = tmp_path / "Volumes"
    volumes.mkdir()
    monkeypatch.setattr(backup_mod, "VOLUMES_ROOT", volumes)

    with pytest.raises(BackupError):
        create_backup(_cfg(home), volumes / "Gone" / "out", home=home)
    assert not storage.backup_marker(home).exists()


# ---------- the round trip, which is the acceptance criterion ----------------


def test_restore_into_a_scratch_home_yields_a_working_install(tmp_path: Path) -> None:
    source = _make_home(tmp_path, "old-mac")
    _populate(source)
    archive = create_backup(_cfg(source), tmp_path / "out", home=source)

    # A brand-new Mac, with the library at a *different* path: destinations come
    # from this machine's config, not from wherever the backup was taken.
    fresh = _make_home(tmp_path, "new-mac")
    fresh_cfg = Config.model_validate({"recording": {"output_dir": str(fresh / "Recordings")}})
    written = restore_archive(archive, fresh_cfg, home=fresh)

    assert written == {"library": 3, "digests": 1, "config": 5, "corrections": 1}
    # No config.toml existed here, so the backup's copy landed.
    assert (storage.config_dir(fresh) / "config.toml").exists()
    assert (fresh / "Recordings" / "20260101-120000.wav").read_bytes().startswith(b"RIFF")
    assert (fresh / "Recordings" / "20260101-120000.summary.json").exists()
    assert (fresh / "digests" / "digest-20260105.summary.md").exists()
    assert (storage.config_dir(fresh) / "workflows" / "abc.toml").read_text() == 'name = "Client X"\n'
    assert (storage.config_dir(fresh) / "roster.json").exists()
    assert (storage.corrections_dir(fresh) / "20260101-120000.json").exists()
    # Secrets and originals were never in the archive, so they are not here either.
    assert not (storage.config_dir(fresh) / "secrets.env").exists()
    assert not storage.originals_dir(fresh).exists()


def test_restore_onto_a_new_mac_keeps_its_own_config_toml(tmp_path: Path) -> None:
    # The catch-22 the runbook walk found: a new Mac must write config.toml first
    # (it names the destinations), so the config root is never empty, and the
    # backup's config.toml would repoint output_dir at the old Mac's library.
    source = _make_home(tmp_path, "old-mac")
    _populate(source)
    archive = create_backup(_cfg(source), tmp_path / "out", home=source)

    fresh = _make_home(tmp_path, "new-mac")
    fresh_config = storage.config_dir(fresh)
    fresh_config.mkdir(parents=True)
    (fresh_config / "config.toml").write_text('[recording]\noutput_dir = "~/Recordings"\n')
    fresh_cfg = Config.model_validate({"recording": {"output_dir": str(fresh / "Recordings")}})

    # Neither a refusal nor a clobber.
    restore_archive(archive, fresh_cfg, home=fresh)
    assert (fresh_config / "config.toml").read_text() == '[recording]\noutput_dir = "~/Recordings"\n'
    assert (fresh_config / "workflows" / "abc.toml").exists()
    assert (fresh_config / "roster.json").exists()
    assert (fresh / "Recordings" / "20260101-120000.wav").exists()


def test_backup_never_archives_this_macs_backup_marker(tmp_path: Path) -> None:
    # It is a fact about this Mac; restoring a stale one would make doctor report
    # a backup that never happened here.
    home = _make_home(tmp_path)
    _populate(home)
    create_backup(_cfg(home), tmp_path / "out", home=home)          # stamps the marker
    second = create_backup(_cfg(home), tmp_path / "out2", home=home)
    assert "config/.last-backup.json" not in _members(second)


def test_restore_still_refuses_a_config_root_with_real_content(tmp_path: Path) -> None:
    source = _make_home(tmp_path, "old-mac")
    _populate(source)
    archive = create_backup(_cfg(source), tmp_path / "out", home=source)

    occupied = _make_home(tmp_path, "in-use")
    config = storage.config_dir(occupied)
    (config / "workflows").mkdir(parents=True)
    (config / "config.toml").write_text("")
    (config / "roster.json").write_text('{"people": [{"name": "Mine"}]}')
    with pytest.raises(RestoreError, match="already has files"):
        restore_archive(archive, _cfg(occupied), home=occupied)


def test_restore_refuses_a_non_empty_destination(tmp_path: Path) -> None:
    source = _make_home(tmp_path, "old-mac")
    _populate(source)
    archive = create_backup(_cfg(source), tmp_path / "out", home=source)

    occupied = _make_home(tmp_path, "occupied")
    _populate(occupied)
    with pytest.raises(RestoreError, match="already has files"):
        restore_archive(archive, _cfg(occupied), home=occupied)


def test_restore_force_writes_into_a_non_empty_destination(tmp_path: Path) -> None:
    source = _make_home(tmp_path, "old-mac")
    _populate(source)
    archive = create_backup(_cfg(source), tmp_path / "out", home=source)

    occupied = _make_home(tmp_path, "occupied")
    _populate(occupied)
    written = restore_archive(archive, _cfg(occupied), home=occupied, force=True)
    assert written["library"] == 3


def test_restore_dry_run_writes_nothing(tmp_path: Path) -> None:
    source = _make_home(tmp_path, "old-mac")
    _populate(source)
    archive = create_backup(_cfg(source), tmp_path / "out", home=source)

    fresh = _make_home(tmp_path, "new-mac")
    written = restore_archive(archive, _cfg(fresh), home=fresh, dry_run=True)
    assert written["library"] == 3
    assert not (fresh / "Meetings" / "raw").exists()


def test_restore_rejects_a_missing_archive(tmp_path: Path) -> None:
    with pytest.raises(RestoreError, match="no archive at"):
        restore_archive(tmp_path / "nope.tar.gz", _cfg(_make_home(tmp_path)))


def test_restore_rejects_an_archive_with_no_manifest(tmp_path: Path) -> None:
    bogus = tmp_path / "bogus.tar.gz"
    with tarfile.open(bogus, "w:gz") as tar:
        payload = tmp_path / "x.txt"
        payload.write_text("hi")
        tar.add(payload, arcname="library/x.txt")
    with pytest.raises(RestoreError):
        restore_archive(bogus, _cfg(_make_home(tmp_path)))


def _hostile_archive(tmp_path: Path, home: Path, arcname: str) -> Path:
    """A real backup, plus one member whose name tries to escape."""
    archive = create_backup(_cfg(home), tmp_path / "out", home=home)
    hostile = tmp_path / f"hostile-{abs(hash(arcname))}.tar.gz"
    with tarfile.open(archive, "r:gz") as src, tarfile.open(hostile, "w:gz") as dst:
        for member in src.getmembers():
            if member.isfile():
                dst.addfile(member, src.extractfile(member))
        evil = tmp_path / "evil.txt"
        evil.write_text("pwned")
        dst.add(evil, arcname=arcname)
    return hostile


def test_restore_ignores_a_member_under_an_unknown_prefix(tmp_path: Path) -> None:
    home = _make_home(tmp_path, "old-mac")
    _populate(home)
    hostile = _hostile_archive(tmp_path, home, "../../escaped.txt")

    fresh = _make_home(tmp_path, "new-mac")
    restore_archive(hostile, _cfg(fresh), home=fresh)
    assert not (tmp_path / "escaped.txt").exists()
    assert not (tmp_path.parent / "escaped.txt").exists()


def test_restore_refuses_a_member_escaping_from_inside_a_valid_prefix(tmp_path: Path) -> None:
    # The real attack: a plausible prefix with a traversing tail. The prefix
    # dispatch happily accepts `library/`, so tarfile's `data` filter is what has
    # to stop it, and the refusal must surface as a RestoreError, not a traceback.
    home = _make_home(tmp_path, "old-mac")
    _populate(home)
    hostile = _hostile_archive(tmp_path, home, "library/../../../escaped.txt")

    fresh = _make_home(tmp_path, "new-mac")
    with pytest.raises(RestoreError, match="would write outside"):
        restore_archive(hostile, _cfg(fresh), home=fresh)
    assert not (tmp_path / "escaped.txt").exists()
    assert not (tmp_path.parent / "escaped.txt").exists()


# ---------- the dry-run plan the app previews (STOR5) ------------------------


def _plan_fixture(tmp_path: Path, destination_name: str = "this-mac") -> tuple[Path, Path]:
    """A real archive, plus a scratch home to plan a restore into."""
    source = _make_home(tmp_path, "old-mac")
    _populate(source)
    archive = create_backup(_cfg(source), tmp_path / "out", home=source)
    return archive, _make_home(tmp_path, destination_name)


def test_plan_counts_every_root_and_names_what_lands(tmp_path: Path) -> None:
    archive, fresh = _plan_fixture(tmp_path)

    plan = plan_restore(archive, _cfg(fresh), home=fresh)

    assert plan["total_files"] == 10
    assert plan["added"] == 10
    assert plan["replaced"] == 0
    roots = {root["name"]: root for root in plan["roots"]}
    assert roots["library"]["files"] == 3
    assert roots["library"]["destination"] == str(fresh / "Meetings" / "raw")
    assert roots["library"]["occupied"] is False
    assert roots["digests"]["files"] == 1
    assert roots["corrections"]["files"] == 1
    # The sample is what lets a preview say *which* meeting comes back.
    assert "library/20260101-120000.wav" in plan["added_sample"]
    assert plan["replaced_sample"] == []
    assert plan["created_at"] == read_manifest(archive)["created_at"]
    assert plan["audio_included"] is True


def test_plan_splits_the_files_that_come_back_from_the_ones_it_overwrites(
    tmp_path: Path,
) -> None:
    """The recovery case STOR5 exists for: one meeting's files were lost from a
    live library, and the preview has to name exactly that one as coming back
    while being honest that everything else is overwritten in place."""
    archive, live = _plan_fixture(tmp_path, "live")
    _populate(live)
    (live / "Meetings" / "raw" / "20260101-120000.wav").unlink()

    plan = plan_restore(archive, _cfg(live), home=live)

    assert plan["added"] == 1
    assert plan["added_sample"] == ["library/20260101-120000.wav"]
    assert plan["replaced"] == plan["total_files"] - 1
    assert "library/20260101-120000.md" in plan["replaced_sample"]
    library = next(root for root in plan["roots"] if root["name"] == "library")
    assert (library["files"], library["added"], library["replaced"]) == (3, 1, 2)


def test_plan_marks_an_occupied_destination_with_nothing_to_replace(tmp_path: Path) -> None:
    # Occupancy is not the same question as overwriting: a library holding only
    # *other* meetings is what a plain restore refuses over, and replaces nothing.
    archive, live = _plan_fixture(tmp_path, "live")
    library = live / "Meetings" / "raw"
    library.mkdir(parents=True)
    (library / "20260707-090000.wav").write_bytes(b"RIFF")

    plan = plan_restore(archive, _cfg(live), home=live)

    root = next(r for r in plan["roots"] if r["name"] == "library")
    assert root["occupied"] is True
    assert root["replaced"] == 0
    assert root["added"] == 3


def test_plan_never_refuses_an_occupied_destination_and_writes_nothing(
    tmp_path: Path,
) -> None:
    # A preview whose whole job is to describe a conflict cannot be the thing
    # that refuses one, and it must leave the disk exactly as it found it.
    archive, live = _plan_fixture(tmp_path, "live")
    _populate(live)
    before = sorted(p.name for p in (live / "Meetings" / "raw").iterdir())

    plan = plan_restore(archive, _cfg(live), home=live)

    assert plan["replaced"] > 0
    assert sorted(p.name for p in (live / "Meetings" / "raw").iterdir()) == before
    assert (live / "Meetings" / "raw" / "20260101-120000.md").read_text() == "# transcript"


def test_plan_reports_that_this_macs_config_toml_is_kept(tmp_path: Path) -> None:
    archive, fresh = _plan_fixture(tmp_path)
    assert plan_restore(archive, _cfg(fresh), home=fresh)["keeps_config_toml"] is False

    config = storage.config_dir(fresh)
    config.mkdir(parents=True, exist_ok=True)
    (config / "config.toml").write_text('[recording]\noutput_dir = "~/Recordings"\n')

    plan = plan_restore(archive, _cfg(fresh), home=fresh)
    assert plan["keeps_config_toml"] is True
    # ... and the backup's copy is then not among the files that would land.
    assert "config/config.toml" not in plan["added_sample"] + plan["replaced_sample"]


def test_plan_samples_are_capped_but_the_counts_stay_exact(tmp_path: Path) -> None:
    source = _make_home(tmp_path, "old-mac")
    _populate(source)
    for i in range(PLAN_SAMPLE_LIMIT + 5):
        (source / "Meetings" / "raw" / f"2026020{i % 10}-1200{i:02d}.md").write_text("x")
    archive = create_backup(_cfg(source), tmp_path / "out", home=source)
    fresh = _make_home(tmp_path, "new-mac")

    plan = plan_restore(archive, _cfg(fresh), home=fresh)

    assert len(plan["added_sample"]) == PLAN_SAMPLE_LIMIT
    assert plan["added"] > PLAN_SAMPLE_LIMIT


def test_plan_carries_the_no_audio_flag(tmp_path: Path) -> None:
    # A sidecar-only backup restores meetings with no recording, which the
    # confirm has to say before the owner presses it.
    source = _make_home(tmp_path, "old-mac")
    _populate(source)
    archive = create_backup(_cfg(source), tmp_path / "out", home=source, include_audio=False)
    fresh = _make_home(tmp_path, "new-mac")

    assert plan_restore(archive, _cfg(fresh), home=fresh)["audio_included"] is False


def test_plan_rejects_a_missing_archive(tmp_path: Path) -> None:
    with pytest.raises(RestoreError, match="no archive at"):
        plan_restore(tmp_path / "nope.tar.gz", _cfg(_make_home(tmp_path)))


def test_plan_matches_what_the_real_run_then_writes(tmp_path: Path) -> None:
    """The two are one walk, seen twice. If they can disagree, the confirm the
    owner pressed described a different restore than the one that ran."""
    archive, live = _plan_fixture(tmp_path, "live")
    _populate(live)
    (live / "Meetings" / "raw" / "20260101-120000.wav").unlink()

    plan = plan_restore(archive, _cfg(live), home=live)
    written = restore_archive(archive, _cfg(live), home=live, force=True)

    assert {root["prefix"]: root["files"] for root in plan["roots"]} == written


# ---------- the CLI surface the daemon spawns (STOR5) ------------------------


def _restore_main(
    argv: list[str], home: Path, monkeypatch: pytest.MonkeyPatch
) -> int:
    """Run `mp restore` the way the daemon spawns it, against a scratch `$HOME`.

    `main` resolves the config and corrections roots from the *real* home (it
    passes no `home=` override), so without the `$HOME` swap a CLI test reads the
    developer's own `~/.config/meeting-pipe` and its counts move machine to
    machine."""
    from mp import restore as restore_mod

    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setattr("mp.entry.prepare", lambda *a, **k: _cfg(home))
    return restore_mod.main(argv)


def test_cli_json_without_dry_run_is_a_usage_error(tmp_path: Path) -> None:
    from mp import restore as restore_mod

    with pytest.raises(SystemExit) as exc:
        restore_mod.main([str(tmp_path / "a.tar.gz"), "--json"])
    assert exc.value.code == 2


def test_cli_out_without_json_is_a_usage_error(tmp_path: Path) -> None:
    from mp import restore as restore_mod

    with pytest.raises(SystemExit) as exc:
        restore_mod.main([str(tmp_path / "a.tar.gz"), "--dry-run", "--out", str(tmp_path / "p")])
    assert exc.value.code == 2


def test_cli_writes_the_plan_the_daemon_reads_and_restores_nothing(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    archive, fresh = _plan_fixture(tmp_path)
    out = tmp_path / "plan" / "restore-plan.json"

    rc = _restore_main([str(archive), "--dry-run", "--json", "--out", str(out)], fresh, monkeypatch)

    assert rc == 0
    plan = json.loads(out.read_text())
    assert plan["total_files"] == 10
    assert [root["name"] for root in plan["roots"]] == [
        "library", "digests", "config", "corrections"
    ]
    assert not (fresh / "Meetings" / "raw").exists()


def test_cli_json_to_stdout_is_the_whole_of_stdout(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    archive, fresh = _plan_fixture(tmp_path)

    rc = _restore_main([str(archive), "--dry-run", "--json"], fresh, monkeypatch)

    assert rc == 0
    assert json.loads(capsys.readouterr().out)["archive"] == str(archive)


def test_cli_reports_a_bad_archive_without_a_traceback(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    rc = _restore_main(
        [str(tmp_path / "nope.tar.gz"), "--dry-run", "--json"], _make_home(tmp_path), monkeypatch
    )
    assert rc == 1
    # STOR14: the daemon reads only stderr, so the reason has to be there.
    captured = capsys.readouterr()
    assert "[FAIL]" in captured.err
    assert captured.out == ""


def test_read_manifest_round_trips_the_creation_time(tmp_path: Path) -> None:
    home = _make_home(tmp_path)
    _populate(home)
    when = datetime.now(timezone.utc) - timedelta(days=3)
    archive = create_backup(_cfg(home), tmp_path / "out", home=home, now=when)
    assert archive.name == f"meeting-pipe-backup-{when.strftime('%Y%m%d-%H%M%S')}.tar.gz"
    assert read_manifest(archive)["created_at"] == when.isoformat()
    assert MANIFEST_NAME in _members(archive)


# ---------- how many times each run reads the archive (STOR12) ---------------


class _CountingFile(io.FileIO):
    """A read-only file that tallies every byte it hands out into a shared dict."""

    def __init__(self, path: str | Path, tally: dict[str, int]) -> None:
        super().__init__(path, "r")
        self._tally = tally

    def _count(self, n: int | None) -> None:
        self._tally["bytes"] = self._tally.get("bytes", 0) + (n or 0)

    def read(self, size: int = -1) -> bytes:  # type: ignore[override]
        data = super().read(size) or b""
        self._count(len(data))
        return data

    def readall(self) -> bytes:
        data = super().readall()
        self._count(len(data))
        return data

    def readinto(self, buffer) -> int:  # type: ignore[override]
        n = super().readinto(buffer) or 0
        self._count(n)
        return n


@pytest.fixture
def archive_reads(monkeypatch: pytest.MonkeyPatch):
    """Every `tarfile.open(path, "r...")` in the test reads through a counting
    file, so a test can say how many archives' worth of bytes a run pulled off
    disk. Reaching the last member of a gzip stream reads the whole file and a
    rewind restarts from byte 0, so the tally is the pass count times the size."""
    tally: dict[str, int] = {}
    opened: list[_CountingFile] = []
    real_open = tarfile.open

    def counting_open(name=None, mode="r", fileobj=None, **kwargs):
        if fileobj is None and name is not None and str(mode).startswith("r"):
            raw = _CountingFile(name, tally)
            opened.append(raw)
            return real_open(name=name, mode=mode, fileobj=raw, **kwargs)
        return real_open(name=name, mode=mode, fileobj=fileobj, **kwargs)

    monkeypatch.setattr(tarfile, "open", counting_open)
    yield tally
    for raw in opened:
        raw.close()


def _sizeable_home(tmp_path: Path, name: str = "old-mac") -> Path:
    """A fixture whose archive is well past every read buffer, so one pass shows
    up as megabytes rather than as a single buffered read either way."""
    home = _make_home(tmp_path, name)
    _populate(home)
    (home / "Meetings" / "raw" / "20260102-120000.wav").write_bytes(os.urandom(3_000_000))
    return home


def _backup_main(argv: list[str], home: Path, monkeypatch: pytest.MonkeyPatch) -> int:
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setattr("mp.entry.prepare", lambda *a, **k: _cfg(home))
    return backup_mod.main(argv)


def test_mp_backup_reads_nothing_of_the_archive_it_just_wrote(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    archive_reads: dict[str, int],
    capsys: pytest.CaptureFixture[str],
) -> None:
    home = _sizeable_home(tmp_path)

    assert _backup_main([str(tmp_path / "out")], home, monkeypatch) == 0

    assert archive_reads.get("bytes", 0) == 0
    assert "library" in capsys.readouterr().out


def test_plan_restore_walks_the_archive_once(
    tmp_path: Path, archive_reads: dict[str, int]
) -> None:
    home = _sizeable_home(tmp_path)
    archive = create_backup(_cfg(home), tmp_path / "out", home=home)
    fresh = _make_home(tmp_path, "new-mac")
    archive_reads.clear()

    plan_restore(archive, _cfg(fresh), home=fresh)

    assert 0 < archive_reads["bytes"] <= archive.stat().st_size


def test_a_real_restore_walks_the_archive_twice(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, archive_reads: dict[str, int]
) -> None:
    """Once to validate the manifest before touching anything, once to extract."""
    home = _sizeable_home(tmp_path)
    archive = create_backup(_cfg(home), tmp_path / "out", home=home)
    fresh = _make_home(tmp_path, "new-mac")
    archive_reads.clear()

    assert _restore_main([str(archive)], fresh, monkeypatch) == 0

    assert (fresh / "Meetings" / "raw" / "20260102-120000.wav").exists()
    assert archive_reads["bytes"] <= 2 * archive.stat().st_size


# ---------- retention on the destination (STOR12) ----------------------------

#: A Thursday, ISO week 46 of 2026. Injected, so the weeks cannot drift with the
#: real calendar.
_NOW = datetime(2026, 11, 12, 3, 0, 0, tzinfo=timezone.utc)


def _stamp(when: datetime) -> str:
    return when.strftime("%Y%m%d-%H%M%S")


def _archive_name(when: datetime) -> str:
    return f"meeting-pipe-backup-{_stamp(when)}.tar.gz"


def _days(*dates: str) -> set[datetime]:
    return {datetime.fromisoformat(f"{d}T03:00:00") for d in dates}


def test_retention_keeps_the_owners_policy_and_touches_nothing_else(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The owner's choice on 2026-11-12: the newest 7, plus the newest archive in
    each of the 4 ISO weeks before the oldest of those 7."""
    home = _make_home(tmp_path)
    _populate(home)
    out = tmp_path / "out"
    out.mkdir()
    for days in range(1, 16):  # 2026-10-28 .. 2026-11-11, one a night
        (out / _archive_name(_NOW - timedelta(days=days))).write_bytes(b"x" * 100)
    (out / "notes.txt").write_text("mine")
    (out / "meeting-pipe-backup-old.tar.gz").write_bytes(b"renamed to keep")
    (out / "meeting-pipe-backup-20261399-000000.tar.gz").write_bytes(b"not a date")
    fresh_partial = out / (_archive_name(_NOW - timedelta(hours=1)) + ".partial")
    stale_partial = out / (_archive_name(_NOW - timedelta(days=2)) + ".partial")
    fresh_partial.write_bytes(b"still being written")
    stale_partial.write_bytes(b"SIGKILLed")
    emitted: list[tuple[str, str, dict]] = []
    monkeypatch.setattr(
        backup_mod.events, "emit", lambda c, a, **kw: emitted.append((c, a, kw))
    )

    result = backup_mod.run_backup(_cfg(home), out, home=home, now=_NOW)

    kept_archives = {
        "meeting-pipe-backup-20261112-030000.tar.gz",  # the one just written
        "meeting-pipe-backup-20261111-030000.tar.gz",
        "meeting-pipe-backup-20261110-030000.tar.gz",
        "meeting-pipe-backup-20261109-030000.tar.gz",
        "meeting-pipe-backup-20261108-030000.tar.gz",
        "meeting-pipe-backup-20261107-030000.tar.gz",
        "meeting-pipe-backup-20261106-030000.tar.gz",  # oldest of the 7, ISO week 45
        # Week 45's older nights (11-02..11-05) are not "before" the 7, so they
        # go; week 44 is, and keeps its newest, Sunday 11-01. Weeks 43..41 hold
        # no archive here, so they keep nothing.
        "meeting-pipe-backup-20261101-030000.tar.gz",
    }
    assert {p.name for p in out.iterdir()} == kept_archives | {
        "notes.txt",
        "meeting-pipe-backup-old.tar.gz",
        "meeting-pipe-backup-20261399-000000.tar.gz",
        fresh_partial.name,
    }
    assert result.pruned == 8
    assert result.pruned_bytes == 800
    assert emitted == [("pipeline", "backup_pruned", {"count": 8, "bytes": 800})]


def test_a_daily_schedule_settles_at_eleven_archives() -> None:
    nights = {_NOW.replace(tzinfo=None) - timedelta(days=d) for d in range(60)}
    assert backup_mod.retained(list(nights)) == _days(
        "2026-11-12", "2026-11-11", "2026-11-10", "2026-11-09",
        "2026-11-08", "2026-11-07", "2026-11-06",
        # The newest of each of the 4 ISO weeks before week 45: Sundays.
        "2026-11-01", "2026-10-25", "2026-10-18", "2026-10-11",
    )


def test_an_empty_week_does_not_use_up_a_weekly_slot() -> None:
    """A drive left unplugged for a fortnight still leaves four older keepers."""
    recent = {_NOW.replace(tzinfo=None) - timedelta(days=d) for d in range(7)}
    older = _days("2026-10-28", "2026-10-27", "2026-10-07", "2026-09-30", "2026-09-23",
                  "2026-09-16")
    assert backup_mod.retained(list(recent | older)) == recent | _days(
        "2026-10-28", "2026-10-07", "2026-09-30", "2026-09-23"
    )


def test_seven_or_fewer_archives_are_all_kept() -> None:
    stamps = [_NOW.replace(tzinfo=None) - timedelta(days=d * 9) for d in range(7)]
    assert backup_mod.retained(stamps) == set(stamps)


def test_a_failed_run_deletes_nothing_and_leaves_no_partial(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Retention runs only after a success, and a run that raises mid-archive
    leaves no `.partial` behind and the previous marker as it was (STOR8 item 2)."""
    home = _make_home(tmp_path)
    _populate(home)
    out = tmp_path / "out"
    create_backup(_cfg(home), out, home=home, now=_NOW - timedelta(days=20))
    for days in range(1, 16):
        (out / _archive_name(_NOW - timedelta(days=days))).write_bytes(b"x")
    before = sorted(p.name for p in out.iterdir())
    marker_before = storage.backup_marker(home).read_text()

    real_add_root = backup_mod._add_root
    calls = {"n": 0}

    def add_root_then_die(tar, root, *, include_audio):
        calls["n"] += 1
        if calls["n"] > 1:
            raise RuntimeError("disk unplugged")
        return real_add_root(tar, root, include_audio=include_audio)

    monkeypatch.setattr(backup_mod, "_add_root", add_root_then_die)
    with pytest.raises(RuntimeError, match="disk unplugged"):
        create_backup(_cfg(home), out, home=home, now=_NOW)

    assert sorted(p.name for p in out.iterdir()) == before
    assert storage.backup_marker(home).read_text() == marker_before


def test_a_completed_run_leaves_no_partial_and_a_private_marker(tmp_path: Path) -> None:
    home = _make_home(tmp_path)
    _populate(home)
    out = tmp_path / "out"
    archive = create_backup(_cfg(home), out, home=home, now=_NOW)

    assert [p.name for p in out.iterdir()] == [archive.name]
    assert stat.S_IMODE(storage.backup_marker(home).stat().st_mode) == 0o600


def test_the_summary_says_how_many_backups_were_pruned(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    home = _make_home(tmp_path)
    _populate(home)
    out = tmp_path / "out"
    out.mkdir()
    for days in range(30, 45):  # all older than anything the real clock writes now
        (out / _archive_name(_NOW - timedelta(days=days))).write_bytes(b"x" * 10)

    assert _backup_main([str(out)], home, monkeypatch) == 0
    assert "pruned " in capsys.readouterr().out


# ---------- the free-space refusal (STOR12) ----------------------------------


def _free(monkeypatch: pytest.MonkeyPatch, free: int) -> None:
    monkeypatch.setattr(backup_mod.shutil, "disk_usage", lambda _p: _Usage(free * 2, free, free))


def test_a_destination_without_room_is_refused_before_anything_is_created(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    home = _make_home(tmp_path)
    _populate(home)
    estimate = backup_mod.estimate_backup_bytes(_cfg(home), home=home)
    monkeypatch.setattr(backup_mod, "_same_volume", lambda _a, _b: False)
    _free(monkeypatch, estimate + backup_mod.BACKUP_HEADROOM_BYTES - 1)
    out = tmp_path / "out"

    with pytest.raises(BackupError) as exc:
        create_backup(_cfg(home), out, home=home)

    message = str(exc.value)
    assert storage.human_bytes(estimate + backup_mod.BACKUP_HEADROOM_BYTES - 1) in message
    assert storage.human_bytes(estimate) in message
    assert "0 backup archive(s)" in message
    assert not out.exists()
    assert not storage.backup_marker(home).exists()


def test_room_for_the_archive_plus_headroom_is_enough_off_the_library_volume(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    home = _make_home(tmp_path)
    _populate(home)
    estimate = backup_mod.estimate_backup_bytes(_cfg(home), home=home)
    monkeypatch.setattr(backup_mod, "_same_volume", lambda _a, _b: False)
    _free(monkeypatch, estimate + backup_mod.BACKUP_HEADROOM_BYTES)

    assert create_backup(_cfg(home), tmp_path / "out", home=home).exists()


def test_on_the_library_volume_the_next_recording_keeps_its_reserve(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The same free space that is plenty on a backup drive is refused when the
    destination shares the library's disk, because the recorder needs it next."""
    home = _make_home(tmp_path)
    _populate(home)
    estimate = backup_mod.estimate_backup_bytes(_cfg(home), home=home)
    out = tmp_path / "out"
    out.mkdir()
    (out / _archive_name(_NOW - timedelta(days=1))).write_bytes(b"x")
    # Real `st_dev`: tmp_path holds both the library and the destination.
    _free(monkeypatch, estimate + backup_mod.RECORDING_RESERVE_BYTES - 1)

    with pytest.raises(BackupError, match="next recording") as exc:
        create_backup(_cfg(home), out, home=home)
    assert "1 backup archive(s)" in str(exc.value)

    _free(monkeypatch, estimate + backup_mod.RECORDING_RESERVE_BYTES)
    assert create_backup(_cfg(home), out, home=home).exists()


def test_the_recording_reserve_is_two_hours_of_capture_plus_the_merge() -> None:
    # REC20's figure: 2 h x (384,000 + 192,000 + 64,000) B/s.
    assert backup_mod.RECORDING_RESERVE_BYTES == 4_608_000_000


def test_the_estimate_counts_what_the_archive_holds(tmp_path: Path) -> None:
    home = _make_home(tmp_path)
    _populate(home)
    archive = create_backup(_cfg(home), tmp_path / "out", home=home)
    manifest = read_manifest(archive)

    assert backup_mod.estimate_backup_bytes(_cfg(home), home=home) == sum(
        root["bytes"] for root in manifest["roots"]
    )
    no_audio = backup_mod.estimate_backup_bytes(_cfg(home), home=home, include_audio=False)
    assert no_audio < backup_mod.estimate_backup_bytes(_cfg(home), home=home)


# ---------- STOR8: a private archive, and a word about the destination -------


_ENCRYPTED_PLIST = (
    b'<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>'
    b"<key>Encryption</key><true/><key>FileVault</key><true/>"
    b"<key>MountPoint</key><string>/Volumes/Vault</string></dict></plist>"
)
_PLAIN_PLIST = (
    b'<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>'
    b"<key>Encryption</key><false/><key>FileVault</key><false/>"
    b"<key>MountPoint</key><string>/Volumes/USB</string></dict></plist>"
)
_ERROR_PLIST = (
    b'<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>'
    b"<key>Error</key><true/><key>ErrorMessage</key><string>Could not find disk</string></dict></plist>"
)
_EXFAT_PLIST = (
    b'<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>'
    b"<key>FilesystemType</key><string>exfat</string></dict></plist>"
)
_NO_KEYS_PLIST = (
    b'<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>'
    b"<key>FilesystemType</key><string>smbfs</string></dict></plist>"
)
# Apple Silicon with FileVault off: the always-on hardware encryption says
# `Encryption` true, and that is not a backup someone else cannot read.
_HARDWARE_ONLY_PLIST = (
    b'<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>'
    b"<key>Encryption</key><true/><key>FileVault</key><false/>"
    b"<key>FilesystemType</key><string>apfs</string></dict></plist>"
)


@pytest.mark.parametrize(
    "plist,expected",
    [(_ENCRYPTED_PLIST, True), (_PLAIN_PLIST, False), (_HARDWARE_ONLY_PLIST, False),
     (_EXFAT_PLIST, False), (_ERROR_PLIST, None), (_NO_KEYS_PLIST, None), (b"not a plist", None)],
)
def test_the_encryption_probe_reads_diskutil(plist: bytes, expected: bool | None) -> None:
    assert backup_mod.parse_diskutil_encryption(plist) is expected


def test_the_probe_asks_diskutil_about_the_destinations_mount_point(tmp_path: Path) -> None:
    calls: list[list[str]] = []

    def run(args: list[str], **_kwargs: object):
        calls.append(args)
        if args[0].endswith("df"):
            out = "Filesystem 512-blocks Used Available Capacity Mounted on\nmap auto_home 100 50 50 50% /Volumes/My Drive\n"
            return namedtuple("R", "stdout returncode")(out, 0)
        return namedtuple("R", "stdout returncode")(_PLAIN_PLIST, 0)

    assert _REAL_ENCRYPTION_PROBE(tmp_path / "not-yet" / "made", run=run) is False
    assert calls[1][-1] == "/Volumes/My Drive", "spaces in the device or the mount point survive the df parse"


def test_an_unrunnable_probe_reads_unknown(tmp_path: Path) -> None:
    def run(args: list[str], **_kwargs: object):
        raise FileNotFoundError(args[0])

    assert _REAL_ENCRYPTION_PROBE(tmp_path, run=run) is None


@pytest.mark.parametrize("encrypted", [True, False, None])
def test_the_marker_records_what_the_probe_said(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, encrypted: bool | None
) -> None:
    monkeypatch.setattr(backup_mod, "destination_encrypted", lambda _d: encrypted)
    home = _make_home(tmp_path)
    _populate(home)
    result = backup_mod.run_backup(_cfg(home), tmp_path / "out", home=home, now=_NOW)
    marker = json.loads(storage.backup_marker(home).read_text())
    assert marker["destination_encrypted"] is encrypted
    assert result.destination_encrypted is encrypted


def test_the_archive_and_a_created_destination_are_private_whatever_the_umask(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(backup_mod, "destination_encrypted", lambda _d: True)
    home = _make_home(tmp_path)
    _populate(home)
    out = tmp_path / "fresh" / "backups"
    previous = os.umask(0o022)
    try:
        result = backup_mod.run_backup(_cfg(home), out, home=home, now=_NOW)
    finally:
        os.umask(previous)
    assert stat.S_IMODE(result.archive.stat().st_mode) == 0o600
    assert stat.S_IMODE(out.stat().st_mode) == 0o700
    assert result.destination_open_mode is None


def test_an_existing_open_destination_is_left_alone_and_named(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(backup_mod, "destination_encrypted", lambda _d: True)
    home = _make_home(tmp_path)
    _populate(home)
    out = tmp_path / "shared"
    out.mkdir()
    os.chmod(out, 0o755)
    result = backup_mod.run_backup(_cfg(home), out, home=home, now=_NOW)
    assert stat.S_IMODE(out.stat().st_mode) == 0o755
    assert result.destination_open_mode == 0o755
    assert stat.S_IMODE(result.archive.stat().st_mode) == 0o600


def test_the_cli_warns_about_an_unencrypted_or_unknown_destination_and_an_open_folder(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    home = _make_home(tmp_path)
    _populate(home)
    out = tmp_path / "shared"
    out.mkdir()
    os.chmod(out, 0o755)

    monkeypatch.setattr(backup_mod, "destination_encrypted", lambda _d: False)
    assert _backup_main([str(out)], home, monkeypatch) == 0
    text = capsys.readouterr().out
    assert "[WARN]" in text and "not on an encrypted volume" in text
    assert "readable by other accounts" in text

    monkeypatch.setattr(backup_mod, "destination_encrypted", lambda _d: None)
    assert _backup_main([str(tmp_path / "private")], home, monkeypatch) == 0
    text = capsys.readouterr().out
    assert "[WARN]" in text and "could not tell" in text
    assert "readable by other accounts" not in text

    monkeypatch.setattr(backup_mod, "destination_encrypted", lambda _d: True)
    assert _backup_main([str(tmp_path / "vault")], home, monkeypatch) == 0
    assert "[WARN]" not in capsys.readouterr().out


# ---------- STOR14: a refusal's reason reaches the app ----------------------


def test_backup_to_an_unplugged_drive_says_why_on_stderr_and_nothing_on_stdout(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    volumes = tmp_path / "Volumes"
    volumes.mkdir()
    monkeypatch.setattr(backup_mod, "VOLUMES_ROOT", volumes)
    home = _make_home(tmp_path)
    _populate(home)

    rc = _backup_main([str(volumes / "BackupDrive" / "meeting-pipe")], home, monkeypatch)

    captured = capsys.readouterr()
    assert rc == 1
    assert "[FAIL]" in captured.err and "is not mounted" in captured.err
    assert captured.out == ""


def test_a_real_restore_of_an_archive_with_no_manifest_says_why_on_stderr(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    bogus = tmp_path / "bogus.tar.gz"
    with tarfile.open(bogus, "w:gz") as tar:
        payload = tmp_path / "x.txt"
        payload.write_text("hi")
        tar.add(payload, arcname="library/x.txt")

    rc = _restore_main([str(bogus)], _make_home(tmp_path), monkeypatch)

    captured = capsys.readouterr()
    assert rc == 1
    assert "[FAIL]" in captured.err
    assert "[FAIL]" not in captured.out


# ---------- a missing, unreadable or collapsed library (STOR13) --------------


def _fifteen_nights(out: Path) -> set[str]:
    """A destination holding 15 dated archives, the set STOR12's retention would
    thin to 8; returns their names."""
    out.mkdir(parents=True, exist_ok=True)
    for days in range(1, 16):
        (out / _archive_name(_NOW - timedelta(days=days))).write_bytes(b"x" * 100)
    return {p.name for p in out.iterdir()}


def _previous_marker(home: Path, library_files: int, *, audio_included: bool = True) -> str:
    marker = storage.backup_marker(home)
    marker.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps({
        "at": (_NOW - timedelta(days=1)).isoformat(),
        "archive": "/elsewhere/meeting-pipe-backup-20261111-030000.tar.gz",
        "bytes": 1234,
        "audio_included": audio_included,
        "destination_encrypted": True,
        "library_files": library_files,
    })
    marker.write_text(text)
    return text


def _library_with(home: Path, count: int) -> Path:
    library = home / "Meetings" / "raw"
    library.mkdir(parents=True, exist_ok=True)
    for i in range(count):
        (library / f"2026010{i // 10}-1200{i % 10:02d}.summary.json").write_text("{}")
    return library


def test_a_missing_library_is_refused_and_touches_nothing(tmp_path: Path) -> None:
    """F092: an unplugged library drive was archived as zero files, stamped the
    marker, and let retention prune the archives that held recordings."""
    home = _make_home(tmp_path)  # no Meetings/raw at all
    out = tmp_path / "out"
    names = _fifteen_nights(out)
    marker_before = _previous_marker(home, 40)

    with pytest.raises(BackupError, match="recordings folder") as raised:
        backup_mod.run_backup(_cfg(home), out, home=home, now=_NOW)

    assert str(home / "Meetings" / "raw") in str(raised.value)
    assert {p.name for p in out.iterdir()} == names
    assert storage.backup_marker(home).read_text() == marker_before


@pytest.mark.skipif(os.geteuid() == 0, reason="root reads a mode-000 directory anyway")
def test_an_unreadable_library_folder_is_refused_by_name(tmp_path: Path) -> None:
    home = _make_home(tmp_path)
    library = _library_with(home, 2)
    locked = library / "locked"
    locked.mkdir()
    (locked / "b.wav").write_bytes(b"RIFF")
    out = tmp_path / "out"
    names = _fifteen_nights(out)
    locked.chmod(0)
    try:
        with pytest.raises(BackupError, match="1 folder") as raised:
            backup_mod.run_backup(_cfg(home), out, home=home, now=_NOW)
    finally:
        locked.chmod(0o700)

    assert str(locked) in str(raised.value)
    assert {p.name for p in out.iterdir()} == names
    assert not storage.backup_marker(home).exists()


def test_a_library_collapsed_to_zero_files_is_refused_with_both_counts(tmp_path: Path) -> None:
    home = _make_home(tmp_path)
    _library_with(home, 0)
    out = tmp_path / "out"
    names = _fifteen_nights(out)
    marker_before = _previous_marker(home, 40)

    with pytest.raises(BackupError, match="40") as raised:
        backup_mod.run_backup(_cfg(home), out, home=home, now=_NOW)

    assert "0 files" in str(raised.value)
    assert {p.name for p in out.iterdir()} == names  # no archive, no .partial
    assert storage.backup_marker(home).read_text() == marker_before


def test_an_empty_library_is_not_refused_when_audio_inclusion_differs(tmp_path: Path) -> None:
    """A `--no-audio` run counts a library of recordings as zero; comparing it to
    a with-audio run's count would be comparing two different things."""
    home = _make_home(tmp_path)
    library = _library_with(home, 0)
    (library / "20260101-120000.wav").write_bytes(b"RIFF")
    _previous_marker(home, 40, audio_included=True)

    result = backup_mod.run_backup(_cfg(home), tmp_path / "out", home=home, now=_NOW,
                                   include_audio=False)

    assert result.library_files == 0
    assert json.loads(storage.backup_marker(home).read_text())["library_files"] == 0


def test_a_sharply_shrunk_library_is_backed_up_but_retention_is_skipped(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    home = _make_home(tmp_path)
    _library_with(home, 10)
    out = tmp_path / "out"
    names = _fifteen_nights(out)
    _previous_marker(home, 40)
    emitted: list[tuple[str, str, dict]] = []
    monkeypatch.setattr(backup_mod.events, "emit", lambda c, a, **kw: emitted.append((c, a, kw)))

    result = backup_mod.run_backup(_cfg(home), out, home=home, now=_NOW)

    assert {p.name for p in out.iterdir()} == names | {result.archive.name}
    marker = json.loads(storage.backup_marker(home).read_text())
    assert marker["archive"] == str(result.archive)
    assert marker["library_files"] == 10
    assert result.pruned == 0
    assert result.previous_library_files == 40
    assert result.prune_skipped
    assert emitted == [
        ("pipeline", "backup_prune_skipped", {"library_files": 10, "previous_library_files": 40})
    ]


def test_the_summary_says_retention_was_skipped(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    home = _make_home(tmp_path)
    _library_with(home, 10)
    out = tmp_path / "out"
    _fifteen_nights(out)
    _previous_marker(home, 40)

    assert _backup_main([str(out)], home, monkeypatch) == 0
    stdout = capsys.readouterr().out
    assert "retention skipped: library has 10 files, last backup had 40" in stdout
    assert "pruned " not in stdout


def test_a_steady_library_prunes_as_before_and_the_marker_counts_it(tmp_path: Path) -> None:
    home = _make_home(tmp_path)
    _library_with(home, 40)
    out = tmp_path / "out"
    _fifteen_nights(out)
    _previous_marker(home, 40)

    result = backup_mod.run_backup(_cfg(home), out, home=home, now=_NOW)

    assert result.pruned == 8  # STOR12's policy over the same 15 nights
    assert not result.prune_skipped
    assert json.loads(storage.backup_marker(home).read_text())["library_files"] == 40


def test_a_marker_without_a_count_compares_nothing(tmp_path: Path) -> None:
    """A marker written before STOR13 carries no `library_files`; the first run
    after the upgrade prunes as before and starts the count."""
    home = _make_home(tmp_path)
    _library_with(home, 3)
    marker = storage.backup_marker(home)
    marker.parent.mkdir(parents=True, exist_ok=True)
    marker.write_text(json.dumps({"at": _NOW.isoformat(), "audio_included": True}))
    out = tmp_path / "out"
    _fifteen_nights(out)

    result = backup_mod.run_backup(_cfg(home), out, home=home, now=_NOW)

    assert result.pruned == 8
    assert json.loads(marker.read_text())["library_files"] == 3


# ---------- a restore that fails part way, or cannot fit (STOR17) ------------


def _forced_restore_fixture(tmp_path: Path) -> tuple[Path, Path, Path]:
    """A real archive of `old-mac`, and a populated `this-mac` whose library's two
    text files were edited after the backup and which holds a newer meeting the
    archive never saw."""
    source = _make_home(tmp_path, "old-mac")
    _populate(source)
    archive = create_backup(_cfg(source), tmp_path / "out", home=source)
    here = _make_home(tmp_path, "this-mac")
    _populate(here)
    library = here / "Meetings" / "raw"
    (library / "20260101-120000.md").write_text("# edited here after the backup")
    (library / "20260101-120000.summary.json").write_text('{"title": "edited here"}')
    (library / "20260301-090000.md").write_text("# a newer meeting")
    return archive, here, library


def _fail_second_replace(monkeypatch: pytest.MonkeyPatch) -> None:
    from mp import restore as restore_mod

    real_replace = os.replace
    calls = {"n": 0}

    def replace(src, dst):
        calls["n"] += 1
        if calls["n"] == 2:
            raise OSError(errno.ENOSPC, "No space left on device", str(dst))
        return real_replace(src, dst)

    monkeypatch.setattr(restore_mod.os, "replace", replace)


def _restoring_temps(*roots: Path) -> list[Path]:
    return [p for root in roots if root.exists() for p in root.rglob("*.restoring")]


def test_a_failed_forced_restore_leaves_each_file_old_or_whole(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """F094: extraction opened the live file `wb`, so ENOSPC on the next member
    left a previously intact transcript truncated."""
    archive, here, library = _forced_restore_fixture(tmp_path)
    before = (library / "20260101-120000.summary.json").read_bytes()
    _fail_second_replace(monkeypatch)

    with pytest.raises(RestoreError, match="ENOSPC") as raised:
        restore_archive(archive, _cfg(here), home=here, force=True)

    # Archive order is sorted: the .md is replaced first, the summary second.
    assert (library / "20260101-120000.md").read_text() == "# transcript"
    assert (library / "20260101-120000.summary.json").read_bytes() == before
    assert "1 file(s) were already restored" in str(raised.value)
    assert _restoring_temps(here) == []


def test_the_cli_reports_a_failed_restore_without_a_traceback(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    archive, here, _library = _forced_restore_fixture(tmp_path)
    _fail_second_replace(monkeypatch)

    assert _restore_main([str(archive), "--force"], here, monkeypatch) == 1
    captured = capsys.readouterr()
    assert captured.err.startswith("[FAIL] restore from")
    assert "Traceback" not in captured.err + captured.out


def test_a_restore_without_room_is_refused_before_anything_is_written(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    archive, here, _library = _forced_restore_fixture(tmp_path)
    snapshot = {
        p: (p.read_bytes(), p.stat().st_mtime_ns) for p in here.rglob("*") if p.is_file()
    }
    # Plenty for the archive's few hundred bytes, short of the recording reserve.
    _free(monkeypatch, backup_mod.RECORDING_RESERVE_BYTES - 1)

    with pytest.raises(RestoreError, match="not enough room") as raised:
        restore_archive(archive, _cfg(here), home=here, force=True)

    assert "Nothing was written" in str(raised.value)
    assert {
        p: (p.read_bytes(), p.stat().st_mtime_ns) for p in here.rglob("*") if p.is_file()
    } == snapshot


def test_a_dry_run_is_never_refused_for_room(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    archive, here, _library = _forced_restore_fixture(tmp_path)
    _free(monkeypatch, 0)
    assert restore_archive(archive, _cfg(here), home=here, dry_run=True)["library"] == 3


def test_a_forced_restore_puts_the_archived_bytes_back_and_leaves_newer_files(
    tmp_path: Path,
) -> None:
    """F120: the forced-restore tests only counted files, never read one back."""
    archive, here, library = _forced_restore_fixture(tmp_path)

    restore_archive(archive, _cfg(here), home=here, force=True)

    assert (library / "20260101-120000.md").read_text() == "# transcript"
    assert (library / "20260101-120000.summary.json").read_text() == '{"title": "Weekly sync"}'
    assert (library / "20260301-090000.md").read_text() == "# a newer meeting"
    assert _restoring_temps(here) == []


def _with_manifest(tmp_path: Path, edit) -> Path:
    """A real backup whose manifest has been rewritten by `edit`."""
    home = _make_home(tmp_path, "old-mac")
    _populate(home)
    archive = create_backup(_cfg(home), tmp_path / "out", home=home)
    edited = tmp_path / "edited.tar.gz"
    with tarfile.open(archive, "r:gz") as src, tarfile.open(edited, "w:gz") as dst:
        for member in src.getmembers():
            data = src.extractfile(member).read()  # type: ignore[union-attr]
            if member.name == MANIFEST_NAME:
                manifest = json.loads(data)
                edit(manifest)
                data = json.dumps(manifest).encode()
                member.size = len(data)
            dst.addfile(member, io.BytesIO(data))
    return edited


@pytest.mark.parametrize(
    ("edit", "match"),
    [
        (lambda m: m.update(schema_version=2), "schema_version 2"),
        (lambda m: m.pop("schema_version"), "missing schema_version"),
        (lambda m: m.pop("created_at"), "missing created_at"),
    ],
    ids=["future-schema", "no-schema", "no-created-at"],
)
def test_a_manifest_this_version_cannot_honour_is_refused(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str],
    edit, match: str,
) -> None:
    """F205: `schema_version` was written by every backup and read by nothing."""
    archive = _with_manifest(tmp_path, edit)
    fresh = _make_home(tmp_path, "new-mac")

    with pytest.raises(RestoreError, match=match):
        read_manifest(archive)
    with pytest.raises(RestoreError, match=match):
        plan_restore(archive, _cfg(fresh), home=fresh)
    assert _restore_main([str(archive)], fresh, monkeypatch) == 1
    assert _restore_main([str(archive), "--dry-run", "--json"], fresh, monkeypatch) == 1
    captured = capsys.readouterr()
    assert "Traceback" not in captured.err
    assert not (fresh / "Meetings" / "raw").exists()


def test_a_truncated_archive_is_refused_not_a_traceback(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    home = _make_home(tmp_path, "old-mac")
    _populate(home)
    archive = create_backup(_cfg(home), tmp_path / "out", home=home)
    archive.write_bytes(archive.read_bytes()[: archive.stat().st_size // 2])
    fresh = _make_home(tmp_path, "new-mac")

    with pytest.raises(RestoreError, match="truncated or unreadable"):
        read_manifest(archive)
    with pytest.raises(RestoreError, match="truncated or unreadable"):
        plan_restore(archive, _cfg(fresh), home=fresh)
    assert _restore_main([str(archive)], fresh, monkeypatch) == 1


def test_an_interrupted_restore_leaves_no_temp_behind(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The router turns SIGTERM into SystemExit; a `.restoring` file left by it
    would be archived by the next backup."""
    from mp import restore as restore_mod

    archive, here, library = _forced_restore_fixture(tmp_path)
    before = (library / "20260101-120000.md").read_bytes()

    def interrupted(src, dst):
        raise SystemExit(143)

    monkeypatch.setattr(restore_mod.os, "replace", interrupted)
    with pytest.raises(SystemExit):
        restore_archive(archive, _cfg(here), home=here, force=True)

    assert (library / "20260101-120000.md").read_bytes() == before
    assert _restoring_temps(here) == []
