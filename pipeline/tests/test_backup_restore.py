"""`mp backup` / `mp restore` round-trip over a fake `$HOME` (STOR2).

The acceptance criterion is the round-trip: a backup restored into a scratch home
yields a working library, workflows, roster, and corrections state, and the
manifest names every Keychain item without exporting one.
"""
from __future__ import annotations

import json
import tarfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from mp import storage
from mp import backup as backup_mod
from mp.backup import MANIFEST_NAME, BackupError, check_destination, create_backup
from mp.config import KEYCHAIN_SERVICE, MANAGED_SECRET_KEYS, Config
from mp.restore import RestoreError, read_manifest, restore_archive


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


def test_read_manifest_round_trips_the_creation_time(tmp_path: Path) -> None:
    home = _make_home(tmp_path)
    _populate(home)
    when = datetime.now(timezone.utc) - timedelta(days=3)
    archive = create_backup(_cfg(home), tmp_path / "out", home=home, now=when)
    assert archive.name == f"meeting-pipe-backup-{when.strftime('%Y%m%d-%H%M%S')}.tar.gz"
    assert read_manifest(archive)["created_at"] == when.isoformat()
    assert MANIFEST_NAME in _members(archive)
